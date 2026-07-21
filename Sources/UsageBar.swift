import SwiftUI
import AppKit
import Security

// MARK: - Models

struct ModelLimit {
    let name: String
    let percent: Double
    let reset: Date?
}

struct ProviderUsage {
    // nil = the provider does not report this window; the row is hidden
    var sessionPercent: Double?
    var sessionReset: Date?
    var weeklyPercent: Double?
    var weeklyReset: Date?
    var modelLimits: [ModelLimit] = []
    var error: String?
}

struct AppState {
    var claude = ProviderUsage()
    var codex = ProviderUsage()
    var lastUpdated: Date?
}

// MARK: - Claude API

struct ClaudeCredentials: Codable {
    struct OAuth: Codable {
        let accessToken: String
        let expiresAt: Int64?
    }
    let claudeAiOauth: OAuth

    var isExpired: Bool {
        guard let exp = claudeAiOauth.expiresAt else { return false }
        return Double(exp) / 1000 < Date().timeIntervalSince1970
    }
}

struct ClaudeUsageResponse: Codable {
    struct Limit: Codable {
        let usedPercent: Double?
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case utilization; case resetsAt = "resets_at" }
    }
    struct LimitEntry: Codable {
        struct Scope: Codable {
            struct Model: Codable {
                let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
        enum CodingKeys: String, CodingKey { case kind, percent, scope; case resetsAt = "resets_at" }
    }
    let fiveHour: Limit?
    let sevenDay: Limit?
    let sessionRateLimit: Limit?
    let weeklyRateLimit: Limit?
    let limits: [LimitEntry]?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sessionRateLimit = "session_rate_limit"
        case weeklyRateLimit = "weekly_rate_limit"
        case limits
    }
}

struct ClaudeStatuslineDebug: Codable {
    struct RateLimits: Codable {
        struct Window: Codable {
            let usedPercentage: Double?
            let resetsAt: Int64?
            enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage"; case resetsAt = "resets_at" }
        }
        let fiveHour: Window?
        let sevenDay: Window?
        enum CodingKeys: String, CodingKey { case fiveHour = "five_hour"; case sevenDay = "seven_day" }
    }
    let rateLimits: RateLimits?
    enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
}

// MARK: - Codex API

struct CodexCredentials: Codable {
    struct Tokens: Codable {
        let accessToken: String
        let accountId: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case accountId = "account_id" }
    }
    let tokens: Tokens
}

struct CodexUsageResponse: Codable {
    struct RateLimit: Codable {
        struct Window: Codable {
            let usedPercent: Int?
            let resetAt: Int64?
            let limitWindowSeconds: Int64?
            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case resetAt = "reset_at"
                case limitWindowSeconds = "limit_window_seconds"
            }
        }
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" }
    }
    struct AdditionalRateLimit: Codable {
        let limitName: String?
        let rateLimit: RateLimit?
        enum CodingKeys: String, CodingKey { case limitName = "limit_name"; case rateLimit = "rate_limit" }
    }
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?
    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }
}

// MARK: - API Client

class UsageAPI {
    static let shared = UsageAPI()

    private var lastGoodClaude: ProviderUsage?
    private var lastGoodCodex: ProviderUsage?

    func fetchAll() async -> AppState {
        var state = AppState()
        state.lastUpdated = Date()

        async let c = fetchClaude()
        async let x = fetchCodex()

        // On transient errors (429 etc.) keep showing the last good data
        // instead of replacing the whole section with an error label.
        let claude = await c
        if claude.error == nil { lastGoodClaude = claude }
        state.claude = claude.error != nil ? (lastGoodClaude ?? claude) : claude

        let codex = await x
        if codex.error == nil { lastGoodCodex = codex }
        state.codex = codex.error != nil ? (lastGoodCodex ?? codex) : codex

        return state
    }

