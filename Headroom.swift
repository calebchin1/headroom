import AppKit
import IOKit
import IOKit.hid
import SwiftUI

// MARK: - Model

struct Limit: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    var detail: String? = nil   // shown under the label instead of the reset countdown
    var level: Severity? = nil  // overrides the percent-based severity (memory uses kernel pressure instead)
    init(id: String, label: String, percent: Double, resetsAt: Date?, detail: String? = nil) {
        self.id = id; self.label = label; self.detail = detail
        self.percent = percent.isFinite ? min(max(percent, 0), 999) : 0   // Int() traps on inf/NaN/huge
        self.resetsAt = resetsAt
    }
}

/// Claude and Codex share the main widget (a click swaps them); System (this Mac's memory and CPU) has its own panel.
enum Provider: String, CaseIterable {
    case claude, codex, system
    var other: Provider { self == .claude ? .codex : .claude }

    var name: String { self == .claude ? "Claude" : (self == .codex ? "Codex" : "System") }
    /// Brand colours: Claude terracotta, OpenAI/ChatGPT green, macOS blue for the system page.
    var brand: Color {
        switch self {
        case .claude: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: return Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)
        case .system: return Color(red: 0x4F / 255, green: 0xA8 / 255, blue: 0xFF / 255)
        }
    }
    var usageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .system: return URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        }
    }
    var usageTitle: String { self == .system ? "Open Activity Monitor" : "Open \(name) Usage Page" }
}

/// Memory and CPU straight from the kernel: two Mach calls per sample, no subprocesses, nothing retained.
enum SystemStats {
    static let host = mach_host_self()

    /// Same sum Activity Monitor calls "Memory Used": app + wired + compressed.
    static func memory() -> (used: Double, total: Double)? {
        var s = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(host, HOST_VM_INFO64, $0, &n) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0
        host_page_size(host, &page)
        let pages = Double(s.internal_page_count) - Double(s.purgeable_count) + Double(s.wire_count) + Double(s.compressor_page_count)
        return (max(pages, 0) * Double(page), Double(ProcessInfo.processInfo.physicalMemory))
    }

    /// Cumulative (user, system, idle, nice) ticks across all cores; usage is the delta between two reads.
    static func cpuTicks() -> [UInt32]? {
        var s = host_cpu_load_info()
        var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &n) }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return [s.cpu_ticks.0, s.cpu_ticks.1, s.cpu_ticks.2, s.cpu_ticks.3]
    }

    /// Kernel memory pressure (1 normal, 2 warning, 4 critical). A full-looking ring is normal on macOS; pressure is what matters.
    static func pressure() -> Severity {
        var v: Int32 = 0
        var n = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &n, nil, 0) == 0 else { return .normal }
        return v >= 4 ? .critical : (v >= 2 ? .warning : .normal)
    }
}

/// Right-click → Glass. `.hudWindow` is the most see-through dark material; `.fullScreenUI` is the original heavy frost.
enum GlassStyle: String, CaseIterable {
    case clear, glass, frosted
    var title: String { rawValue.capitalized }
    var material: NSVisualEffectView.Material { self == .frosted ? .fullScreenUI : .hudWindow }
    var alpha: CGFloat { switch self { case .clear: return 0.55; case .glass: return 0.80; case .frosted: return 0.72 } }
}

struct HistoryPoint: Equatable {
    let cpu: Double, mem: Double
    static let interval: TimeInterval = 5
    static let slots = 120   // 10 minutes
}

enum Severity {
    case normal, warning, critical
    init(_ p: Double) {
        self = p >= 90 ? .critical : (p >= 75 ? .warning : .normal)
    }
    func color(_ p: Provider) -> Color {
        self == .critical ? Color(nsColor: .systemRed) : p.brand   // ring stays on-brand until it's critical
    }
}

@MainActor
final class UsageStore: ObservableObject {
    let provider: Provider
    init(_ provider: Provider) { self.provider = provider }
    @Published var limits: [Limit] = []
    @Published var error: String?
    @Published var updated: Date?
    private var timer: Timer?

