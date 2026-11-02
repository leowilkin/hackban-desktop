# Hackban for Mac

A native SwiftUI client for [Hackban](https://github.com/hackclub/hackban), Hack Club's self-hosted Trello.
Sign in to as many Hackban servers as you like (say, a work server and a personal one) and see all of them at
once.

## Features

- **Every server at once.** The sidebar has a section per workspace on every account, plus starred and guest
  boards. Home, My Cards and Notifications cover every account, each item tagged with its account, and Search
  (⌘K) is a floating panel that finds boards and cards on all of them. Accounts can be renamed, recoloured,
  reordered, hidden or signed out in Settings.
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
uploads it as an artifact. Builds of `main` are also published as GitHub releases tagged `build-<run number>`,
with the run number as the app's `CFBundleVersion` (`BUILD_NUMBER=… ./Scripts/bundle.sh`; local builds are 0).

## Updates

The app checks this repo's latest release (`HackbanUpdateRepo` in `Resources/Info.plist`) about ten seconds
after launch and every six hours, and offers newer builds: Install and Relaunch downloads `Hackban.zip`, checks
it's signed with the update key, that it's Hackban at that build with an intact code signature, swaps it in for
the running copy and reopens it. Turn the automatic checks off in Settings → General; Hackban → Check for
Updates… works either way, and on a local build offers the latest release. Hackban has to be somewhere it can
write to, such as /Applications. Each release is a new ad-hoc signature, so after an update macOS asks once more
to let Hackban read its Keychain item.

### Signed releases

An ad-hoc code signature shows the app arrived intact but not who built it, so releases are signed the way
Sparkle signs them: CI signs `Hackban.zip` with an Ed25519 key from the `HACKBAN_UPDATE_KEY` secret and uploads
the signature as `Hackban.zip.sig` next to it. The app verifies that against the public key in
`Resources/Info.plist` (`HackbanUpdatePublicKey`) before unzipping anything, and refuses releases that are
unsigned or signed with another key. A build without `HackbanUpdatePublicKey` doesn't check. The signing step
fails, and nothing is published, if the secret is missing or isn't the private half of that public key.

To make the key (once, on your own machine):

```sh
./Scripts/update-key.swift new ~/hackban-update-key     # prints the public key
gh secret set HACKBAN_UPDATE_KEY < ~/hackban-update-key
```

Put the public key in `Resources/Info.plist` as `HackbanUpdatePublicKey`, keep the private key somewhere safe
such as a password manager, and delete the file. Installed copies only trust the key they shipped with: changing
keys takes one release that carries the new public key but is signed with the old private key (by hand, since CI
insists the two match), and after losing the key everyone has to download the next build by hand.

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
- **Layout**:
  - `Sources/HackbanKit`: Foundation-only core (superjson, tRPC client, OAuth, SSE, models, API, filters,
    sorts, activity text, quick-add parser). Builds and tests on Linux too.
  - `Sources/Hackban`: the SwiftUI app (models, views, quick-add panel, global hotkey, Keychain).
  - `Tests/HackbanKitTests`: wire format, token refresh, model decoding, filters and the quick-add parser.

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
