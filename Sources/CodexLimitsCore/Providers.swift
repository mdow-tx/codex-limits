import AppKit
import CryptoKit
import Foundation
import Security

public protocol CodexUsageProvider: Sendable {
    var name: String { get }
    func fetchSnapshot() async throws -> RateLimitSnapshot
}

public struct ProviderChain: Sendable {
    public let providers: [CodexUsageProvider]
    public let store: SnapshotStore

    public init(providers: [CodexUsageProvider]? = nil, store: SnapshotStore = SnapshotStore()) {
        self.providers = providers ?? [
            CodexStructuredProvider(),
            CodexCachedStateProvider()
        ]
        self.store = store
    }

    public func fetchSnapshot() async throws -> RateLimitSnapshot {
        var errors: [String] = []
        for provider in providers {
            do {
                let snapshot = try await provider.fetchSnapshot()
                try? store.save(snapshot)
                return snapshot
            } catch {
                errors.append("\(provider.name): \(error.localizedDescription)")
            }
        }
        if let cached = try? store.load() {
            return RateLimitSnapshot(
                buckets: cached.buckets,
                credit: cached.credit,
                resetCredits: cached.resetCredits,
                lastUpdated: cached.lastUpdated,
                sourceStatus: .cachedStructured,
                sourceDescription: "Last saved snapshot; refresh failed: \(errors.joined(separator: " | "))",
                planType: cached.planType,
                rateLimitReachedType: cached.rateLimitReachedType,
                spendControl: cached.spendControl
            )
        }
        throw CodexUsageError.unavailable(errors.joined(separator: " | "))
    }
}

public struct CodexStructuredProvider: CodexUsageProvider {
    public let name = "Codex structured fetch"
    public let codexHome: URL
    public let endpoint: URL

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) {
        self.codexHome = codexHome
        self.endpoint = endpoint
    }

    public func fetchSnapshot() async throws -> RateLimitSnapshot {
        let auth = try CodexAuth.load(codexHome: codexHome)
        guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            throw CodexUsageError.unavailable("Codex does not have a ChatGPT access token available. Open Codex in the ChatGPT desktop app and sign in, then refresh.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.0.0 (Mac OS; arm64) Codex Limits", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.tokens?.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await usageSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageError.unavailable("Codex usage endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexUsageError.unavailable("Codex usage endpoint returned HTTP \(http.statusCode).")
        }
        return try UsagePayloadParser.parse(
            data: data,
            sourceStatus: .liveStructured,
            sourceDescription: "Fetched Codex usage from \(endpoint.absoluteString)"
        )
    }

    private var usageSession: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }
}

struct CodexAuth: Decodable {
    let authMode: String?
    let tokens: Tokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }

    static func load(codexHome: URL) throws -> Self {
        let fileURL = codexHome.appendingPathComponent("auth.json")
        if let keychainAuth = try? loadFromKeychain(codexHome: codexHome) {
            return keychainAuth
        }
        return try loadFromFile(fileURL)
    }

    static func loadFromFile(_ url: URL) throws -> Self {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CodexUsageError.unavailable("Could not read Codex auth at \(url.path): \(error.localizedDescription)")
        }
    }

    static func loadFromKeychain(codexHome: URL) throws -> Self {
        let account = try CodexAuthStoreKey.account(for: codexHome)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Codex Auth",
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw CodexUsageError.unavailable("Could not read Codex auth from Keychain account \(account): \(Self.securityMessage(status))")
        }
        guard let data = result as? Data else {
            throw CodexUsageError.unavailable("Codex Keychain auth entry did not contain data.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CodexUsageError.unavailable("Could not decode Codex Keychain auth: \(error.localizedDescription)")
        }
    }

    private static func securityMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }

    struct Tokens: Decodable {
        let accessToken: String?
        let accountID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}

enum CodexAuthStoreKey {
    static func account(for codexHome: URL) throws -> String {
        let canonicalPath = canonicalPath(for: codexHome)
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let prefix = String(digest.prefix(16))
        return "cli|\(prefix)"
    }

    private static func canonicalPath(for url: URL) -> String {
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        }
        return url.path
    }
}

public struct CodexCachedStateProvider: CodexUsageProvider {
    public let name = "Codex cached state"
    public let roots: [URL]

    public init(roots: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [
            home.appendingPathComponent("Library/Application Support/Codex/Local Storage/leveldb"),
            home.appendingPathComponent("Library/Application Support/Codex/Session Storage"),
            home.appendingPathComponent("Library/Application Support/Codex/Partitions/codex-browser-app/Local Storage/leveldb"),
            home.appendingPathComponent("Library/Application Support/Codex/Partitions/codex-browser-app/Session Storage"),
            home.appendingPathComponent("Library/Application Support/ChatGPT/Local Storage/leveldb"),
            home.appendingPathComponent("Library/Application Support/ChatGPT/Session Storage"),
            home.appendingPathComponent("Library/Application Support/ChatGPT/Partitions/codex-browser-app/Local Storage/leveldb"),
            home.appendingPathComponent("Library/Application Support/ChatGPT/Partitions/codex-browser-app/Session Storage")
        ]
    }

    public func fetchSnapshot() async throws -> RateLimitSnapshot {
        let files = Self.candidateFiles(roots: roots)
        for url in files {
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { continue }
            for candidate in JSONCandidateExtractor.extractCandidates(from: data) {
                if let snapshot = try? UsagePayloadParser.parse(
                    data: candidate,
                    sourceStatus: .cachedStructured,
                    sourceDescription: "Parsed cached Codex state from \(url.path)"
                ) {
                    return snapshot
                }
            }
        }
        throw CodexUsageError.unavailable("No cached structured usage payload found in Codex storage.")
    }

    private static func candidateFiles(roots: [URL]) -> [URL] {
        var files: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files.append(url)
            }
        }
        return files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
    }
}

public struct AccessibilityProvider: CodexUsageProvider {
    public let name = "Accessibility text (no OCR)"

    public init() {}

    public func fetchSnapshot() async throws -> RateLimitSnapshot {
        let promptOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(promptOptions)
        guard trusted else {
            throw CodexUsageError.unavailable("Accessibility text permission is not granted. This reads UI labels only; it does not take screenshots or run OCR.")
        }

        let app = ["com.openai.codex", "com.openai.chat"]
            .lazy
            .compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .first
        guard let pid = app?.processIdentifier else {
            throw CodexUsageError.unavailable("Codex is not running in the ChatGPT desktop app.")
        }

        let element = AXUIElementCreateApplication(pid)
        let text = collectText(from: element).joined(separator: "\n")
        guard !text.isEmpty else {
            throw CodexUsageError.unavailable("No readable Codex accessibility text found. No OCR or screenshot capture was attempted.")
        }
        guard let snapshot = AccessibilityTextParser.parse(text: text) else {
            throw CodexUsageError.parseFailed("Codex accessibility text did not include rate-limit rows. No OCR or screenshot capture was attempted.")
        }
        return snapshot
    }

    private func collectText(from element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var output: [String] = []
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let string = value as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(string)
            }
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childElements = children as? [AXUIElement] {
            for child in childElements {
                output.append(contentsOf: collectText(from: child, depth: depth + 1))
            }
        }
        return output
    }
}