    func start() {
        guard provider != .system else { return }   // sampled only while its panel is showing; see setSampling
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// Backoff state: after a 429 we don't hit the endpoint again until `nextAllowed`.
    private var nextAllowed = Date.distantPast
    private var backoff: TimeInterval = 300
    private var inFlight = false

    // System panel: kernel samples at 2 Hz while the panel is shown, every 5 s while hidden (history only).
    private var sampler: Timer?
    private var fast: Bool?
    private var lastTicks: [UInt32]?
    private var cpu: Double = 0
    /// One point per 5 s, newest last, capped at 10 minutes.
    @Published var history: [HistoryPoint] = []
    private var bucketTicks: [UInt32]?
    private var bucketStart = Date.distantPast

    func setSampling(_ on: Bool) {
        guard provider == .system, on != fast else { return }
        fast = on
        sampler?.invalidate()
        sample()
        let t = Timer(timeInterval: on ? 0.5 : HistoryPoint.interval, repeats: true) { _ in Task { @MainActor in self.sample() } }
        t.tolerance = on ? 0.05 : 1
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while a menu is open or the widget is dragged
        sampler = t
    }

    static func busyPercent(_ now: [UInt32], since then: [UInt32]) -> Double? {
        let d = zip(now, then).map { Double($0 &- $1) }   // tick counters wrap
        let total = d.reduce(0, +)
        return total > 0 ? (total - d[2]) / total * 100 : nil
    }

    private func sample() {
        let ticks = SystemStats.cpuTicks()
        if let ticks {
            if let l = lastTicks, let v = Self.busyPercent(ticks, since: l) { cpu = v }
            lastTicks = ticks
        }
        let m = SystemStats.memory()
        let memPercent = m.map { $0.total > 0 ? $0.used / $0.total * 100 : 0 }

        // History: CPU averaged over the whole 5 s bucket, memory as it stands.
        let now = Date()
        if now.timeIntervalSince(bucketStart) >= HistoryPoint.interval - 0.3 {
            let avg = ticks.flatMap { t in bucketTicks.flatMap { Self.busyPercent(t, since: $0) } } ?? cpu
            history.append(HistoryPoint(cpu: avg, mem: memPercent ?? 0))
            if history.count > HistoryPoint.slots { history.removeFirst(history.count - HistoryPoint.slots) }
            bucketTicks = ticks; bucketStart = now
        }
        guard fast == true else { return }   // hidden: nothing to draw

        var out: [Limit] = []
        if let m, m.total > 0 {
            let gb = 1_073_741_824.0
            let total = m.total / gb
            let totalText = total == total.rounded() ? String(Int(total)) : String(format: "%.1f", total)
            var l = Limit(id: "memory", label: "Memory", percent: memPercent ?? 0, resetsAt: nil,
                          detail: String(format: "%.1f/%@ GB", m.used / gb, totalText))
            l.level = SystemStats.pressure()
            out.append(l)
        }
        var load = [Double](repeating: 0, count: 1)
        let haveLoad = getloadavg(&load, 1) == 1
        out.append(Limit(id: "cpu", label: "CPU", percent: cpu, resetsAt: nil,
                         detail: haveLoad ? String(format: "load %.2f", load[0]) : nil))
        if out != limits { limits = out }
    }

    func refresh() {
        guard provider != .system, !inFlight, Date() >= nextAllowed else { return }
        inFlight = true
        let provider = self.provider
        Task.detached {
            let result = UsageStore.fetch(provider)
            await MainActor.run {
                self.inFlight = false
                switch result {
                case .success(let l):
                    self.limits = l; self.error = nil; self.updated = Date(); self.backoff = 300
                    self.nextAllowed = Date().addingTimeInterval(60)   // never more than once a minute, even on double-click/wake
                case .failure(let e):
                    if let wait = e.retryAfter {
                        let delay = min(max(wait, self.backoff), 3600)
                        self.backoff = min(self.backoff * 2, 3600)
                        self.nextAllowed = Date().addingTimeInterval(delay)
                        self.error = "Rate limited · retrying in \(Int((delay / 60).rounded(.up)))m"
                    } else {
                        self.error = e.message
                    }
                }
            }
        }
    }

    struct FetchError: Error { let message: String; var retryAfter: TimeInterval? = nil }

    nonisolated static func token() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String else { return nil }
        return tok
    }

