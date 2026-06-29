import CodexLimitsCore
import AppKit
import Charts
import SwiftUI
@preconcurrency import UserNotifications

@main
struct CodexLimitsMenuBarApp: App {
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        MenuBarExtra(model.menuTitle) {
            LimitsPanel(model: model)
                .task {
                    await model.refresh()
                    model.startTimer()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case one = 60
    case five = 300
    case ten = 600
    case fifteen = 900

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .one: "1 min"
        case .five: "5 min"
        case .ten: "10 min"
        case .fifteen: "15 min"
        }
    }
}

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var snapshot: RateLimitSnapshot?
    @Published var history: [RateLimitSnapshot] = []
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published var notificationsEnabled: Bool
    @Published var refreshInterval: RefreshInterval

    private let chain = ProviderChain()
    private let store = SnapshotStore()
    private let historyStore = SnapshotHistoryStore()
    private let notifier = LimitNotifier()
    private let notificationsKey = "notificationsEnabled"
    private let refreshIntervalKey = "refreshIntervalSeconds"
    private var timer: Timer?

    init() {
        snapshot = try? store.load()
        history = (try? historyStore.load()) ?? []
        notificationsEnabled = UserDefaults.standard.bool(forKey: notificationsKey)
        let savedInterval = UserDefaults.standard.integer(forKey: refreshIntervalKey)
        refreshInterval = RefreshInterval(rawValue: savedInterval) ?? .five
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval.rawValue), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let next = try await chain.fetchSnapshot()
            snapshot = next
            try? historyStore.append(next)
            history = (try? historyStore.load()) ?? [next]
            errorMessage = nil
            if notificationsEnabled {
                await notifier.sendNotificationsIfNeeded(for: next)
            }
        } catch {
            errorMessage = error.localizedDescription
            if snapshot == nil {
                snapshot = try? store.load()
            }
        }
    }

    func setRefreshInterval(_ interval: RefreshInterval) {
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: refreshIntervalKey)
        startTimer()
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        notificationsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: notificationsKey)
        if isEnabled {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    var menuTitle: String {
        SnapshotFormatting.menuTitle(for: snapshot)
    }

    var isStale: Bool {
        guard let snapshot else { return false }
        return Date().timeIntervalSince(snapshot.lastUpdated) > 30 * 60
    }

    var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "dev")"
    }

    var sanitizedError: String? {
        errorMessage.map(Self.sanitize)
    }

    var needsCodexSignIn: Bool {
        guard snapshot == nil, let errorMessage else { return false }
        return errorMessage.contains("auth.json")
            || errorMessage.localizedCaseInsensitiveContains("access token")
            || errorMessage.localizedCaseInsensitiveContains("auth file")
    }

    func copyDiagnostics() {
        let text = diagnosticsText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func diagnosticsText() -> String {
        var lines: [String] = [
            "Codex Limits \(versionText)",
            "Last refresh: \(snapshot?.lastUpdated.formatted(date: .abbreviated, time: .standard) ?? "never")",
            "Refresh interval: \(refreshInterval.label)",
            "Notifications enabled: \(notificationsEnabled ? "yes" : "no")"
        ]
        if isStale {
            lines.append("Status: stale")
        }
        if let error = sanitizedError {
            lines.append("Last error: \(error)")
        }
        if let snapshot {
            if let planType = snapshot.planType {
                lines.append("Plan: \(planType)")
            }
            if let rateLimitReachedType = snapshot.rateLimitReachedType {
                lines.append("Rate limit reached type: \(rateLimitReachedType)")
            }
            if let spendControl = snapshot.spendControl {
                let remaining = spendControl.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "unknown"
                lines.append("Spend control: \(remaining) remaining")
            }
            lines.append("Limits:")
            for bucket in snapshot.buckets.sorted(by: { $0.id < $1.id }) {
                let remaining = bucket.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "unknown"
                let reset = SnapshotFormatting.resetText(for: bucket) ?? "unknown"
                lines.append("- \(bucket.group.displayName) \(bucket.window.displayName): \(remaining) left, resets \(reset)")
            }
            if let credit = snapshot.credit {
                let balance = credit.balance.map { String(Int($0.rounded())) } ?? "unknown"
                lines.append("Credit: \(credit.unlimited ? "unlimited" : balance)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(
            of: NSHomeDirectory(),
            with: "~"
        )
    }
}

struct LimitsPanel: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    if model.isStale {
                        Label("Last successful refresh is stale", systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(groups(in: snapshot), id: \.self) { group in
                        let rows = snapshot.buckets.filter { $0.group == group }
                        if !rows.isEmpty {
                            LimitGroupSection(group: group, buckets: rows, history: model.history)
                        }
                    }

                    if let credit = snapshot.credit {
                        Divider()
                        Label(creditText(credit), systemImage: "creditcard")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle(isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { model.setNotificationsEnabled($0) }
                    )) {
                        Label("Low-limit notifications", systemImage: "bell")
                    }

                    Picker("Refresh", selection: Binding(
                        get: { model.refreshInterval },
                        set: { model.setRefreshInterval($0) }
                    )) {
                        ForEach(RefreshInterval.allCases) { interval in
                            Text(interval.label).tag(interval)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                if model.needsCodexSignIn {
                    ContentUnavailableView(
                        "Sign in to Codex first",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Open Codex, sign in, then refresh this menu.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView("No Codex usage data yet", systemImage: "speedometer")
                        .frame(maxWidth: .infinity)
                }
            }

            if let error = model.sanitizedError {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Refresh failed", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }

            footer
        }
        .padding(16)
        .frame(width: 420)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Codex Limits")
                        .font(.headline)
                    Text(model.versionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh Now")
            .disabled(model.isRefreshing)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack {
                Button {
                    model.copyDiagnostics()
                } label: {
                    Label("Copy Debug Info", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Quit") {
                    model.quit()
                }
            }
        }
    }

    private var statusText: String {
        if let snapshot = model.snapshot {
            let prefix = model.isStale ? "Stale" : "Updated"
            return "\(prefix) \(snapshot.lastUpdated.formatted(date: .omitted, time: .shortened))"
        }
        return model.isRefreshing ? "Refreshing..." : "Waiting for first refresh"
    }

    private func creditText(_ credit: CreditStatus) -> String {
        if credit.unlimited {
            return "Credit: unlimited"
        }
        if let balance = credit.balance {
            return "Credit: \(Int(balance.rounded())) remaining"
        }
        return credit.available ? "Credit: available" : "Credit: unavailable"
    }

    private func groups(in snapshot: RateLimitSnapshot) -> [RateLimitGroup] {
        Array(Set(snapshot.buckets.map(\.group)))
            .sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
    }
}

struct LimitGroupSection: View {
    let group: RateLimitGroup
    let buckets: [RateLimitBucket]
    let history: [RateLimitSnapshot]
    @State private var showsTrends = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.displayName)
                    .font(.headline)
                Spacer()
                if hasTrendData {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            showsTrends.toggle()
                        }
                    } label: {
                        Label(showsTrends ? "Hide Trends" : "Show Trends", systemImage: showsTrends ? "chevron.up" : "chart.xyaxis.line")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(showsTrends ? "Hide trend details" : "Show trend details")
                }
            }
            ForEach(buckets) { bucket in
                LimitBucketRow(bucket: bucket, historyPoints: points(for: bucket), showsTrend: showsTrends)
            }
        }
    }

    private var hasTrendData: Bool {
        buckets.contains { points(for: $0).count >= 6 }
    }

    private func points(for bucket: RateLimitBucket) -> [LimitHistoryPoint] {
        history.compactMap { snapshot in
            guard let match = snapshot.buckets.first(where: { $0.id == bucket.id }),
                  let remaining = match.remainingPercent else {
                return nil
            }
            return LimitHistoryPoint(date: snapshot.lastUpdated, remainingPercent: remaining)
        }
    }
}

