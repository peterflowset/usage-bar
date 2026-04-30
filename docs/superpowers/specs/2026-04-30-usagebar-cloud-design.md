# UsageBar Cloud — Design Spec

**Date:** 2026-04-30
**Status:** Draft, awaiting user review
**Source:** Derived from `UsageBar.swift` (macOS menu bar app, single account).

## 1. Goal

A localhost-only web dashboard that shows Claude Code and Codex usage limits (5h session, 7d weekly) for **multiple accounts at once** — replacing the single-account macOS menu bar app for the multi-account use case.

This is a **proof of concept**. It runs on `localhost`, has no auth, no fancy styling. Final integration will happen in an existing dashboard later; this PoC just needs to prove the data flow works.

## 2. Non-Goals

- Auth / login / session management (localhost-only).
- Multi-tenancy. The whole instance is "yours".
- History, charts, alerts, billing, exports.
- Production-grade UI — Tailwind defaults, plain table.
- Cloud hosting / deployment. Runs locally via `npm run dev`.
- Person-grouping (one person owning multiple Claude+Codex logins). Each provider login is its own row, identified by the email.

## 3. Architecture

### 3.1 Repo Layout

A new repository at `/Users/peterkasseroler/Projects/usagebar-cloud/`, npm workspace monorepo:

```
usagebar-cloud/
├── package.json                    # workspaces: ["apps/*", "packages/*"]
├── apps/
│   └── web/                        # Next.js 15 app
│       ├── package.json
│       ├── next.config.ts
│       ├── tsconfig.json
│       ├── tailwind.config.ts
│       ├── data/                   # gitignored runtime state
│       │   └── accounts.json
│       └── src/
│           ├── app/
│           │   ├── layout.tsx
│           │   ├── page.tsx        # dashboard
│           │   ├── globals.css
│           │   └── api/
│           │       ├── accounts/route.ts          # GET, POST
│           │       ├── accounts/[id]/route.ts     # DELETE
│           │       └── usage/route.ts             # GET
│           └── lib/
│               ├── store.ts        # JSON file read/write w/ atomic rename
│               ├── localhost.ts    # localhost guard
│               ├── claude.ts       # Claude API + refresh
│               ├── codex.ts        # Codex API + refresh
│               └── types.ts
└── packages/
    └── cli/                        # `usagebar` CLI
        ├── package.json            # bin: { usagebar: "./dist/index.js" }
        ├── tsconfig.json
        └── src/
            ├── index.ts            # commander entry
            ├── commands/
            │   ├── add.ts
            │   ├── list.ts
            │   └── remove.ts
            ├── providers/
            │   ├── claude.ts       # read keychain / credentials.json, fetch email
            │   └── codex.ts        # read auth.json, decode id_token
            └── api.ts              # POST/GET/DELETE to localhost server
```

### 3.2 Tech Stack

- **Next.js 15** (App Router) + TypeScript strict.
- **Tailwind v4** (zero config). No component library.
- **better-sqlite3? → no.** No DB. JSON file for state.
- **commander** for CLI.
- **uuid** for account IDs.
- Node ≥ 20.
- npm only. No pnpm/yarn/bun.

### 3.3 Persistence Model

`apps/web/data/accounts.json`:

```json
{
  "version": 1,
  "accounts": [
    {
      "id": "uuid-v4",
      "provider": "claude" | "codex",
      "email": "user@example.com",
      "accessToken": "...",
      "refreshToken": "...",
      "expiresAt": 1735689600000,
      "codexAccountId": "acc_...",
      "addedAt": 1735603200000
    }
  ]
}
```

**Writing rule:** any time tokens get refreshed, write the full file via temp-file + atomic rename (`fs.rename`) to avoid partial writes corrupting state. Reads are plain `fs.readFile` + JSON parse; if the file is missing, treat as empty list.

**Concurrency:** Next.js dev mode is single-process for our purposes; we serialize writes via an in-process `Promise` chain in `lib/store.ts`. Good enough for PoC.

