# Suite Settings: project brief

Suite Settings (`local.suite.settings`) shows the settings of the suite's apps in one window, as an
app of its own with its own Dock icon, and through its login item, Suite Settings Agent
(`local.suite.settings.agent`), marks in System Settings the settings a running suite app takes over;
still to come: a catalog to discover and install the others.

## Architecture

```
SettingsUI    (library, SwiftUI) every app's settings tabs, read and written through each app's settings
              library: ExplorerSettings (repository suite-explorer), DesktopSettings (suite-desktop),
              BarSettings (suite-bar), ClipboardSettings (suite-clipboard); SuiteFilesCore (suite-files)
              for the file display settings
Settings      (Suite Settings.app)
NativeBanner  (library, no UI, tested) which System Settings pane a window shows (NativePane) and what
              to cover there for the suite apps running (PaneMarks, PaneCover, RowLayout)
SettingsAgent (Suite Settings Agent.app, in Suite Settings.app/Contents/Library/LoginItems) reads the
              pane through Accessibility (PaneReader), draws the covers (RowOverlay), swallows clicks
              under them (ClickGuard)
```

`SuiteCore` (repository `suite-core`) brings where Explorer's settings live (`SuiteDefaults`), the
messages to Explorer and Clipboard (`ExplorerLink`, `ClipboardMessage`) and settings profiles
(`SettingsProfile`, `ProfileStore`). Suite Settings never imports an app's own code, only its
`<App>Settings` library; changing a setting in an app's library and its tab here at once:
`swift package edit Explorer --path ../suite-explorer` (or `Desktop`, `Bar`, `Clipboard`, `SuiteFiles`),
`swift package unedit` after.

The Bar tab writes Bar.app's defaults (`BarSettings.current`), tells it (`BarMessage.applySettings`)
and starts it when it is turned on (`BarApp.settingsChanged()`); Bar.app reports whether it has
Accessibility (`BarMessage.statusDidChange`). The Desktop tab writes Desktop.app's defaults
(`DesktopSettings.current`) and tells it (`DesktopMessage.applySettings`).

## What Suite Settings does today

- **Settings**: Suite Settings, opened from the apps' menus on the right tab (`SettingsApp.show` in
  Explorer, which says so when Suite Settings isn't installed; `SuiteSettingsApp.show` in the others). It reads and writes
  Explorer's defaults by name (`SuiteDefaults`, which every settings store in ExplorerSettings and ExplorerCore goes
  through), then tells Explorer through distributed notifications (`ExplorerLink`): Explorer applies them as
  a change of its own (the desktop, Dock and Finder switch read theirs again, the rest redraws), does what
  only it can (check for updates, ask for Accessibility, empty the Trash, reopen), and reports back what the
  tabs show about it (`Status` keys, kept out of profiles) whenever its settings change. Tabs: General
  (what concerns every app: updates), Profile, then one tab per app (Explorer: Finder,
  files, windows, sidebar and Favorites; Toolbar; Trash: Restore, iCloud Drive's Trash, the folders it gathers,
  Empty Trash; Desktop, Bar, Viewer, Clipboard), SwiftUI forms in an `NSTabViewController` toolbar window.
  Profile: the settings of Explorer, Desktop, Bar, Clipboard, Viewer, Bindings and Launcher saved as named profiles on this Mac
  (Application Support/Explorer/Profiles) or in iCloud Drive › Explorer › Profiles, created from the current
  settings, saved again, moved, trashed, and loaded: the apps' defaults replaced and applied at once
  (Explorer, Desktop and Bar apply them, Clipboard is told); a setting
  Explorer can't apply while running makes it offer to reopen, after asking. Preferences and named
  windows' frames (Viewer, Clipboard's history; macOS keeps them on screen), never this Mac's state such
  as the hidden Dock's previous settings (`SettingsProfile`, `ProfileStore`).
  Add a tab when an app exists, not before.