    private func fetchClaude() async -> ProviderUsage {
        if let local = fetchClaudeFromStatusline() {
            return local
        }

        var u = ProviderUsage()

        let auth = fetchClaudeAccessToken()
        guard let token = auth.token else {
            u.error = auth.error ?? "No auth"
            return u
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                u.error = "Network"
                return u
            }
            guard http.statusCode == 200 else {
                u.error = http.statusCode == 429 ? "Rate limit" : "API \(http.statusCode)"
                return u
            }
            let r = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            if let s = r.fiveHour ?? r.sessionRateLimit {
                u.sessionPercent = s.usedPercent ?? s.utilization ?? 0
                if let t = s.resetsAt { u.sessionReset = parseISO(t) }
            }
            if let w = r.sevenDay ?? r.weeklyRateLimit {
                u.weeklyPercent = w.usedPercent ?? w.utilization ?? 0
                if let t = w.resetsAt { u.weeklyReset = parseISO(t) }
            }
            // Model-scoped weekly limits (e.g. Fable/Opus) from the newer `limits` array
            for l in r.limits ?? [] where l.kind == "weekly_scoped" {
                guard let name = l.scope?.model?.displayName else { continue }
                u.modelLimits.append(ModelLimit(name: name,
                                                percent: l.percent ?? 0,
                                                reset: l.resetsAt.flatMap(parseISO)))
            }
        } catch {
            u.error = "Error"
        }
        return u
    }

    private func fetchClaudeFromStatusline() -> ProviderUsage? {
        let path = NSHomeDirectory() + "/.claude/statusline-debug.json"
        // Only trust the cached file when it was written very recently
        // (i.e. an active Claude Code session is producing fresh data).
        // Otherwise the values may belong to a previous account/session
        // and we should hit the live API instead.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < 60 else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path),
              let debug = try? JSONDecoder().decode(ClaudeStatuslineDebug.self, from: data),
              debug.rateLimits != nil else {
            return nil
        }

        var u = ProviderUsage()
        if let s = debug.rateLimits?.fiveHour {
            u.sessionPercent = s.usedPercentage ?? 0
            if let t = s.resetsAt { u.sessionReset = Date(timeIntervalSince1970: Double(t)) }
        }
        if let w = debug.rateLimits?.sevenDay {
            u.weeklyPercent = w.usedPercentage ?? 0
            if let t = w.resetsAt { u.weeklyReset = Date(timeIntervalSince1970: Double(t)) }
        }
        return u
    }

    private func fetchClaudeAccessToken() -> (token: String?, error: String?) {
        // macOS keeps the live token in the login keychain; a leftover
        // ~/.claude/.credentials.json may hold a long-expired one. Prefer
        // whichever source is not expired (keychain first).
        var fileError: String?
        var fileToken: String?
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: path) {
            if let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) {
                if creds.isExpired {
                    fileError = "Auth expired"
                } else {
                    fileToken = creds.claudeAiOauth.accessToken
                }
            } else {
                fileError = "Auth format"
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
                return (fileToken, fileToken != nil ? nil : "Auth format")
            }
            if creds.isExpired {
                return (fileToken, fileToken != nil ? nil : "Auth expired")
            }
            return (creds.claudeAiOauth.accessToken, nil)
        case errSecItemNotFound:
            return (fileToken, fileToken != nil ? nil : (fileError ?? "No auth"))
        case errSecInteractionNotAllowed:
            return (fileToken, fileToken != nil ? nil : "Keychain locked")
        case errSecAuthFailed, errSecUserCanceled:
            return (fileToken, fileToken != nil ? nil : "Keychain denied")
        default:
            return (fileToken, fileToken != nil ? nil : "Keychain \(status)")
        }
    }

    private func fetchCodex() async -> ProviderUsage {
        var u = ProviderUsage()
        let path = NSHomeDirectory() + "/.codex/auth.json"

        guard let data = FileManager.default.contents(atPath: path) else {
            u.error = "No auth"
            return u
        }
        guard let creds = try? JSONDecoder().decode(CodexCredentials.self, from: data) else {
            u.error = "Auth format"
            return u
        }

        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(creds.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.tokens.accountId, forHTTPHeaderField: "Chatgpt-Account-Id")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                u.error = "Network"
                return u
            }
            guard http.statusCode == 200 else {
                u.error = http.statusCode == 429 ? "Rate limit" : "API \(http.statusCode)"
                return u
            }
            let r = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            // Windows are classified by their actual duration, not their
            // position: the API nowadays reports the weekly limit as
            // primary_window (secondary is null), so primary != 5h.
            let windows = [(r.rateLimit?.primaryWindow, false), (r.rateLimit?.secondaryWindow, true)]
            for (w, positionalWeekly) in windows {
                guard let w else { continue }
                let isWeekly = w.limitWindowSeconds.map { $0 >= 86400 } ?? positionalWeekly
                if isWeekly {
                    u.weeklyPercent = Double(w.usedPercent ?? 0)
                    if let t = w.resetAt { u.weeklyReset = Date(timeIntervalSince1970: Double(t)) }
                } else {
                    u.sessionPercent = Double(w.usedPercent ?? 0)
                    if let t = w.resetAt { u.sessionReset = Date(timeIntervalSince1970: Double(t)) }
                }
            }
            // Named per-model/feature limits (e.g. "GPT-5.3-Codex-Spark")
            for extra in r.additionalRateLimits ?? [] {
                guard let name = extra.limitName, let w = extra.rateLimit?.primaryWindow else { continue }
                let short = name.count > 7 ? String(name.split(separator: "-").last ?? Substring(name)) : name
                u.modelLimits.append(ModelLimit(name: short,
                                                percent: Double(w.usedPercent ?? 0),
                                                reset: w.resetAt.map { Date(timeIntervalSince1970: Double($0)) }))
            }
        } catch {
            u.error = "Error"
        }
        return u
    }

    private func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }()
    }
}

