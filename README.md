<p align="center">
  <img src="assets/app_icon.png" width="128" alt="Hamstapp icon" />
</p>

<h1 align="center">Hamstapp · 囤囤</h1>

<p align="center"><b>A local-first Android app &amp; APK manager, with a fully customisable launcher.</b></p>

<p align="center">
  <b>English</b> ｜ <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://flutter.dev"><img alt="Flutter" src="https://img.shields.io/badge/Flutter-3-02569B?logo=flutter&logoColor=white"></a>
  <a href="https://dart.dev"><img alt="Dart" src="https://img.shields.io/badge/Dart-3-0175C2?logo=dart&logoColor=white"></a>
  <img alt="Platform" src="https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white">
  <img alt="minSdk" src="https://img.shields.io/badge/minSdk-24-blue">
  <img alt="version" src="https://img.shields.io/badge/version-1.1-orange">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg"></a>
</p>

> Vibe-coded with DeepSeek V4.1 Flash / OpenCode

---

**Hamstapp** (囤囤, *tún tún* — “to hoard”) helps you keep track of everything installed on your phone:
why you installed each app, what you were using it for, which apps you actually launch — and turns all of that
into a fast, fully customisable launcher. Everything is stored locally: no account, no analytics, no telemetry.

> **The name** — *Hamstapp* is **Hamster** + **App**: a hamster stuffing apps into its cheeks.
> It pairs with the Chinese 囤囤 (*tún tún*, “to hoard”, pronounced *tún*), so the app is literally a hamster
> that hoards apps for you.

## 📸 Screenshots

<p align="center">
  <img src="docs/en-tiles.jpg" width="240" alt="Tile board">
  <img src="docs/en-categories.jpg" width="240" alt="Categories">
  <img src="docs/en-sync.jpg" width="240" alt="Remote APK sources">
</p>

## ✨ Features

### 🚀 Launch
- **Tile board** — a free-form grid where each app is a tile you can move and resize (1×1 up to 6×6).
  Multiple pages, per-tile label / padding / border, and two looks: **Colorful** and **Glass**.
- **Info tiles** — 30 kinds of live tiles that need no app behind them, in five groups the picker can
  filter by (Readings / Apps / 囤囤 / Tools / Actions):
  - *Readings* — clock, date, battery (level, temperature or both), storage, RAM, today's screen time,
    this month's mobile + Wi-Fi data, the next alarm, uptime, live network speed, unread total.
  - *Apps* — recently used, most used (or suggested for this time of day), new installs, long unused,
    favourites, biggest, and **folders** (a category, or a hand-picked set, opening as a grid).
  - *囤囤* — the latest snapshot and what changed since, apps still to sort out, the download cache,
    and a backup list's installed / missing counts.
  - *Tools* — torch, quick dial, countdown, world clock (optional date, or its difference from today),
    a note, and a battery / RAM / storage / data overview.
  - *Actions* — scan apps, take a snapshot, search apps, open the storage manager.
- **Tile gestures** — bind an action to a double tap or an upward swipe on any tile (open the app,
  its details, search, or jump to a page). Off by default, so a plain tap still launches instantly.
- **Drag one tile onto another** to make a real folder; dropping onto an existing folder adds to it.
- **Multi-select** (delete or move a batch to another page), **copy a page** with all its tiles, and
  **lock the layout** so nothing moves by accident.
- **App shortcuts** — long-press a tile to open the app's own long-press menu (WeChat's "Scan", …).
  Android only shows those to the current launcher, so this needs 囤囤 to be the default home app;
  the menu explains that instead of failing silently.
- **Global search** — one search icon in the header covers apps (including web entries), categories,
  backup lists, snapshots and a handful of screens that are otherwise buried in Settings.
- **Categories** — group apps with an emoji and a colour; reorder by hand or by name / count.
- **Favorites** — a quick grid of the apps you starred.
- **Recent** — launch history with *all / today / 7-day / 30-day* filters, sorted by recency or frequency,
  plus time-of-day **recommendations** learned from your habits.
- **Notification badges** — grant notification access, turn on *Capture notifications*, and app icons
  get an unread bubble: choose **count / dot / hidden**, set separately for the tile board and the rest.
  Badges follow **unread** semantics: dismissing a notification keeps the bubble, which clears when you
  open it, the app withdraws it, or you launch the app from 囤囤.
- **Launcher shortcuts** — long-press 囤囤's own icon for *Scan apps*, *Recent* and *Tiles*.

### 🖥 Home-screen widget
- **Recommended apps on the desktop.** A native Android widget (no Flutter engine, no background
  service) shows the same apps as **Recent → Recommendations** for the current hour — at most two
  rows — or the most used / pinned apps when there are no suggestions yet. The widget follows the
  system light / dark theme.