- **Suite Settings Agent**: registered as a login item the first time Suite Settings opens
  (`AgentLoginItem`, `SMAppService`), one copy at a time, `LSUIElement`. In System Settings only (not
  Finder's settings), it covers what a running suite app takes over: Desktop & Dock's Dock sections while
  Bar runs and shows, Desktop's "Show items: On Desktop" checkbox and "Click wallpaper to reveal desktop"
  while Desktop runs, Spotlight's "Results from Clipboard" while Clipboard runs; nothing with Stage Manager
  on. A cover is a dark overlay, grey hatching and border, with a white button (red under the pointer)
  opening that app's tab in Suite Settings; clicks under it are swallowed (an event tap), the scroll wheel
  goes through. Panes are found by their title in every language, from macOS's own extensions; controls by
  Accessibility identifier, slider index or localized title. It waits on Accessibility notifications, no
  timer, and needs Accessibility (asked at each launch until granted). `LastSeen` in its defaults and the
  log (subsystem `local.suite.settings.agent`) say what it sees; `~/Library/Logs/Suite Settings Agent/`
  holds a record of a pane whose settings it couldn't find.

## Work to do

- Suite Settings (About windows, catalog of the apps from `suite`'s `catalog.json`, installing them).
- Settings in each app (⌘,), this app as the hub: each app's tabs move to a `<App>SettingsUI` product of
  its repository, laid out here.
- Moved branches (rebase on this `main`): `feat/bindings` (the Bindings tab), `feat/dock-parity` (the Dock
  tab), `feat/launcher/core` (the Dock tab's Launcher switch).

## Building and running

- `swift build` and `swift test` (`NativeBannerTests`) for development.
- `scripts/make-app.sh` builds `build/Suite Settings.app` (release), with the agent inside it, signs it with the "Suite Local Signing"
  certificate from the login keychain, so macOS permissions survive rebuilds (ad-hoc signing, the
  fallback, re-asks every build), and installs it as `~/Applications/Suite Settings.app`, the only copy Launch
  Services knows. It records the branch and commit in the Info.plist (`SuiteBuildBranch`,
  `SuiteBuildCommit`) and refuses to replace an installed copy built from another branch, or from an unknown
  one, unless `--force`: another session may be testing it. `INSTALL_DIR=` builds without installing. A
  running copy is relaunched from the new one, and the agent too.
- Never ask the user to open `build/Suite Settings.app` from a worktree.
- UI can't be checked by unit tests and screenshots of the user's screen are not available: check UI by
  rendering views offscreen (`cacheDisplay`) from a scratch package that compiles the sources.
- Releases: change `VERSION` (only `Z` is this repository's own), commit, push, then `scripts/publish.sh`
  pushes the tag; `.github/workflows/release.yml` builds, signs the app with "Suite Release Signing",
  signs `update.json` with the update key (both from the repository's `release` environment secrets),
  publishes the release and updates the cask in `love-suite/homebrew-tap`. The feed is
  `https://github.com/love-suite/suite-settings/releases/latest/download/update.json`
  (the GitHub repository it is built from). A change of `AA.Y` comes from the suite repository through
  `.github/workflows/sync-version.yml`. Until `Support/release-certificate.cer` and
  `Support/update-public-key.txt` exist, nothing can be released.

## The suite

This repository is part of Love Suite, one repository per app under `github.com/love-suite`:
`suite-core` (the shared library), `suite-files` (the file layer of the apps handling files),
`suite-guard`, `suite-desktop` (the desktop), `suite-explorer`, `suite-bar` (the Dock), `suite-viewer`,
`suite-clipboard`, `suite-settings` (the settings), `suite-awake` (keeping the Mac awake), `suite-launcher`, `suite-bindings`,
`suite-ai-organizer`; `homebrew-tap` (the tap `love-suite/tap`, one cask per app) and `suite` (the
front page, the suite's version, the scripts that act on every repository). Locally they sit side by side
in `~/GitHub/paul-amour/suite/`.

## Conventions (the same in every repository of the suite)

- The user writes in French and expects answers in French; everything in the code stays in English: code,
  comments, tests, docs, commit messages. Do not add co-author trailers.
- No "…" in menu items, buttons or messages: the user wants none, anywhere.
- Behaviour follows Windows unless Apple's design is asked for.
- Swift Package Manager, `swift-tools-version:5.9`, macOS 13+. Tests use Swift Testing (`import Testing`).
- Toolchain: swiftly, Swift 6.4.2 (`.swift-version`, git-ignored). If `swift test` complains about a
  missing toolchain: `swiftly use 6.4.2`.
- AppKit for windows that need fine control; SwiftUI is allowed for small panels (settings, pickers).
- No private APIs and no system modifications (SIP stays on).
- Git: one worktree per feature under `.worktrees/` (git-ignored), one branch per change
  (`feat/<feature>`, `fix/<area>/<what>`), merged into `main` one by one; `main` stays stable.
- Versions are `AA.Y`, then `AA.Y.Z` for a fix (`VERSION`, tag `vVERSION`: 27.1, then 27.1.1; SwiftPM reads
  `v27.1` as 27.1.0): `AA` is the latest macOS in production (27), `AA.Y` is the same in every repository of
  the suite so the apps work together, `Z` is this repository's own. A change of `AA.Y` is made in `suite`
  and reaches every repository. While a version is being prepared, `VERSION` doesn't move (27.1 now):
  development builds are `VERSION-dev.N`, N the commits since `VERSION` was set, merges aside, from 1 (`make-app.sh`),
  and a change another repository needs gets a development tag, `vVERSION-dev.N`, which releases nothing.
  Dependencies on other repositories of the suite (`suite-core`, `suite-files`, `suite-guard`, settings
  libraries) use
  `.upToNextMinor(from: "27.1.0-dev.1")` (the latest development tag, then the release);
  `Package.resolved` is committed. Tags are never moved once pushed. The build number (`CFBundleVersion`,
  which the updater compares) stays the number of commits.
- Changing two repositories at once: `swift package edit <Package> --path ../<repository>` points at the
  neighbour's working copy until its tag exists, `swift package unedit` goes back. Never committed.
- What two apps need lives in `suite-core` (file code in `suite-files`); an app's own code never goes into another app's repository, and
  an app exposes only its settings, as `<App>Settings`, for Suite Settings.
- Do not run commands that delete user data. Trash instead of delete.
- No code converting saved settings at launch. Before the first release nothing needs converting (the
  developer's own settings don't count): rename freely. Between released versions, a change to saved
  settings is a `SettingsMigration` (suite-core) for the version that brought it, given to the app's
  `SuiteUpdater`, which runs it once after the update.