// MARK: - Views

struct ProviderRow: View {
    let name: String
    let usage: ProviderUsage
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 12, weight: .semibold))

            if let e = usage.error {
                Text(e).font(.system(size: 11)).foregroundColor(.red)
            } else {
                let w: CGFloat = usage.modelLimits.isEmpty ? 20 : 42
                if let p = usage.sessionPercent {
                    Row(label: "5h", pct: p, reset: usage.sessionReset, now: now, labelWidth: w)
                }
                if let p = usage.weeklyPercent {
                    Row(label: "7d", pct: p, reset: usage.weeklyReset, now: now, labelWidth: w)
                }
                ForEach(usage.modelLimits, id: \.name) { m in
                    Row(label: m.name, pct: m.percent, reset: m.reset, now: now, labelWidth: w)
                }
            }
        }
    }
}

struct Row: View {
    let label: String
    let pct: Double
    let reset: Date?
    let now: Date
    var labelWidth: CGFloat = 20

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: labelWidth, alignment: .leading)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: g.size.width * min(pct / 100, 1))
                }
            }
            .frame(height: 5)

            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 32, alignment: .trailing)

            if let r = reset {
                Text(remaining(r))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    var color: Color { pct >= 80 ? .red : pct >= 60 ? .orange : .green }

    func remaining(_ d: Date) -> String {
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 { return "\(h/24)d" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }
}

struct ContentView: View {
    @State private var state = AppState()
    @State private var loading = false
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Usage").font(.system(size: 12, weight: .bold))
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.5)
                } else {
                    Button(action: { Task { await load() } }) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundColor(.secondary)
                }
            }

            Divider()

            ProviderRow(name: "Claude", usage: state.claude, now: now)
            ProviderRow(name: "Codex", usage: state.codex, now: now).padding(.top, 4)

            Divider()

            HStack {
                if let d = state.lastUpdated {
                    Text(fmt(d)).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .task { await autoRefresh() }
    }

    func load() async {
        loading = true
        state = await UsageAPI.shared.fetchAll()
        now = Date()
        loading = false
    }

    func autoRefresh() async {
        await load()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await load()
        }
    }

    func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

// MARK: - Panel

class Panel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let v = NSVisualEffectView(frame: contentRect(forFrameRect: frame))
        v.material = .hudWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.masksToBounds = true
        contentView = v
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: Panel!
    var hostingView: NSHostingView<ContentView>!
    var globalMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
            b.action = #selector(toggle)
            b.target = self
        }

        panel = Panel()
        hostingView = NSHostingView(rootView: ContentView())
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
    }

    @objc func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            // Fit panel to content
            let fitting = hostingView.fittingSize
            if fitting.width > 0 && fitting.height > 0 {
                panel.setContentSize(fitting)
            }
            if let b = statusItem.button, let w = b.window {
                let r = w.convertToScreen(b.convert(b.bounds, to: nil))
                panel.setFrameOrigin(NSPoint(x: r.midX - panel.frame.width / 2, y: r.minY - panel.frame.height - 2))
            }
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
