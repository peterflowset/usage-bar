import SwiftUI
import AppKit
import Security

// MARK: - Models

struct ModelLimit: Codable {
    let name: String
    let percent: Double
    let reset: Date?
}

struct ProviderUsage: Codable {
    // nil = the provider does not report this window; the row is hidden
    var sessionPercent: Double?
    var sessionReset: Date?
    var weeklyPercent: Double?
    var weeklyReset: Date?
    var modelLimits: [ModelLimit] = []
    var error: String?
}

// Shared across processes (menu bar app + cmux Dock CLI instances) so only
// one of them actually hits the APIs per refresh interval.
struct CachedProvider: Codable {
    var usage: ProviderUsage
    var fetchedAt: Date
}

struct UsageCache: Codable {
    var claude: CachedProvider?
    var codex: CachedProvider?
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
    static let shared = UsageAPI(
        // A terminal copy has a different code-signing identity from the app
        // bundle. It must never ask for access to Claude Code's Keychain item;
        // CLI mode can use fresh statusline data or the cache written by the
        // menu-bar app instead.
        allowsClaudeKeychainAccess: !CommandLine.arguments.contains("--cli")
            && !CommandLine.arguments.contains("--once")
    )

    private var lastGoodClaude: ProviderUsage?
    private var lastGoodCodex: ProviderUsage?
    private var claudeBackoffUntil = Date.distantPast
    private var codexBackoffUntil = Date.distantPast
    private let allowsClaudeKeychainAccess: Bool
    private var cachedClaudeKeychainCredentials: ClaudeCredentials?
    private var didAttemptClaudeKeychainAccess = false
    private var claudeKeychainModificationDateAtLastAttempt: Date?

    private let cacheURL = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/usagebar-state.json")
    // Serve from the shared cache while it is fresher than this, so N running
    // instances still produce only ~1 API request per interval in total.
    private let cacheMaxAge: TimeInterval = 55
    private let backoffInterval: TimeInterval = 300

    init(allowsClaudeKeychainAccess: Bool = true) {
        self.allowsClaudeKeychainAccess = allowsClaudeKeychainAccess
    }

    func fetchAll(forceClaudeAuthRetry: Bool = false) async -> AppState {
        if forceClaudeAuthRetry {
            didAttemptClaudeKeychainAccess = false
            claudeKeychainModificationDateAtLastAttempt = nil
        }

        var state = AppState()
        state.lastUpdated = Date()
        let cache = readCache()

        state.claude = await fetchProvider(
            cached: cache?.claude, lastGood: &lastGoodClaude, backoffUntil: &claudeBackoffUntil,
            fetch: fetchClaude, store: { c in self.writeCache { $0.claude = c } })
        state.codex = await fetchProvider(
            cached: cache?.codex, lastGood: &lastGoodCodex, backoffUntil: &codexBackoffUntil,
            fetch: fetchCodex, store: { c in self.writeCache { $0.codex = c } })

        return state
    }

    private func fetchProvider(cached: CachedProvider?,
                               lastGood: inout ProviderUsage?,
                               backoffUntil: inout Date,
                               fetch: () async -> ProviderUsage,
                               store: (CachedProvider) -> Void) async -> ProviderUsage {
        let now = Date()
        // Another instance fetched moments ago — reuse its result.
        if let c = cached, now.timeIntervalSince(c.fetchedAt) < cacheMaxAge {
            lastGood = c.usage
            return c.usage
        }
        // Backing off after a 429 — show the best data we have.
        if now < backoffUntil, let u = lastGood ?? cached?.usage {
            return u
        }

        let fetched = await fetch()
        if fetched.error == nil {
            lastGood = fetched
            store(CachedProvider(usage: fetched, fetchedAt: Date()))
            return fetched
        }
        if fetched.error == "Rate limit" {
            backoffUntil = Date().addingTimeInterval(backoffInterval)
        }
        // Transient errors keep the last good data (in-memory or from disk).
        return lastGood ?? cached?.usage ?? fetched
    }