struct LimitBucketRow: View {
    let bucket: RateLimitBucket
    let historyPoints: [LimitHistoryPoint]
    let showsTrend: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(bucket.window.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: normalizedRemaining)
                .tint(color)

            HStack(alignment: .center, spacing: 8) {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(deltaText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if showsTrend, historyPoints.count >= 6 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trend over time")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LimitHistoryChart(points: historyPoints, color: color)
                        .frame(height: 86)
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    private var normalizedRemaining: Double {
        max(0, min(1, (bucket.remainingPercent ?? 0) / 100))
    }

    private var summary: String {
        guard let remaining = bucket.remainingPercent else { return "unknown" }
        return "\(Int(remaining.rounded()))% left"
    }

    private var resetText: String {
        SnapshotFormatting.resetText(for: bucket).map { "Resets \($0)" } ?? "Reset unknown"
    }

    private var deltaText: String {
        let orderedPoints = historyPoints.sorted { $0.date < $1.date }
        guard let latest = orderedPoints.last else {
            return ""
        }

        let oneHourAgo = latest.date.addingTimeInterval(-60 * 60)
        guard let baseline = orderedPoints
            .dropLast()
            .filter({ $0.date <= oneHourAgo })
            .last else {
            return ""
        }

        let delta = latest.remainingPercent - baseline.remainingPercent
        if abs(delta) < 0.5 {
            return ""
        }
        let sign = delta > 0 ? "+" : ""
        return "\(sign)\(Int(delta.rounded()))% in the last hour"
    }

    private var color: Color {
        guard let remaining = bucket.remainingPercent else { return .secondary }
        if remaining <= 10 { return .red }
        if remaining <= 25 { return .orange }
        return .green
    }
}

struct LimitHistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let remainingPercent: Double
}

struct LimitHistoryChart: View {
    let points: [LimitHistoryPoint]
    let color: Color
    @State private var selectedPoint: LimitHistoryPoint?

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Remaining", point.remainingPercent)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(color)
            PointMark(
                x: .value("Time", point.date),
                y: .value("Remaining", point.remainingPercent)
            )
            .symbolSize(18)
            .foregroundStyle(color)