    nonisolated static func send(_ req: URLRequest) -> (Int, Data?, TimeInterval?) {
        let sem = DispatchSemaphore(value: 0)
        var body: Data?, status = 0, retryAfter: TimeInterval?
        URLSession.shared.dataTask(with: req) { d, r, _ in
            let http = r as? HTTPURLResponse
            body = d; status = http?.statusCode ?? 0
            retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init).flatMap { $0.isFinite ? min(max($0, 0), 3600) : nil }
            sem.signal()
        }.resume()
        sem.wait()
        return (status, body, retryAfter)
    }

    nonisolated static func fetch(_ provider: Provider) -> Result<[Limit], FetchError> {
        let app = provider == .claude ? "Claude Code" : "Codex"
        var req: URLRequest
        switch provider {
        case .claude:
            guard let tok = token() else { return .failure(.init(message: "Log in to Claude Code with a Claude.ai plan")) }
            req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .codex:
            guard let (tok, account) = codexToken() else {
                return .failure(.init(message: codexUsesAPIKey() ? "Codex uses an API key · no plan limits" : "Log in to Codex with ChatGPT"))
            }
            req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            if let account { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        case .system:
            return .success([])   // never fetched; sampled locally
        }
        req.timeoutInterval = 15
        let (status, body, retryAfter) = send(req)

        if status == 429 { return .failure(.init(message: "Rate limited", retryAfter: retryAfter ?? 300)) }
        if status == 401 || status == 403 { return .failure(.init(message: "Login expired — open \(app)")) }
        guard status == 200, let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return .failure(.init(message: status == 0 ? "Offline" : "Error \(status)")) }
        return .success(provider == .claude ? parse(json) : parseCodex(json))
    }

    /// Codex CLI keeps its ChatGPT login in ~/.codex/auth.json.
    nonisolated static func codexToken() -> (String, String?)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let tok = tokens["access_token"] as? String else { return nil }
        return (tok, tokens["account_id"] as? String)
    }

    /// API-key Codex logins have no ChatGPT tokens, only OPENAI_API_KEY.
    nonisolated static func codexUsesAPIKey() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (obj["OPENAI_API_KEY"] as? String).map { !$0.isEmpty } ?? false
    }

    nonisolated static func parseCodex(_ json: [String: Any]) -> [Limit] {
        func window(_ w: Any?, id: String, fallback: String) -> Limit? {
            guard let w = w as? [String: Any] else { return nil }
            let pct = (w["used_percent"] as? Double) ?? (w["used_percent"] as? Int).map(Double.init) ?? 0
            let secs = (w["limit_window_seconds"] as? Double) ?? (w["limit_window_seconds"] as? Int).map(Double.init)
            let label: String
            switch secs {
            case .some(let s) where s >= 6 * 86400: label = "Week"
            case .some(let s) where s <= 6 * 3600: label = "Session"
            default: label = fallback
            }
            let reset = ((w["reset_at"] as? Double) ?? (w["reset_at"] as? Int).map(Double.init)).map { Date(timeIntervalSince1970: $0) }
            return Limit(id: id, label: label, percent: pct, resetsAt: reset)
        }
        var out: [Limit] = []
        if let rl = json["rate_limit"] as? [String: Any] {
            if let l = window(rl["primary_window"], id: "primary", fallback: "Session") { out.append(l) }
            if let l = window(rl["secondary_window"], id: "secondary", fallback: "Week") { out.append(l) }
        }
        if let extra = json["additional_rate_limits"] as? [[String: Any]] {
            for (i, e) in extra.enumerated() {
                let name = (e["limit_name"] as? String) ?? (e["metered_feature"] as? String) ?? "Extra"
                let rl = (e["rate_limit"] as? [String: Any]) ?? e
                if let l = window(rl["primary_window"], id: "extra-\(i)", fallback: name.capitalized) { out.append(l) }
            }
        }
        return out
    }

    nonisolated static func parseDate(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    nonisolated static func parse(_ json: [String: Any]) -> [Limit] {
        var out: [Limit] = []
        // Session (5-hour) window lives at the top level.
        if let fh = json["five_hour"] as? [String: Any], let u = fh["utilization"] as? Double {
            out.append(Limit(id: "five_hour", label: "Session", percent: u, resetsAt: parseDate(fh["resets_at"])))
        }
        if let limits = json["limits"] as? [[String: Any]] {
            for (i, l) in limits.enumerated() {
                guard let pct = (l["percent"] as? Double) ?? (l["percent"] as? Int).map(Double.init) else { continue }
                let kind = l["kind"] as? String ?? "limit"
                let group = l["group"] as? String ?? ""
                let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let label: String
                if let model { label = model }
                else if kind == "weekly_all" { label = "Week" }
                else if group.contains("session") || kind.contains("five") || kind.contains("session") {
                    if out.contains(where: { $0.id == "five_hour" }) { continue }
                    label = "Session"
                } else { label = group.isEmpty ? kind : group.capitalized }
                out.append(Limit(id: "\(kind)-\(model ?? "")-\(i)", label: label, percent: pct, resetsAt: parseDate(l["resets_at"])))
            }
        } else {
            // Fallback for older response shape.
            for (key, label) in [("seven_day", "Week"), ("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
                if let w = json[key] as? [String: Any], let u = w["utilization"] as? Double {
                    out.append(Limit(id: key, label: label, percent: u, resetsAt: parseDate(w["resets_at"])))
                }
            }
        }
        return out
    }
}

// MARK: - Views

func agoText(_ d: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

func resetText(_ d: Date?, now: Date) -> String {
    guard let d else { return " " }
    let s = Int(min(max(0, d.timeIntervalSince(now)), 1e9))
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 { return "\(days)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

struct Ring: View {
    let limit: Limit
    let now: Date
    let provider: Provider
    var delay: Double = 0
    private let size: CGFloat = 58
    private let line: CGFloat = 6
    @State private var shown: Double = 0   // drawn fraction; animates up from 0 when the ring appears

    var body: some View {
        let sev = limit.level ?? Severity(limit.percent)
        let frac = min(max(limit.percent / 100, 0), 1)
        let color = sev.color(provider)
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(provider.brand.opacity(0.14), lineWidth: line)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.75), color],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(shown, 0.01))),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.45), radius: 3)
                    .opacity(shown > 0.002 ? 1 : 0)
                HStack(spacing: 0) {
                    Text("\(Int(limit.percent.rounded()))")
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                    Text("%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .baselineOffset(1)
                }
                .monospacedDigit()
            }
            .frame(width: size, height: size)

            HStack(spacing: 3) {
                if sev != .normal {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(sev == .critical ? Color(nsColor: .systemRed) : Color(nsColor: .systemOrange))
                }
                Text(limit.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text(limit.detail ?? resetText(limit.resetsAt, now: now))
                .font(.system(size: 10))
                .lineLimit(1)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 70)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.82).delay(0.12 + delay)) { shown = frac }
        }
        .onChange(of: frac) { v in
            // Live readings snap: animating the ring on every sample cost ~9% CPU when measured; snapping costs ~2%.
            if provider == .system { shown = v } else { withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { shown = v } }
        }
        .help("\(limit.label): \(Int(limit.percent.rounded()))% used\(limit.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name) \(limit.label), \(Int(limit.percent.rounded())) percent used, \(limit.detail ?? "resets in \(resetText(limit.resetsAt, now: now))")")
    }
}