- **A tap launches directly and still counts.** Widget taps are recorded natively, then merged into
  囤囤's launch log the next time it opens, so the app also shows up in *Recent*, the usage trends
  and later recommendations. Apps launch through the same pinned launcher entry as the tile board
  (icon, label and activity), and hand-added web apps open in their own window (or the chosen browser).
- Add it from **Settings → Tiles → Home screen widget**; the same screen has a live preview and a
  switch to hide app names. The widget refreshes about every 30 minutes on the platform's own tick.

### 📦 App manager
- Scan installed apps (optionally including system apps); the list is cached for instant launch.
- Search by **name, package, pinyin initials, full pinyin** or fuzzy subsequence.
- Filter by scope (all / user / system), by state (favorite, categorised, has a reason, unorganized,
  uninstalled…) and by category; sort by name, install time, update time or size. The filter and sort
  you leave behind are remembered.
- Per-app page: launch, favourite, pin to tiles, install **reason**, **note**, categories, usage stats,
  APK analysis, export / share the APK, open the system app-info screen, uninstall — plus three cards:
  - **Storage** — APK, data and cache, a proportion bar, and a shortcut into the system screen to clear it.
  - **Permissions** — everything the app requests, sensitive and granted ones first, with a tap into the
    system permission screen.
  - **Signature** — the certificate fingerprint (tap to copy), subject, validity, and flags for
    self-signed / multiple signers / rotated keys.
- **Hidden apps** — hide an app from the list without deleting anything it carries (categories,
  reason, notes); the 「隐藏」 filter is where it comes back from.
- **Custom icons** — pick an image for any app; it is shrunk to 192 px and used everywhere (list,
  tiles, search) until you restore the launcher icon.
- **整理与体检 (Health)** — one screen for the things worth noticing: updates that added sensitive
  permissions or changed signer, the install-source breakdown, apps sharing a name (highlighted when
  their certificates differ), packages with several downloaded versions, and the hidden apps.
- **Real usage** — per-app foreground time for today / 7 / 30 days and this month's traffic per app,
  straight from the system (usage access), next to 囤囤's own launch history.
- **Uninstall records** — when an app disappears it is kept together with the reason you give,
  so reinstalls and snapshots stay meaningful.

### 🔐 Permissions & storage
- **Permission audit** — the other direction: for each capability, who holds it. Microphone, camera,
  location (and background location), contacts, phone & call log, SMS, photos / music / files, calendar,
  body sensors, notifications, draw-over-other-apps, install-unknown-apps, modify system settings,
  usage access, notification access, accessibility and the battery-optimisation whitelist — each entry
  taps through to the app.
- **Storage manager** — what 囤囤 itself is using (icon cache, scan cache, downloaded APKs, scratch files,
  other data), with per-row clearing, plus an **app usage ranking** (APK + data + cache per app, biggest
  first, straight to the system clear screen).
- Where Android requires a grant — *usage access* for per-app sizes, screen time and data — the screen
  says so and offers the switch instead of showing zeros.

### 🌐 Web apps
- Installed **web apps** (WebAPK / Trusted Web Activity) are detected during a scan and marked with a 🌐,
  and can be inspected from Settings → 网页应用检测.
- Add a website by hand and it becomes a first-class entry: same list, tiles, favourites, categories,
  search and usage log as an app, with its own icon.
- 囤囤 reads the site's **web app manifest** (name, start URL, scope, display mode, theme / background
  colour, icons) and opens it the way the site asks for: a **standalone window** (its own task, no address
  bar, per-entry status-bar behaviour), or handed to a **browser you choose**.
- Leave the manifest's scope and the window stays, but shows an address bar — the standard's rule for
  sign-in pages on another host — so logins keep the same session instead of being thrown to a browser.
- This is 囤囤's own WebView host, so it does not share cookies with your browser; when a tap needs a real
  browser, 囤囤 asks the system where the URL would go and prefers an installed web app, so it can open in
  the browser's own app window when one exists.

### 🗂 Snapshots & backup
- **Snapshots** capture the installed list and all your annotations (including app icons), so you can
  **diff** two points in time (added / removed / updated) and **restore** annotations later.
- **Backup lists** are curated sets of packages with installed / missing counts — handy as reinstall checklists.

### 🌐 Remote APK sources
- Browse and install from **FTP**, **SMB / Samba** and **WebDAV** sources.
- At a glance: new, update, already installed, or newer-than-yours; one-tap download + install.
- Download **cache** with per-file version history, *keep all versions*, orphan cleanup and size reporting.
- **APK analyzer**: SHA-256 / MD5 hashes, manifest flags, component counts, permissions & features,
  native ABIs / DEX / zip breakdown, and v1 / v2 / v3 signing certificates — including a signature
  match check against the installed app before updating.

