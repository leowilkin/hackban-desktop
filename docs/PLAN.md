# Hackban for Mac: plan

## Goal

A native SwiftUI macOS client for Hackban that talks to any number of Hackban servers at once (e.g. a work
instance and a personal one), covers what the web app does, and adds desktop-only features: a global,
rebindable quick-add shortcut (Todoist-style), a menu bar extra, native notifications and a dock badge.

## Findings that shape the plan

- The web app talks to the server over tRPC 11 with superjson. The tRPC context only reads the Auth.js
  cookie session. Bearer tokens (from the existing OAuth 2.1 server built for MCP) are only accepted on
  `/api/mcp`.
- MCP covers maybe 60% of features (no deletes, no uploads, no live updates, no settings), so a client built on
  MCP can't reach parity.
- Live updates are a tRPC subscription (`board.onEvent`) over SSE.
- File routes (`/api/files`, `/api/cards/:id/attachments`, avatars, logos, board export) are plain Next
  routes that also only read the cookie session.

## Plan

### 1. Server (hackban repo)

1. Add an `app` OAuth scope. `/oauth/authorize?scope=app` issues tokens that work on tRPC and the REST file
   routes, not just MCP. The scope is stored on each `OAuthToken` row (additive column) and carried through
   code, access and refresh tokens.
2. `createTRPCContext` falls back to `Authorization: Bearer` when there is no cookie session, but only for
   `app`-scoped tokens. Site-admin powers stay off over tokens (`isAdmin: false`), matching MCP.
3. One `sessionFor(req)` helper used by the file routes so uploads, downloads, avatars, logos and export
   accept the same tokens.
4. `app` scope only for native redirect URIs (custom scheme or loopback), so a phishing web page can't
   collect full-access tokens. Consent page says plainly that the app gets full access, including deleting.
5. Advertise `scopes_supported: ["mcp", "app"]` in the authorization server metadata so clients can
   detect whether an older self-hosted server supports this.
6. Tests for the scope/redirect rules, README section, announcement entry.

### 2. Client (this repo)

SwiftPM package, two targets:

- `HackbanKit` (Foundation only, builds and is unit-tested on Linux and macOS): superjson codec, tRPC client
  (GET queries, POST mutations, typed errors), SSE subscription reader, OAuth (discovery, dynamic client
  registration, PKCE, token exchange, refresh with rotation), typed models for every router output used,
  typed API for every procedure, card filters and sorts, activity text, the quick-add parser.
- `Hackban` (macOS 14+, SwiftUI): the app.

App features:

- **Accounts**: add any number of servers (URL + browser sign-in via `ASWebAuthenticationSession`).
  Tokens in the Keychain. Each account has its own colour and can be hidden.
- **See everything at once** rather than switching: the sidebar lists every account's workspaces and
  boards together. Home, My cards, Notifications and Search merge every account's results, tagged by account.
- **Boards**: lists and cards with drag and drop (cards across lists, list reordering), add/rename/
  colour/copy/move/archive lists, move all cards, archive all cards, sort list, filters (keyword,
  members, labels, due), board menu (about/description, background colours/gradients/image URL,
  labels, archived items with restore/delete, activity, copy, move to workspace, close/reopen, delete,
  export JSON, watch), star, share (members, roles, email invites, invite links), live updates over SSE.
- **Cards**: title, markdown description, labels, members, start/due dates, complete, repeat, cover
  colour/image/size, checklists (add/rename/delete, items with due/assignee, reorder, copy from),
  attachments (upload via picker, drag-and-drop, paste; links; rename; delete; make cover), comments
  (add/edit/delete), activity, watch, blockers (dependencies), copy, move, archive/restore, delete.
  Hover shortcuts as on the web: Enter, e, d, c, Space, 1–0, q, x, w, /.
- **Workspaces**: create, rename/description, logo upload/remove, members and roles, email invites,
  auto-join rules, leave, delete. Guest boards, closed boards, join by invite link.
- **Me**: profile name/username, avatar upload/remove, my cards, my activity, connected apps (revoke),
  theme (system/light/dark).
- **Desktop extras**: global quick-add hotkey (default ⌃⌥Space, rebindable in Settings) opening a
  floating panel. Natural syntax: `#board`, `/list`, `@member`/`@me`, `!label`, dates like `today`,
  `tomorrow 5pm`, `fri`, `next week`, `in 3 days`, `jan 5`. Parsed tokens show as chips before you
  submit, plus explicit board/list pickers, a remembered default destination per account, one card per
  line when pasting several lines. Menu bar extra (due soon, quick add). Native notifications for new
  Hackban notifications, dock badge for unread count. ⌘K to jump to any board.
- **Browser-only, by design**: the site-admin panel and Trello import (site-admin tools); the app
  links to them.

## Critique

1. **It needs a server change.** Every instance has to run the new server before the app can sign in to
   it. Self-hosted personal servers lag behind. Mitigation: the app reads `scopes_supported` and shows
   "this server needs updating" instead of a confusing OAuth failure.
2. **Full-access tokens are a bigger target than MCP tokens.** Registration is open, so anyone can make a
   consent link. Mitigation: `app` scope only for native redirects, consent copy that says "full access",
   no site-admin powers over tokens, Keychain storage, revocable from Connected apps, rotating refresh
   tokens with replay detection (already in place).
3. **Tight coupling to tRPC/superjson internals.** No published API; a router change can break the app
   silently. Alternative (a versioned REST API) is a lot more server code to maintain. Mitigation: one
   file lists every procedure, decoding is tolerant (unknown fields ignored, most fields optional),
   errors surface the server's message.
4. **I can't build SwiftUI here** (Linux container, no Xcode). `HackbanKit` is compiled and unit-tested
   on Linux with Swift 6; the app target is written carefully against macOS 14 APIs but unverified until
   built on a Mac. Expect a short compile-fix pass on first build.
5. **Drag and drop**: SwiftUI's drop APIs are coarser than dnd-kit (no live gap animation). Drops target
   "before this card" or "end of list", which covers every position.
6. **Quick-add parsing is ambiguous** (`#` inside a title, dates in titles like "Q3 review"). Mitigation:
   only parse tokens that match a real board/list/member/label, show chips so you see what will be
   applied, and a toggle to turn parsing off.
7. **Live updates**: only open boards subscribe over SSE; other views refresh on focus and on a timer.
   One connection per open board per account, which the single-replica server handles fine.
8. **Packaging**: SwiftPM plus a script that bundles a `.app` (Info.plist, ad-hoc signature). No
   `.xcodeproj` to keep in sync; open `Package.swift` in Xcode to develop. Notarisation is left out.
