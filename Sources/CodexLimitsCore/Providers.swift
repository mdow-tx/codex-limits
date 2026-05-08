import AppKit
import Foundation

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
                lastUpdated: cached.lastUpdated,
                sourceStatus: .cachedStructured,
                sourceDescription: "Last saved snapshot; refresh failed: \(errors.joined(separator: " | "))"
            )
        }
        throw CodexUsageError.unavailable(errors.joined(separator: " | "))
    }
}

public struct CodexStructuredProvider: CodexUsageProvider {
    public let name = "Codex structured fetch"
    public let authURL: URL
    public let endpoint: URL

    public init(
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"),
        endpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) {
        self.authURL = authURL
        self.endpoint = endpoint
    }

    public func fetchSnapshot() async throws -> RateLimitSnapshot {
        let auth = try CodexAuthFile.load(from: authURL)
        guard auth.authMode == "chatgpt" else {
            throw CodexUsageError.unavailable("Codex auth mode '\(auth.authMode ?? "unknown")' is not supported by the ChatGPT usage endpoint yet.")
        }
        guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            throw CodexUsageError.unavailable("Codex auth file does not include a ChatGPT access token.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.0.0 (Mac OS; arm64) Codex Limits", forHTTPHeaderField: "User-Agent")
        if let accountID = auth.tokens?.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageError.unavailable("Codex usage endpoint returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let reason = String(data: data.prefix(800), encoding: .utf8) ?? "empty response"
            throw CodexUsageError.unavailable("Codex usage endpoint returned HTTP \(http.statusCode): \(reason)")
        }
        return try UsagePayloadParser.parse(
            data: data,
            sourceStatus: .liveStructured,
            sourceDescription: "Fetched Codex usage from \(endpoint.absoluteString)"
        )
    }
}

private struct CodexAuthFile: Decodable {
    let authMode: String?
    let tokens: Tokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }

    static func load(from url: URL) throws -> Self {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CodexUsageError.unavailable("Could not read Codex auth at \(url.path): \(error.localizedDescription)")
        }
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

public struct CodexCachedStateProvider: CodexUsageProvider {
    public let name = "Codex cached state"
    public let roots: [URL]

    public init(roots: [URL]? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.roots = roots ?? [
            home.appendingPathComponent("Library/Application Support/Codex/Local Storage/leveldb"),
            home.appendingPathComponent("Library/Application Support/Codex/Session Storage"),
            home.appendingPathComponent("Library/Application Support/Codex/Partitions/codex-browser-app/Local Storage/leveldb"),
            home.appendingPathComponent("Library/Application Support/Codex/Partitions/codex-browser-app/Session Storage")
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
        return files
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

        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        guard let pid = app?.processIdentifier else {
            throw CodexUsageError.unavailable("Codex is not running.")
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