### 3.4 Localhost Guard

Every API route checks the request `Host` header. If it doesn't start with `localhost:` or `127.0.0.1:`, return 403. This prevents accidental exposure if the user later puts the app behind a proxy without thinking.

```ts
// lib/localhost.ts — call at top of every route handler.
// Returns a 403 Response if not localhost; null if OK.
export function localhostGuard(req: Request): Response | null {
  const host = req.headers.get('host') ?? '';
  const ok = host.startsWith('localhost:') || host.startsWith('127.0.0.1:');
  return ok ? null : new Response('forbidden', { status: 403 });
}
```

## 4. Data Flow

### 4.1 Onboarding (CLI)

```
$ usagebar add --provider claude
→ reads ~/.claude/.credentials.json OR macOS Keychain (item "Claude Code-credentials")
→ extracts accessToken, refreshToken, expiresAt
→ calls Claude profile endpoint to fetch email
→ POST http://localhost:3000/api/accounts { provider, email, accessToken, refreshToken, expiresAt }
→ server dedupes on (provider, email), upserts, returns { id }
→ CLI prints "Added: claude · user@example.com"
```

For Codex:

```
$ usagebar add --provider codex
→ reads ~/.codex/auth.json
→ extracts tokens.access_token, tokens.refresh_token, tokens.id_token, tokens.account_id
→ decodes id_token JWT → email claim
→ POST /api/accounts { provider: "codex", email, accessToken, refreshToken, expiresAt, codexAccountId }
→ server upserts
```

**Email-resolution fallbacks:**
- Claude: if no profile endpoint works (to be verified during impl), CLI requires `--name <email>` flag.
- Codex: id_token JWT decode is reliable; no fallback needed. If somehow missing, CLI also accepts `--name`.

**Other CLI commands:**
- `usagebar list` → `GET /api/accounts`, prints table (provider, email, added, expires).
- `usagebar remove <email-or-id>` → resolves to id, `DELETE /api/accounts/:id`.
- `--server <url>` flag, default `http://localhost:3000`.

### 4.2 Dashboard Refresh

```
Client (React)
  ├─ on mount: fetch('/api/usage')
  ├─ setInterval(30_000) → refetch
  └─ render table

GET /api/usage
  ├─ load accounts.json
  ├─ Promise.all(accounts.map(a => fetchUsage(a)))
  │     for each account:
  │       if (expiresAt - 60_000 < Date.now()) → refresh first
  │       call provider usage API
  │       if (usage API returns 401) → refresh, retry once
  │       if (refresh itself returns 4xx) → error: "Re-add account", stop
  │       on successful refresh: persist new tokens to accounts.json
  │       map response → { sessionPercent, sessionResetAt, weeklyPercent, weeklyResetAt, error? }
  └─ return { accounts: [{ id, provider, email, ...usage }], lastUpdated }
```

A failure on one account (network, 429, refresh failure) sets `error` on its row; other accounts still render normally.

### 4.3 Token Refresh

**Claude:** OAuth2 refresh against the Anthropic refresh endpoint with `grant_type=refresh_token`. Endpoint and exact body to be confirmed during impl by inspecting Claude Code's behavior; the swift app doesn't currently refresh because it relies on the OS Keychain being kept fresh by Claude Code itself. The cloud app must implement this independently.

**Codex:** OAuth2 refresh against ChatGPT's auth endpoint, again confirmed by inspecting Codex CLI behavior during impl.

If refresh fails (refresh token revoked, etc.), mark the account row with `error: "Re-add account"` and surface a hint in the UI; don't delete it automatically.

## 5. UI

A single page at `/`:

```
┌──────────────────────────────────────────────────────────────┐
│  UsageBar Cloud                          [↻] last 14:32:11   │
├──────────────────────────────────────────────────────────────┤
│  Provider  Email                  5h            7d           │
│  Claude    peter@example.com      [██████░░] 62%   [██░░] 24%│
│  Claude    work@example.com       [█░░░░░░░]  8%   [█░░░]  9%│
│  Codex     peter@example.com      Re-add account             │
│  ...                                                         │
└──────────────────────────────────────────────────────────────┘
```

