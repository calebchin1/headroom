import AppKit
import SwiftUI

// MARK: - Model

struct Limit: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    init(id: String, label: String, percent: Double, resetsAt: Date?) {
        self.id = id; self.label = label
        self.percent = percent.isFinite ? min(max(percent, 0), 999) : 0   // Int() traps on inf/NaN/huge
        self.resetsAt = resetsAt
    }
}

/// Both providers live in one widget; a click swaps which one is showing.
enum Provider: String, CaseIterable {
    case claude, codex
    var other: Provider { self == .claude ? .codex : .claude }

    var name: String { self == .claude ? "Claude" : "Codex" }
    /// Brand colours: Claude terracotta, OpenAI/ChatGPT green.
    var brand: Color {
        self == .claude ? Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
                        : Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)
    }
    var usageURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
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
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    /// Backoff state: after a 429 we don't hit the endpoint again until `nextAllowed`.
    private var nextAllowed = Date.distantPast
    private var backoff: TimeInterval = 300
    private var inFlight = false

    func refresh() {
        guard !inFlight, Date() >= nextAllowed else { return }
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
        let sev = Severity(limit.percent)
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
            Text(resetText(limit.resetsAt, now: now))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 70)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.82).delay(0.12 + delay)) { shown = frac }
        }
        .onChange(of: frac) { v in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { shown = v }
        }
        .help("\(limit.label): \(Int(limit.percent.rounded()))% used\(limit.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.name) \(limit.label), \(Int(limit.percent.rounded())) percent used, resets in \(resetText(limit.resetsAt, now: now))")
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
    let stores: [Provider: UsageStore] = [.claude: UsageStore(.claude), .codex: UsageStore(.codex)]
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

let panelRadius: CGFloat = 24

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
    lazy var state = AppState(selected: Provider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .claude)
    var panel: FloatingPanel!
    var host: InteractiveHostingView<WidgetView>!
    let blur = NSVisualEffectView()
    private var animatingUntil = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        guard Installer.ensureInstalled() else { return }   // relaunching from ~/Applications
        panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0.72
        blur.maskImage = glassMask()
        blur.frame = fx.bounds
        blur.autoresizingMask = [.width, .height]
        fx.addSubview(blur)
        fx.onRightClick = { [weak self] e in self?.showMenu(e) }

        host = InteractiveHostingView(rootView: WidgetView(state: state))
        host.onClick = { [weak self] in self?.toggle() }
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

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
            Task { @MainActor in
                let f = self.panel.frame
                self.defaults.set([f.minX, f.maxY], forKey: "topLeft")
            }
        }

        state.stores.values.forEach { $0.start() }
        panel.setContentSize(measure(state.selected))
        if let tl = defaults.array(forKey: "topLeft") as? [CGFloat], tl.count == 2 {
            panel.setFrameTopLeftPoint(NSPoint(x: tl[0], y: tl[1]))
        } else if let s = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: s.maxX - panel.frame.width - 20, y: s.maxY - 20))
        }
        panel.orderFrontRegardless()

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.state.stores.values.forEach { $0.refresh() } }
        }
        // Follow content size as limits load / appear / disappear.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in if Date() > self.animatingUntil { self.resize(to: self.measure(self.state.selected), animated: true) } }
        }
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
        if let u = state.current.updated {
            let i = NSMenuItem(title: "\(state.selected.name) · updated \(u.formatted(date: .omitted, time: .shortened))", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Show \(state.selected.other.name)", action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        m.addItem(withTitle: "Refresh Now", action: #selector(refresh), keyEquivalent: "r").target = self
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
        m.addItem(withTitle: "Open \(state.selected.name) Usage Page", action: #selector(openUsage), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Uninstall UsageRings…", action: #selector(uninstall), keyEquivalent: "").target = self
        m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        NSMenu.popUpContextMenu(m, with: e, for: panel.contentView!)
    }

    @objc func toggleFromMenu() { toggle() }
    @objc func refresh() { state.current.refresh() }
    @objc func setOpacity(_ s: NSMenuItem) {
        let v = s.representedObject as! Double
        panel.alphaValue = v
        defaults.set(v, forKey: "opacity")
    }
    @objc func openUsage() { NSWorkspace.shared.open(state.selected.usageURL) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func uninstall() {
        let a = NSAlert()
        a.messageText = "Uninstall UsageRings?"
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
    static let id = Bundle.main.bundleIdentifier ?? "local.usagerings"
    static var fm: FileManager { .default }
    static var dest: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/UsageRings.app") }
    static var agent: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(id).plist") }

    /// true = we're the installed copy, carry on; false = a relaunch is under way, stop.
    static func ensureInstalled() -> Bool {
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        if here.path == dest.resolvingSymlinksInPath().standardizedFileURL.path || here.pathExtension != "app" {
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
