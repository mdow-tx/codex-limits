import CodexLimitsCore
import Charts
import SwiftUI
import UserNotifications

@main
struct CodexLimitsMenuBarApp: App {
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        MenuBarExtra(SnapshotFormatting.menuTitle(for: model.snapshot)) {
            LimitsPanel(model: model)
                .task {
                    await model.refresh()
                    model.startTimer()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var snapshot: RateLimitSnapshot?
    @Published var history: [RateLimitSnapshot] = []
    @Published var errorMessage: String?
    @Published var isRefreshing = false

    private let chain = ProviderChain()
    private let store = SnapshotStore()
    private let historyStore = SnapshotHistoryStore()
    private let notifier = LimitNotifier()
    private var timer: Timer?

    init() {
        snapshot = try? store.load()
        history = (try? historyStore.load()) ?? []
    }

    func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
            await notifier.sendNotificationsIfNeeded(for: next)
        } catch {
            errorMessage = error.localizedDescription
            if snapshot == nil {
                snapshot = try? store.load()
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

struct LimitsPanel: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(RateLimitGroup.allCases, id: \.self) { group in
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
                }
            } else {
                ContentUnavailableView("No Codex usage data yet", systemImage: "speedometer")
                    .frame(maxWidth: .infinity)
            }

            if let error = model.errorMessage {
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
                Text("Codex Limits")
                    .font(.headline)
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
                Spacer()
                Button("Quit") {
                    model.quit()
                }
            }
        }
    }

    private var statusText: String {
        if let snapshot = model.snapshot {
            return "Updated \(snapshot.lastUpdated.formatted(date: .omitted, time: .shortened))"
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
        guard historyPoints.count >= 2,
              let first = historyPoints.dropLast().last?.remainingPercent,
              let latest = historyPoints.last?.remainingPercent else {
            return "Trend after 6 refreshes"
        }
        let delta = latest - first
        if abs(delta) < 0.5 {
            return "No change"
        }
        let sign = delta > 0 ? "+" : ""
        return "\(sign)\(Int(delta.rounded()))% since last refresh"
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
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
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