### 📈 Usage insights
- **Stats** over 7 / 30 / 90 days: most used, **neglected** (used before, then stopped) and never-launched apps.
- **Recommendations** based on the time of day you usually open each app.

### 🔒 Data & privacy
- **Export / import** the whole state as one JSON package. Import shows what the package holds and
  how much of it is already here, and can **merge** instead of replacing everything.
- **Back up to WebDAV** — write the package into one of the configured WebDAV folders, and restore
  from the list of backups there (same preview/merge step).
- **Snapshot difference export** — the comparison page writes its result (versions, new/removed
  permissions, signer changes) to a Markdown file.
- **Automatic snapshots** — off by default; when enabled, a scan that finds changes after N days
  takes one on its own.
- A persistent **icon cache** so icons appear instantly, with an on-demand refresh.
- **Offline by default** — the only network access is the remote sources you configure yourself.
- **Notification badges** are read on-device from the system notification access you grant; nothing is uploaded.
- An **opt-in log** (off by default) records scan / install / sync / launch / notification events on-device;
  filter it by module and copy the result when reporting a problem.

### 🎨 Interface
- Light / dark / system theme, custom seed colour, **Chinese & English**.
- **Date format** — five styles (`2026-10-17`, `2026/10/17`, `10/17/2026`, `17/10/2026`,
  `2026年10月17日`) and 24-hour or `1:05 PM`; one setting drives every screen and tile.
  Relative times (`3 days ago`, `today`) stay relative.
- Navigation: bottom bar, side rail, or a collapsed button.
- **Icon packs** — use the icons of an installed icon pack instead of the launcher's (the platform
  appfilter convention; system icons stay the default).
- **Font size and density** — 85 / 100 / 115 / 130 % on top of the device's own scale, and a compact
  list density.
- On a tablet or in landscape the app list and the app page sit side by side instead of pushing pages.
- Adjustable haptics, optional full-screen (hide the status bar), remember last position.

## 📥 Install

Download the latest `hamstapp-*-arm64-v8a.apk` from the [Releases](https://github.com/whynbnb/hamstapp/releases)
page and install it on an **arm64-v8a** device running **Android 7.0+ (API 24)**.

Some features ask for extra grants and work without them: **notification access** (unread badges),
**usage access** (per-app sizes, screen time, data), **install unknown apps** (installing from a source),
and **all-files / package visibility** for the scan.

## 🛠 Build from source

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart 3) and the Android SDK.

```bash
git clone https://github.com/whynbnb/hamstapp.git
cd hamstapp
flutter pub get

# Run on a connected device
flutter run

# Slim, obfuscated arm64-v8a release APK -> dist/
bash scripts/release.sh
```

## 🧱 Tech stack

- **Flutter / Dart 3** with `provider` for state, `path_provider` for local JSON storage,
  `lpinyin` for search and `file_picker` for import/export.
- A small **Kotlin** `MethodChannel` plugin on top of the Android `PackageManager`:
  app scan & icons, launching, install / uninstall / share, APK parsing & signing,
  storage & usage statistics, permissions and app-ops, camera torch, FTP (`commons-net`),
  SMB (`jcifs-ng`) and vibration.
- **WebDAV** is implemented in Dart over HTTP.

## 🚫 Not planned

These are deliberately out of scope. They need system-level privileges, vendor private APIs, or
would break the local-first design, so they will not be added — listed here so they stop coming
back as suggestions:

- **Freezing / disabling apps** — Shizuku, root or device-owner; too much setup and risk for what it adds.
- **Autostart / background management** — every vendor hides its own components; supporting it means
  hard-coding each ROM.
- **Battery-drain ranking** — `BatteryStats` is only readable with system-level permissions.
- **Weather or other cloud data** — needs network and location; the app stays offline by default.
- **Accounts / a sync service** — no account, no telemetry, no server of ours.

## 📝 Changelog

- **1.1** — permission audit; per-app storage / permissions / signature cards; storage manager and app
  usage ranking; 30 info tiles with their own settings; web-app entries with a standalone window or a
  browser of your choice; launcher shortcuts; date-format and 24-hour settings; “unsupported tile”
  handling instead of silent removal.
- **Unreleased** — tile gestures, drag-into-folder, multi-select / page copy / layout lock, app
  shortcuts, global search; hidden apps, custom icons, 整理与体检, per-app usage and traffic, install
  source breakdown; icon packs, font size / density, two-pane tablets; auto snapshots, WebDAV
  backup, preview/merge import, snapshot-difference export; home-screen widget with hourly
  recommendations whose taps count as launches.
- **1.0** — first release: app manager, tile board and categories, snapshots and backup lists,
  remote APK sources with the APK analyzer, usage insights, export / import.

## 📄 License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 0x574859