- Color thresholds (matching Swift app): green `<60%`, orange `60–80%`, red `≥80%`.
- Reset times shown as relative ("4h", "2d", "now"), exact behavior copied from `UsageBar.swift`.
- Refresh button forces an immediate `GET /api/usage`.
- Empty state ("No accounts yet — run `usagebar add --provider claude` to get started").

## 6. API Contract

### `GET /api/accounts`
```json
{ "accounts": [ { "id", "provider", "email", "expiresAt", "addedAt" } ] }
```
(Tokens are NEVER returned to the client.)

### `POST /api/accounts`
Body:
```json
{ "provider", "email", "accessToken", "refreshToken", "expiresAt", "codexAccountId?" }
```
Response: `{ "id": "uuid" }`. Upserts by `(provider, email)` — re-adding the same account replaces tokens.

### `DELETE /api/accounts/:id`
Response: `{ "ok": true }` or 404.

### `GET /api/usage`
```json
{
  "lastUpdated": 1735689600000,
  "accounts": [
    {
      "id", "provider", "email",
      "sessionPercent": 62.0,
      "sessionResetAt": 1735693200000,
      "weeklyPercent": 24.0,
      "weeklyResetAt": 1736294400000,
      "error": null
    },
    {
      "id", "provider", "email",
      "sessionPercent": 0, "weeklyPercent": 0,
      "error": "Re-add account"
    }
  ]
}
```

## 7. Error Handling

| Situation | Behavior |
|---|---|
| `accounts.json` missing | Treat as empty list. Auto-create on first POST. |
| Refresh token revoked / 401 on refresh | `error: "Re-add account"` on that row. |
| Provider API returns 429 | `error: "Rate limit"` on that row. |
| Provider API returns 5xx | `error: "API <code>"`, don't refresh. |
| Network failure | `error: "Network"`. |
| Claude Code keychain locked (CLI side) | CLI exits with code 1, prints hint. |
| Provider returns shape we don't recognize | `error: "Parse"`, log raw response to server console. |

## 8. Out of Scope (PoC)

- Encrypting tokens at rest. (PoC is local; the JSON file sits on the same machine that already has the tokens.)
- Concurrency safety beyond single-process serialization.
- Production deployment (Docker, cloud, TLS, auth).
- Person-grouping in the UI (Claude + Codex from the same human).
- Charts, history, billing breakdown.
- Per-account custom display names (always email).
- Codex-only or Claude-only modes — both providers always supported.

## 9. Risks & Open Questions

1. **Claude profile/email endpoint** — not yet verified. If `GET /api/oauth/profile` (or similar) doesn't expose the email for an OAuth Bearer token, we fall back to requiring `--name <email>` on `usagebar add`. Resolution during impl.
2. **Refresh endpoints** — exact URLs and body shapes for Claude/Codex token refresh need to be confirmed by inspecting Claude Code / Codex CLI behavior. If refresh is not feasible, the PoC degrades to "tokens valid until they expire, then re-run `usagebar add`" — still a usable PoC, just less convenient.
3. **Anthropic / OpenAI ToS** — using OAuth tokens from official CLIs in a third-party tool is the same pattern the existing Swift app uses; we are not introducing new risk.
4. **Atomic write on Windows** — `fs.rename` over an existing file is fine on macOS/Linux; on Windows you sometimes need to delete first. PoC targets macOS so this is fine.

## 10. Success Criteria

- After `usagebar add --provider claude` for 2+ accounts and `usagebar add --provider codex` for 1+ account, `localhost:3000` shows a row per account with non-zero, plausible 5h and 7d percentages.
- Closing & reopening `npm run dev` retains the accounts.
- Tokens refresh transparently for at least one cycle (verified manually by waiting past `expiresAt`).
- Removing an account via `usagebar remove` removes it from the dashboard.
