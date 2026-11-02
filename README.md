# Hackban for Mac

A native SwiftUI client for [Hackban](https://github.com/hackclub/hackban), Hack Club's self-hosted Trello.
Sign in to as many Hackban servers as you like (say, a work server and a personal one) and see all of them at
once.

## Features

- **Every server at once.** The sidebar lists each account's starred boards, workspaces and guest boards
  together. Home, My Cards, Notifications, Search and ⌘K (go to board) cover every account, each item tagged
  with its account. Accounts can be renamed, recoloured, reordered, hidden or signed out in Settings.
- **Boards** as on the web: drag and drop cards and lists, add/rename/colour/copy/move/archive/delete lists,
  move or archive all cards in a list, sort a list, filters (keyword, members, labels, due), star, visibility,
  live updates from other people, share (members, roles, email invites, invite links), and the board menu
  (description, background colours/gradients/image, labels, archived items, activity, copy, move to another
  workspace, export JSON, close/reopen, delete).
- **Cards**: title, markdown description, labels (create/edit/delete), members, start/due dates, repeat,
  complete, cover (colour or image, normal/full), checklists (add/rename/delete/copy, item due dates and
  assignees, drag to reorder, hide checked), attachments (upload from a picker, drag files onto a card, or
  paste; links; rename; make cover; open), comments (edit/delete your own), activity, watch, dependencies
  (blocked by / blocking), move and copy anywhere on the same server, archive/restore, delete.
- **Hover shortcuts** on a board, matching the web: `Enter` open, `e` quick edit (or right-click), `d`
  complete, `c` archive, `Space` join/leave, `1`–`0` toggle labels, `q` my cards, `x` clear filters, `w` board
  menu, `/` filters.
- **Workspaces**: boards (sorted by activity or name), members and roles, email invites, auto-join domains,
  logo, rename, leave, delete. Closed boards, guest boards, join from an invite link.
- **Profile**: name, username, picture (upload or back to Slack), your activity, connected apps.

### Desktop extras

- **Quick add from anywhere** with a global shortcut (⌃⌥Space by default, change it in Settings → Quick Add).
  A floating panel takes Todoist-style input:

  ```
  Write launch post #Marketing/Doing @me @sam !urgent tomorrow 5pm
  ```

  `#board` (or `#board/list`), `/list`, `@me`/`@name`, `!label`, and dates such as `today`, `tonight`,
  `tomorrow 5pm`, `fri`, `next week`, `in 3 days`, `jan 5`. Only tokens that match a real board, list,
  member or label are used; everything else stays in the title. Parsed tokens show as chips before you add,
  and there are explicit board/list pickers too. `↩` adds, `⌘↩` adds and opens the card, pasting several lines
  adds one card per line. Parsing can be turned off, and the destination can be fixed or follow the last
  board you used.
- **Offline mode.** Boards and cards you've opened are kept on this Mac, per server, so they open without a
  connection (the window says "Offline, updated …"). Most edits work offline: card title, description, dates,
  complete, repeat, cover colour, labels, members, watch, move and reorder, archive, delete, checklists and their
  items, comments, links, and list create, rename, colour, reorder, archive and sort. They wait on the Mac and sync
  in order when the server's back. The sidebar and toolbar show what's waiting and what couldn't sync, and settle
  conflicts. Uploads, copying, moving to another board, board settings and sharing need a connection.
- **Menu bar extra** with quick add, what's due in the next three days, and unread notifications.
- **Native notifications** for Hackban notifications (comments on watched cards, being added to a card),
  and an unread count on the Dock icon.
- Light/dark/system theme, open at login, default time for new due dates.

### Browser-only

Site-admin tools (the admin panel, Trello import, linking imported members) stay on the web. The app links to
them for site admins.

## Requirements

- macOS 14 Sonoma or later.
- Xcode 16 (Swift 6 toolchain) to build. Xcode 26 or later for the Liquid Glass design on macOS 26 and later.
- A Hackban server with native app sign-in (`scopes_supported` includes `"app"` in
  `/.well-known/oauth-authorization-server`). See [Server support](#server-support).

## Build and run

```sh
swift run Hackban          # run from source
./Scripts/bundle.sh        # build/Hackban.app (ad-hoc signed)
UNIVERSAL=1 ./Scripts/bundle.sh
./Scripts/icon.sh          # regenerate Resources/AppIcon.icns from AppIcon.svg (needs librsvg)
```

Or open `Package.swift` in Xcode and run the `Hackban` scheme. Notifications, open-at-login and Liquid Glass
need the bundled app (`Scripts/bundle.sh`), not `swift run`: plain `swift build` records the deployment target
as the SDK version, so macOS shows the pre-26 design. The app is ad-hoc signed, so the first launch needs
right-click → Open, and macOS may ask once per build to let it read its Keychain item.

CI (`.github/workflows/build.yml`) runs the tests and builds `Hackban.app` on macOS for every push, and
uploads it as an artifact.

## How it works

- **Sign-in**: the app uses Hackban's OAuth 2.1 server (the one MCP clients use). It registers itself
  dynamically as a public client, then opens the consent page in an `ASWebAuthenticationSession` with PKCE
  and `scope=app`, redirecting to `hackban-desktop://oauth/callback`. Tokens live in the Keychain, one item
  per account; refresh tokens rotate on every refresh, and refreshes are serialized so a rotated token is
  never replayed (the server revokes the whole grant if it is).
- **API**: the same tRPC procedures as the web app, over plain HTTP with superjson
  (`Sources/HackbanKit/API.swift` lists every one). Uploads and downloads use the file routes with the same
  bearer token.
- **Live updates**: an open board subscribes to `board.onEvent` over SSE and refetches when someone else
  changes it. Your own changes are applied optimistically and skipped when they echo back.
- **Offline**: every edit that can work offline goes through a per-account queue
  (`Sources/HackbanKit/OfflineQueue.swift`) and is sent in order, online or not. What you see is the last server
  snapshot with the queue applied on top. Things made offline get temporary ids, swapped for the server's as their
  creates land. A create that may have reached the server before the connection dropped is looked for before
  it's sent again, so nothing's made twice. If someone else changed a card's title or description meanwhile,
  theirs stays and yours is kept as a conflict to settle; other fields take your change. A server counts as
  offline when the network's down or requests can't reach it, and is probed with backoff until it answers.
  Snapshots and the queue live in `~/Library/Application Support/Hackban/Offline/<account>/`.
- **Layout**:
  - `Sources/HackbanKit`: Foundation-only core (superjson, tRPC client, OAuth, SSE, models, API, filters,
    sorts, activity text, quick-add parser). Builds and tests on Linux too.
  - `Sources/Hackban`: the SwiftUI app (models, views, quick-add panel, global hotkey, Keychain).
  - `Tests/HackbanKitTests`: wire format, token refresh, model decoding, filters, the quick-add parser, and
    offline replay against a fake server.

```sh
swift test
```

## Server support

Native app sign-in needs a Hackban server change, included here as
[docs/hackban-server-app-scope.patch](docs/hackban-server-app-scope.patch) (apply it to
[hackclub/hackban](https://github.com/hackclub/hackban) with `git am`): an `app` OAuth scope whose tokens work on tRPC and the
file routes, issued only to native redirect URIs (custom scheme or loopback), with a consent page that says
the app gets full access. Site-admin powers stay browser-only. Servers without it show "This Hackban server
doesn't support the Mac app yet" when you try to sign in.

See [docs/PLAN.md](docs/PLAN.md) for the plan and its critique.