            if selectedPoint?.id == point.id {
                RuleMark(x: .value("Selected Time", point.date))
                    .foregroundStyle(.secondary.opacity(0.35))
                PointMark(
                    x: .value("Selected Time", point.date),
                    y: .value("Selected Remaining", point.remainingPercent)
                )
                .symbolSize(54)
                .foregroundStyle(color)
                .annotation(position: .top, alignment: .center) {
                    VStack(spacing: 2) {
                        Text(point.date.formatted(date: .omitted, time: .shortened))
                        Text("\(Int(point.remainingPercent.rounded()))% left")
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                    .foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) {
                AxisGridLine()
                    .foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartYScale(domain: 0...100)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            selectedPoint = nearestPoint(to: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            selectedPoint = nil
                        }
                    }
            }
        }
    }

    private func nearestPoint(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> LimitHistoryPoint? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let x = location.x - origin.x
        guard let hoveredDate: Date = proxy.value(atX: x) else { return nil }
        return points.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(hoveredDate)) < abs(rhs.date.timeIntervalSince(hoveredDate))
        }
    }
}

actor LimitNotifier {
    private var sentKeys: Set<String> = []

    func sendNotificationsIfNeeded(for snapshot: RateLimitSnapshot) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        for bucket in snapshot.buckets {
            guard let remaining = bucket.remainingPercent else { continue }
            let threshold: Int?
            if remaining <= 5 {
                threshold = 5
            } else if remaining <= 10 {
                threshold = 10
            } else if remaining <= 25 {
                threshold = 25
            } else {
                threshold = nil
            }
            guard let threshold else { continue }
            let resetKey = bucket.resetAt?.timeIntervalSince1970.description ?? bucket.resetLabel ?? "unknown"
            let key = "\(bucket.id)-\(threshold)-\(resetKey)"
            guard !sentKeys.contains(key) else { continue }
            sentKeys.insert(key)

            let content = UNMutableNotificationContent()
            content.title = "Codex limit below \(threshold)%"
            content.body = SnapshotFormatting.detailLine(for: bucket)
            let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
