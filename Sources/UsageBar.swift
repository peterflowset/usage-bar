import SwiftUI
import AppKit

// MARK: - Models

struct ProviderUsage {
    var sessionPercent: Double = 0
    var sessionReset: Date?
    var weeklyPercent: Double = 0
    var weeklyReset: Date?
    var error: String?
}

struct AppState {
    var claude = ProviderUsage()
    var codex = ProviderUsage()
    var lastUpdated: Date?
}

// MARK: - Claude API

struct ClaudeCredentials: Codable {
    struct OAuth: Codable { let accessToken: String }
    let claudeAiOauth: OAuth
}

struct ClaudeUsageResponse: Codable {
    struct Limit: Codable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
    }
    let fiveHour: Limit?
    let sevenDay: Limit?
    enum CodingKeys: String, CodingKey { case fiveHour = "five_hour"; case sevenDay = "seven_day" }
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
            enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at" }
        }
        let primaryWindow: Window?
        let secondaryWindow: Window?
        enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" }
    }
    let rateLimit: RateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
}

// MARK: - API Client

class UsageAPI {
    static let shared = UsageAPI()

    func fetchAll() async -> AppState {
        var state = AppState()
        state.lastUpdated = Date()

        async let c = fetchClaude()
        async let x = fetchCodex()

        state.claude = await c
        state.codex = await x

        return state
    }

    private func fetchClaude() async -> ProviderUsage {
        var u = ProviderUsage()
        let path = NSHomeDirectory() + "/.claude/.credentials.json"

        guard let data = FileManager.default.contents(atPath: path) else {
            u.error = "No auth"
            return u
        }
        guard let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
            u.error = "Auth format"
            return u
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.claudeAiOauth.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                u.error = "API error"
                return u
            }
            let r = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            if let s = r.fiveHour {
                u.sessionPercent = s.utilization ?? 0
                if let t = s.resetsAt { u.sessionReset = parseISO(t) }
            }
            if let w = r.sevenDay {
                u.weeklyPercent = w.utilization ?? 0
                if let t = w.resetsAt { u.weeklyReset = parseISO(t) }
            }
        } catch {
            u.error = "Error"
        }
        return u
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
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                u.error = "API error"
                return u
            }
            let r = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            if let p = r.rateLimit?.primaryWindow {
                u.sessionPercent = Double(p.usedPercent ?? 0)
                if let t = p.resetAt { u.sessionReset = Date(timeIntervalSince1970: Double(t)) }
            }
            if let s = r.rateLimit?.secondaryWindow {
                u.weeklyPercent = Double(s.usedPercent ?? 0)
                if let t = s.resetAt { u.weeklyReset = Date(timeIntervalSince1970: Double(t)) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 12, weight: .semibold))

            if let e = usage.error {
                Text(e).font(.system(size: 11)).foregroundColor(.red)
            } else {
                Row(label: "5h", pct: usage.sessionPercent, reset: usage.sessionReset)
                Row(label: "7d", pct: usage.weeklyPercent, reset: usage.weeklyReset)
            }
        }
    }
}

struct Row: View {
    let label: String
    let pct: Double
    let reset: Date?

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 20, alignment: .leading)

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
        let s = d.timeIntervalSinceNow
        if s <= 0 { return "now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 { return "\(h/24)d" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }
}

struct ContentView: View {
    @State private var state = AppState()
    @State private var loading = false

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

            ProviderRow(name: "Claude", usage: state.claude)
            ProviderRow(name: "Codex", usage: state.codex).padding(.top, 4)

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
        .task { await load() }
    }

    func load() async {
        loading = true
        state = await UsageAPI.shared.fetchAll()
        loading = false
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