    private func readCache() -> UsageCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(UsageCache.self, from: data)
    }

    private func writeCache(_ update: (inout UsageCache) -> Void) {
        // Re-read and merge so concurrent instances don't clobber each other's slot.
        var cache = readCache() ?? UsageCache()
        update(&cache)
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.cache",
                                                 withIntermediateDirectories: true)
        if let data = try? e.encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
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
        // ~/.claude/.credentials.json may hold a long-expired one.
        // Keep a successful Keychain read in memory: querying the item on
        // every refresh can repeatedly display macOS authorization prompts.
        if let cached = cachedClaudeKeychainCredentials, !cached.isExpired {
            return (cached.claudeAiOauth.accessToken, nil)
        }
        if cachedClaudeKeychainCredentials?.isExpired == true {
            cachedClaudeKeychainCredentials = nil
            didAttemptClaudeKeychainAccess = false
            claudeKeychainModificationDateAtLastAttempt = nil
        }
        if cachedClaudeKeychainCredentials == nil,
           allowsClaudeKeychainAccess,
           let cached = loadOwnClaudeTokenCache() {
            cachedClaudeKeychainCredentials = cached
            return (cached.claudeAiOauth.accessToken, nil)
        }

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

        // Reading Keychain metadata does not expose the secret or show an auth
        // prompt. If Claude Code replaced/refreshed the credential after our
        // last denied lookup, allow one new attempt so the app can recover
        // without a relaunch. An unchanged item stays latched to avoid showing
        // the same authorization prompt every minute.
        let currentKeychainModificationDate = allowsClaudeKeychainAccess
            ? claudeKeychainModificationDate()
            : nil
        if didAttemptClaudeKeychainAccess,
           let currentKeychainModificationDate,
           let lastAttemptDate = claudeKeychainModificationDateAtLastAttempt,
           currentKeychainModificationDate != lastAttemptDate {
            didAttemptClaudeKeychainAccess = false
        }

        // CLI mode deliberately never reads Keychain credentials.
        guard allowsClaudeKeychainAccess, !didAttemptClaudeKeychainAccess else {
            return (fileToken, fileToken != nil ? nil : (fileError ?? "No auth"))
        }
        didAttemptClaudeKeychainAccess = true
        claudeKeychainModificationDateAtLastAttempt = currentKeychainModificationDate

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
            // The read succeeded, so no authorization prompt is in play:
            // keep retrying on later refreshes even if the payload is
            // unusable right now (Claude Code refreshes the item over time).
            didAttemptClaudeKeychainAccess = false
            claudeKeychainModificationDateAtLastAttempt = nil
            guard let data = item as? Data,
                  let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
                return (fileToken, fileToken != nil ? nil : "Auth format")
            }
            if creds.isExpired {
                return (fileToken, fileToken != nil ? nil : "Auth expired")
            }
            cachedClaudeKeychainCredentials = creds
            storeOwnClaudeTokenCache(creds)
            return (creds.claudeAiOauth.accessToken, nil)
        case errSecItemNotFound:
            didAttemptClaudeKeychainAccess = false
            claudeKeychainModificationDateAtLastAttempt = nil
            return (fileToken, fileToken != nil ? nil : (fileError ?? "No auth"))
        case errSecInteractionNotAllowed:
            return (fileToken, fileToken != nil ? nil : "Keychain locked")
        case errSecAuthFailed, errSecUserCanceled:
            return (fileToken, fileToken != nil ? nil : "Keychain denied")
        default:
            return (fileToken, fileToken != nil ? nil : "Keychain \(status)")
        }
    }

    private func storeOwnClaudeTokenCache(_ creds: ClaudeCredentials) {
        guard allowsClaudeKeychainAccess,
              let data = try? JSONEncoder().encode(creds) else {
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.usagebar.claude-token-cache",
            kSecAttrAccount as String: "claude",
            kSecValueData as String: data,
        ]
        if SecItemAdd(query as CFDictionary, nil) == errSecDuplicateItem {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.local.usagebar.claude-token-cache",
                kSecAttrAccount as String: "claude",
            ]
            SecItemUpdate(
                match as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    private func loadOwnClaudeTokenCache() -> ClaudeCredentials? {
        guard allowsClaudeKeychainAccess else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.local.usagebar.claude-token-cache",
            kSecAttrAccount as String: "claude",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) else {
            return nil
        }
        if creds.isExpired {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.local.usagebar.claude-token-cache",
                kSecAttrAccount as String: "claude",
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return nil
        }
        return creds
    }

    private func claudeKeychainModificationDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else {
            return nil
        }
        return attributes[kSecAttrModificationDate as String] as? Date
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
                    Button(action: { Task { await load(forceClaudeAuthRetry: true) } }) {
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

    func load(forceClaudeAuthRetry: Bool = false) async {
        loading = true
        state = await UsageAPI.shared.fetchAll(forceClaudeAuthRetry: forceClaudeAuthRetry)
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

// MARK: - CLI mode (for terminals / cmux Dock)

enum CLI {
    static func color(_ pct: Double) -> String { pct >= 80 ? "\u{1B}[31m" : pct >= 60 ? "\u{1B}[33m" : "\u{1B}[32m" }

    static func bar(_ pct: Double, width: Int = 18) -> String {
        let filled = min(max(Int((pct / 100 * Double(width)).rounded()), 0), width)
        return color(pct) + String(repeating: "█", count: filled)
            + "\u{1B}[0m\u{1B}[2m" + String(repeating: "░", count: width - filled) + "\u{1B}[0m"
    }

    static func remaining(_ d: Date?, now: Date) -> String {
        guard let d else { return "" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 { return "\(h/24)d" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }

    static func row(_ label: String, _ pct: Double, _ reset: Date?, now: Date) -> String {
        let l = label.count > 6 ? String(label.prefix(6)) : label.padding(toLength: 6, withPad: " ", startingAt: 0)
        let p = String(format: "%3.0f%%", pct)
        let r = remaining(reset, now: now)
        return "  \(l) \(bar(pct)) \(color(pct))\(p)\u{1B}[0m \u{1B}[2m\(r)\u{1B}[0m"
    }

    static func section(_ name: String, _ u: ProviderUsage, now: Date) -> String {
        var lines = ["\u{1B}[1m\(name)\u{1B}[0m"]
        if let e = u.error {
            lines.append("  \u{1B}[31m\(e)\u{1B}[0m")
        } else {
            if let p = u.sessionPercent { lines.append(row("5h", p, u.sessionReset, now: now)) }
            if let p = u.weeklyPercent { lines.append(row("7d", p, u.weeklyReset, now: now)) }
            for m in u.modelLimits { lines.append(row(m.name, m.percent, m.reset, now: now)) }
        }
        return lines.joined(separator: "\n")
    }

    static func run(once: Bool) async {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if !once {
            // Alternate screen buffer + hidden cursor: redraws replace the
            // frame instead of stacking copies in the scrollback.
            print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
            for sig in [SIGINT, SIGTERM] {
                signal(sig) { _ in
                    print("\u{1B}[?1049l\u{1B}[?25h", terminator: "")
                    exit(0)
                }
            }
        }
        while true {
            let state = await UsageAPI.shared.fetchAll()
            let now = Date()
            var out = once ? "" : "\u{1B}[H\u{1B}[2J"
            out += "\u{1B}[1mUsage\u{1B}[0m \u{1B}[2m\(f.string(from: now))\u{1B}[0m\n\n"
            out += section("Claude", state.claude, now: now) + "\n\n"
            out += section("Codex", state.codex, now: now) + "\n"
            print(out, terminator: "")
            fflush(stdout)
            if once { exit(0) }
            try? await Task.sleep(for: .seconds(60))
        }
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

if CommandLine.arguments.contains("--cli") || CommandLine.arguments.contains("--once") {
    Task.detached { await CLI.run(once: CommandLine.arguments.contains("--once")) }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