/// A 0–100% series drawn right-aligned on a fixed 10-minute axis, so the line grows in from the right as history fills.
struct Spark: Shape {
    let values: [Double]
    var filled = false
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let step = rect.width / CGFloat(HistoryPoint.slots - 1)
        let pts = values.enumerated().map { i, v in
            CGPoint(x: rect.maxX - CGFloat(values.count - 1 - i) * step,
                    y: rect.maxY - 1 - CGFloat(min(max(v, 0), 100) / 100) * (rect.height - 2))
        }
        p.addLines(pts)
        if filled {
            p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: rect.maxY))
            p.addLine(to: CGPoint(x: pts[0].x, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

/// Past 10 minutes of CPU (accent line + fill) and memory (neutral line). Equatable so it only redraws when a point is added.
struct HistoryGraph: View, Equatable {
    let points: [HistoryPoint]
    let color: Color
    var body: some View {
        let box = RoundedRectangle(cornerRadius: 7, style: .continuous)
        VStack(spacing: 4) {
            ZStack {
                box.fill(Color.primary.opacity(0.05))
                Spark(values: points.map(\.cpu), filled: true)
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Spark(values: points.map(\.mem))
                    .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                Spark(values: points.map(\.cpu))
                    .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 36)
            .clipShape(box)
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text("CPU")
                Circle().fill(Color.primary.opacity(0.5)).frame(width: 5, height: 5).padding(.leading, 5)
                Text("Memory")
                Spacer(minLength: 8)
                Text("10 min").foregroundStyle(.tertiary)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU and memory over the past 10 minutes")
    }
}

/// One provider's rings, sized to fit. Also used off-screen to measure the target window size.
struct ProviderContent: View {
    @ObservedObject var store: UsageStore
    let now: Date

    var body: some View {
        let p = store.provider
        Group {
            if store.limits.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(p.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(p.brand)
                    HStack(spacing: 8) {
                        if store.error == nil { ProgressView().controlSize(.small) }
                        Text(store.error ?? "Loading usage…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 160, minHeight: 60, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(p.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(p.brand)
                        .padding(.leading, 2)
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(store.limits.enumerated()), id: \.element.id) { i, l in
                            Ring(limit: l, now: now, provider: p, delay: Double(i) * 0.06)
                        }
                    }
                    if p == .system {
                        HistoryGraph(points: store.history, color: p.brand).equatable()
                    }
                    if let e = store.error {
                        Text(e).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                // Last successful check, top-right on the same line as the name.
                .overlay(alignment: .topTrailing) {
                    if let u = store.updated {
                        Text(agoText(u, now: now))
                            .font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .padding(.top, 0.5)
                            .help("Checked \(u.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .fixedSize()
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selected: Provider
    let stores: [Provider: UsageStore] = [.claude: UsageStore(.claude), .codex: UsageStore(.codex), .system: UsageStore(.system)]
    init(selected: Provider) { self.selected = selected }
    var current: UsageStore { stores[selected]! }
}

/// Outgoing rings blur, shrink and fade; incoming ones resolve out of the blur.
struct GlassSwap: ViewModifier {
    let amount: Double
    func body(content: Content) -> some View {
        content
            .blur(radius: amount * 10)
            .scaleEffect(1 - amount * 0.08)
            .opacity(1 - amount)
    }
}

struct WidgetView: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            ZStack {
                GlassBackground()
                ProviderContent(store: state.current, now: ctx.date)
                    .id(state.selected)
                    .transition(reduceMotion ? .opacity
                                : .modifier(active: GlassSwap(amount: 1), identity: GlassSwap(amount: 0)))
                GlassRim()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .help("Click to show \(state.selected.other.name)")
    }
}

/// Reads Caps Lock (set == nil) or forces it on/off. Used to undo the flip that ⌘⇪ causes.
@discardableResult
func capsLock(_ set: Bool? = nil) -> Bool? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var conn: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &conn) == KERN_SUCCESS else { return nil }
    defer { IOServiceClose(conn) }
    if let set { return IOHIDSetModifierLockState(conn, Int32(kIOHIDCapsLockState), set) == KERN_SUCCESS ? set : nil }
    var on = false
    return IOHIDGetModifierLockState(conn, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS ? on : nil
}

/// The always-on memory + CPU panel, pinned separately from the usage widget.
struct SystemView: View {
    let store: UsageStore
    var body: some View {
        ZStack {
            GlassBackground()
            ProviderContent(store: store, now: Date())
            GlassRim()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

let panelRadius: CGFloat = 24
let deskSwitchID = "local.caleb.deskswitch"

/// Liquid Glass imitation for macOS 15: tint + top sheen over the native blur.
struct GlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            ZStack {
                shape.fill(scheme == .dark ? Color.black.opacity(0.04) : Color.white.opacity(0.06))
                shape.fill(LinearGradient(
                    stops: [.init(color: .white.opacity(scheme == .dark ? 0.06 : 0.14), location: 0),
                            .init(color: .white.opacity(0), location: 0.35)],
                    startPoint: .top, endPoint: .bottom))
                    .blendMode(.plusLighter)
            }
        }
    }
}

/// Specular edge: bright where light hits the top-left, fading round the sides, faint return at the bottom.
struct GlassRim: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(LinearGradient(
                stops: [.init(color: .white.opacity(scheme == .dark ? 0.16 : 0.28), location: 0),
                        .init(color: .white.opacity(0), location: 0.22)],
                startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .blendMode(.plusLighter)
            shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.05), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Stretchable mask for the behind-window blur (continuous corners stay fixed while the middle stretches),
/// so the blur keeps its shape while the window animates between sizes.
func glassMask() -> NSImage {
    let cap = ceil(panelRadius * 1.6)
    let side = cap * 2 + 1
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addPath(RoundedRectangle(cornerRadius: panelRadius, style: .continuous).path(in: rect).cgPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        return true
    }
    img.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    img.resizingMode = .stretch
    return img
}

// MARK: - Window

/// SwiftUI sits on top and swallows clicks, so click / drag / menu handling lives here.
/// A click (under 3pt of movement) toggles the provider; anything more moves the window.
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var startMouse: NSPoint = .zero
    private var startOrigin: NSPoint = .zero
    private var tracking = false
    private var dragged = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        tracking = true; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard tracking, let window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        if !dragged && hypot(dx, dy) > 3 { dragged = true }
        if dragged { window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if tracking && !dragged { onClick?() }
        tracking = false
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class VisualEffectHost: NSView {
    var onRightClick: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let defaults = UserDefaults.standard
    lazy var state = AppState(selected: defaults.string(forKey: "provider") == "codex" ? .codex : .claude)
    var panel: FloatingPanel!
    var systemPanel: FloatingPanel!
    var host: InteractiveHostingView<WidgetView>!
    var blurs: [NSVisualEffectView] = []
    var statusItem: NSStatusItem!
    private var lastHotkey = Date.distantPast
    private var animatingUntil = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        guard Installer.ensureInstalled() else { return }   // relaunching from ~/Applications
        host = InteractiveHostingView(rootView: WidgetView(state: state))
        host.onClick = { [weak self] in self?.toggle() }
        panel = makePanel(host)
        systemPanel = makePanel(InteractiveHostingView(rootView: SystemView(store: state.stores[.system]!)))
        applyGlass(GlassStyle(rawValue: defaults.string(forKey: "glass") ?? "") ?? .glass)

        for (p, key) in [(panel!, "topLeft"), (systemPanel!, "systemTopLeft")] {
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
                Task { @MainActor in
                    guard p.isVisible else { return }
                    self.defaults.set([p.frame.minX, p.frame.maxY], forKey: key)
                }
            }
        }

        state.stores.values.forEach { $0.start() }
        panel.setContentSize(measure(state.selected))
        if let tl = defaults.array(forKey: "topLeft") as? [CGFloat], tl.count == 2 {
            panel.setFrameTopLeftPoint(NSPoint(x: tl[0], y: tl[1]))
        } else if let s = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: s.maxX - panel.frame.width - 20, y: s.maxY - 20))
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Headroom")
            b.toolTip = "Click to show/hide the widgets (⌘⇪) · Right-click to choose which"
            b.target = self; b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        state.stores[.system]!.setSampling(false)   // history collects from launch, shown or not
        setVisible(usage: defaults.object(forKey: "showUsage") as? Bool ?? true,
                   system: defaults.object(forKey: "showSystem") as? Bool ?? true)
        installHotkey()
        // Keep the Desk Switch button in step, including when it starts after us at login.
        postDesk()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == deskSwitchID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { self.postDesk() } }
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.state.stores.values.forEach { $0.refresh() } }
        }
        // Follow content size as limits load / appear / disappear.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in if Date() > self.animatingUntil { self.resize(to: self.measure(self.state.selected), animated: true) } }
        }
    }

    /// A borderless always-on-top glass panel hosting `host`: blur underneath, SwiftUI on top.
    func makePanel<V: View>(_ host: InteractiveHostingView<V>) -> FloatingPanel {
        let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.alphaValue = defaults.object(forKey: "opacity") as? CGFloat ?? 1.0

        let fx = VisualEffectHost()
        // Blur sits in its own layer at reduced alpha so the desktop reads through more clearly;
        // the rings stay at full opacity above it.
        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = glassMask()
        blur.frame = fx.bounds
        blur.autoresizingMask = [.width, .height]
        fx.addSubview(blur)
        blurs.append(blur)
        fx.onRightClick = { [weak self] e in self?.showMenu(e) }
        host.onRightClick = { [weak self] e in self?.showMenu(e) }
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        panel.contentView = fx
        return panel
    }

    /// Show or hide the memory + CPU panel; while hidden it only keeps the history going (one sample per 5 s).
    func setSystemVisible(_ on: Bool) {
        state.stores[.system]!.setSampling(on)
        guard on else { systemPanel.orderOut(nil); return }
        systemPanel.setContentSize(measure(.system))
        if let tl = defaults.array(forKey: "systemTopLeft") as? [CGFloat], tl.count == 2 {
            systemPanel.setFrameTopLeftPoint(NSPoint(x: tl[0], y: tl[1]))
        } else {
            // First run: directly under the usage widget, or above it when there's no room below.
            // The widget may still be in its short loading state, so assume it will grow to ring height.
            let f = panel.frame, h = systemPanel.frame.height
            let below = f.maxY - max(f.height, 144) - 10   // 144 = the widget's height once its rings load
            let floor = (panel.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
            systemPanel.setFrameTopLeftPoint(NSPoint(x: f.minX, y: below - h >= floor ? below : f.maxY + 10 + h))
        }
        systemPanel.orderFrontRegardless()
    }

    // MARK: Show / hide

    // Desk Switch is a separate app with its own floating button; it follows a distributed notification from us.
    var deskRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: deskSwitchID).isEmpty }
    var deskWanted: Bool { defaults.object(forKey: "showDesk") as? Bool ?? true }
    var deskShown: Bool { deskRunning && deskWanted }
    func postDesk() {
        DistributedNotificationCenter.default().postNotificationName(
            .init("local.usagerings.visibility.desk"), object: deskWanted ? "show" : "hide", userInfo: nil, deliverImmediately: true)
    }

    /// Show exactly these panels (desk: nil leaves the Desk Switch button alone); the choice survives relaunch.
    func setVisible(usage: Bool, system: Bool, desk: Bool? = nil) {
        if usage != panel.isVisible { if usage { panel.orderFrontRegardless() } else { panel.orderOut(nil) } }
        if system != systemPanel.isVisible { setSystemVisible(system) }
        defaults.set(usage, forKey: "showUsage")
        defaults.set(system, forKey: "showSystem")
        if let desk { defaults.set(desk, forKey: "showDesk"); postDesk() }
        statusItem.button?.appearsDisabled = !(usage || system || deskShown)
    }

    /// Menu-bar button and ⌘⇪: hide whatever is showing, or bring back the set that was showing before.
    @objc func toggleAll() {
        let u = panel.isVisible, s = systemPanel.isVisible, d = deskShown
        if u || s || d {
            defaults.set([u, s, d], forKey: "lastShown")
            setVisible(usage: false, system: false, desk: deskRunning ? false : nil)
        } else {
            let last = defaults.array(forKey: "lastShown") as? [Bool] ?? []
            var show = [last.count > 0 ? last[0] : true, last.count > 1 ? last[1] : true, last.count > 2 ? last[2] : true]
            if !(show[0] || show[1] || (deskRunning && show[2])) { show = [true, true, true] }   // never restore to nothing
            setVisible(usage: show[0], system: show[1], desk: deskRunning ? show[2] : nil)
        }
    }
    @objc func toggleUsage() { setVisible(usage: !panel.isVisible, system: systemPanel.isVisible) }
    @objc func toggleSystem() { setVisible(usage: panel.isVisible, system: !systemPanel.isVisible) }
    @objc func toggleDesk() { setVisible(usage: panel.isVisible, system: systemPanel.isVisible, desk: !deskShown) }

    func addVisibilityItems(_ m: NSMenu) {
        let any = panel.isVisible || systemPanel.isVisible || deskShown
        m.addItem(withTitle: "\(any ? "Hide" : "Show") Widgets   ⌘⇪", action: #selector(toggleAll), keyEquivalent: "").target = self
        for (title, sel, on) in [("Claude / Codex Usage", #selector(toggleUsage), panel.isVisible),
                                 ("System Monitor", #selector(toggleSystem), systemPanel.isVisible)] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off
            m.addItem(i)
        }
        if deskRunning {
            let i = NSMenuItem(title: "Desk Switch Button", action: #selector(toggleDesk), keyEquivalent: "")
            i.target = self; i.state = deskShown ? .on : .off
            m.addItem(i)
        }
    }

    @objc func statusClicked() {
        let e = NSApp.currentEvent
        guard e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true else { toggleAll(); return }
        let m = NSMenu()
        addVisibilityItems(m)
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Headroom", action: #selector(quit), keyEquivalent: "").target = self
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // so a plain click toggles again
    }

    /// ⌘ + Caps Lock from any app. Modifier-only events reach a global monitor without Accessibility permission.
    func installHotkey() {
        let handle: (NSEvent) -> Void = { [weak self] e in
            guard e.keyCode == 57,   // the physical Caps Lock key; our own state restore reports 255
                  e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command else { return }
            Task { @MainActor in self?.hotkey() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { handle($0); return $0 }
    }

    func hotkey() {
        guard Date().timeIntervalSince(lastHotkey) > 0.4 else { return }   // one toggle per press
        lastHotkey = Date()
        if let on = capsLock() { capsLock(!on) }   // the press just flipped Caps Lock; put it back
        toggleAll()
    }

    /// Size the given provider's content wants, measured off-screen.
    func measure(_ p: Provider) -> NSSize {
        NSHostingView(rootView: ProviderContent(store: state.stores[p]!, now: Date())).fittingSize
    }

    /// Morph the window to `size`, keeping whichever side is nearer the screen edge pinned, and the top edge fixed.
    func resize(to size: NSSize, animated: Bool) {
        guard size.width > 0 else { return }
        let f = panel.frame
        guard abs(f.width - size.width) > 0.5 || abs(f.height - size.height) > 0.5 else { return }
        let screenMid = (panel.screen ?? NSScreen.main)?.visibleFrame.midX ?? f.midX
        let x = f.midX > screenMid ? f.maxX - size.width : f.minX
        let target = NSRect(x: x, y: f.maxY - size.height, width: size.width, height: size.height)
        if animated {
            animatingUntil = Date().addingTimeInterval(0.6)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { Task { @MainActor in self.panel.invalidateShadow() } })
        } else {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
        }
    }

    func toggle() {
        let next = state.selected.other
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)) {
            state.selected = next
        }
        resize(to: measure(next), animated: !reduce)
        defaults.set(next.rawValue, forKey: "provider")
    }

    func showMenu(_ e: NSEvent) {
        let m = NSMenu()
        let sys = e.window === systemPanel   // the System panel has no provider to switch or refresh
        let target: Provider = sys ? .system : state.selected
        if !sys, let u = state.current.updated {
            let i = NSMenuItem(title: "\(state.selected.name) · updated \(u.formatted(date: .omitted, time: .shortened))", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
            m.addItem(.separator())
        }
        if !sys {
            m.addItem(withTitle: "Show \(state.selected.other.name)", action: #selector(toggleFromMenu), keyEquivalent: "").target = self
            m.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
            m.addItem(.separator())
        }
        addVisibilityItems(m)
        m.addItem(.separator())
        let op = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [1.0, 0.85, 0.7, 0.5] {
            let i = NSMenuItem(title: "\(Int(v * 100))%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = v
            i.state = abs(panel.alphaValue - v) < 0.01 ? .on : .off
            sub.addItem(i)
        }
        op.submenu = sub
        m.addItem(op)
        let gl = NSMenuItem(title: "Glass", action: nil, keyEquivalent: "")
        let gsub = NSMenu()
        let current = GlassStyle(rawValue: defaults.string(forKey: "glass") ?? "") ?? .glass
        for g in GlassStyle.allCases {
            let i = NSMenuItem(title: g.title, action: #selector(setGlass(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = g.rawValue
            i.state = g == current ? .on : .off
            gsub.addItem(i)
        }
        gl.submenu = gsub
        m.addItem(gl)
        let open = NSMenuItem(title: target.usageTitle, action: #selector(openUsage(_:)), keyEquivalent: "")
        open.target = self; open.representedObject = target.rawValue
        m.addItem(open)
        m.addItem(.separator())
        m.addItem(withTitle: "Uninstall Headroom…", action: #selector(uninstall), keyEquivalent: "").target = self
        m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        NSMenu.popUpContextMenu(m, with: e, for: e.window?.contentView ?? panel.contentView!)
    }

    @objc func toggleFromMenu() { toggle() }

    @objc func refresh() { state.current.refresh() }
    @objc func setOpacity(_ s: NSMenuItem) {
        let v = s.representedObject as! Double
        panel.alphaValue = v
        systemPanel.alphaValue = v
        defaults.set(v, forKey: "opacity")
    }
    @objc func setGlass(_ s: NSMenuItem) {
        guard let g = GlassStyle(rawValue: s.representedObject as? String ?? "") else { return }
        applyGlass(g)
        defaults.set(g.rawValue, forKey: "glass")
    }
    func applyGlass(_ g: GlassStyle) {
        for blur in blurs { blur.material = g.material; blur.alphaValue = g.alpha }
    }
    @objc func openUsage(_ s: NSMenuItem) {
        NSWorkspace.shared.open((Provider(rawValue: s.representedObject as? String ?? "") ?? state.selected).usageURL)
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall Headroom?"
        a.informativeText = "Removes the app, its login item and its settings."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Installer.uninstall()
        NSApp.terminate(nil)
    }
}

// MARK: - Self-install

/// Double-click install: on first launch from anywhere (e.g. Downloads) the app copies itself
/// to ~/Applications, registers a login item, relaunches the copy and quits.
@MainActor
enum Installer {
    /// Bundle ID kept from the UsageRings days so upgrades replace the old app, its login item and settings.
    static let id = Bundle.main.bundleIdentifier ?? "local.usagerings"
    static var fm: FileManager { .default }
    static var dest: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Headroom.app") }
    static var oldDest: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/UsageRings.app") }
    static var agent: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(id).plist") }

    /// true = we're the installed copy, carry on; false = a relaunch is under way, stop.
    static func ensureInstalled() -> Bool {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        if here.path == dest.resolvingSymlinksInPath().standardizedFileURL.path || here.pathExtension != "app" {
            if fm.fileExists(atPath: oldDest.path) { try? fm.trashItem(at: oldDest, resultingItemURL: nil) }   // pre-rename copy
            writeLoginItem()
            return true
        }
        // Replace any copy that's already running/installed.
        for a in NSRunningApplication.runningApplications(withBundleIdentifier: id) where a != .current { a.forceTerminate() }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: here, to: dest)
        } catch {
            writeLoginItem()   // can't install (permissions?) — just run from where we are
            return true
        }
        let x = Process()
        x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        x.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? x.run(); x.waitUntilExit()

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, err in
            DispatchQueue.main.async {
                if err == nil { NSApp.terminate(nil) }
            }
        }
        return false
    }

    static func writeLoginItem() {
        let plist: [String: Any] = [
            "Label": id,
            "ProgramArguments": ["/usr/bin/open", "-a", dest.path],
            "RunAtLoad": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? Data(contentsOf: agent)) != data else { return }
        try? fm.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: agent)
    }

    static func uninstall() {
        try? fm.removeItem(at: agent)
        UserDefaults.standard.removePersistentDomain(forName: id)
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
