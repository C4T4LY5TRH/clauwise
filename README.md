# Clauwise

A small macOS menu bar app that shows your Claude plan usage (the 5-hour session and 7-day weekly limits) with a pace estimate and one line of plain-language advice.

> **Unofficial — not affiliated with or endorsed by Anthropic.**
> Clauwise reads the login Claude Code already keeps on your Mac and calls an undocumented usage endpoint, which may change or stop working at any time.

## What it shows

- **Session (5h)** and **Weekly (7d)** usage with reset times. The numbers come from your account, so they include usage from the web, the desktop app and Claude Code.
- **Pace**: how fast the current window is filling and where it is heading by the reset (can be turned off).
- **Advice**: one line such as "Good time to start deep work" or "On pace to exhaust … before reset".
- **Usage credits (overage)**: monthly spend against your own limit, if extra usage is turned on for your account.
- **Today's tokens** and **active model**: from Claude Code sessions on this Mac only. Web and desktop app usage can't be seen there.
- **Notifications** when a window crosses a threshold (presets: 70/90%, 50/80% or 85/95%), once per level per window, plus an alert (at most once a day) if the login stops working.
- **Optional**: your 5h/7d usage in the Claude Code status line.

## Requirements

- A Mac with Apple Silicon, running macOS 13 (Ventura) or later.
- Xcode Command Line Tools with Swift 5.9 or later: `xcode-select --install`.
- Claude Code installed and signed in on this Mac, on a Claude Pro or Max plan. Clauwise has no login of its own.

## Build and run

```sh
git clone https://github.com/C4T4LY5TRH/clauwise.git
cd clauwise
./build.sh
open Clauwise.app
```

`build.sh` builds a release binary, places it in `Clauwise.app` and signs it ad hoc (macOS only lets a signed app ask for notification permission). Clauwise lives in the menu bar only: no Dock icon, no window.

Tests: `swift test` (needs a toolchain that includes the Swift Testing framework).

## First run

- macOS asks whether Clauwise may send notifications. If you dismiss it, turn them on later in **System Settings → Notifications → Clauwise**.
- macOS may ask whether to allow access to the `Claude Code-credentials` Keychain item. Clauwise only reads it.
- After the first successful refresh, Clauwise asks **once** whether to show your usage in the Claude Code status line (it doesn't ask if you already have a status line of your own). Your answer is remembered, and you can change it any time from the menu (**Claude Code Status Line**).
- **Launch at Login** is in the menu. If you move `Clauwise.app` afterwards, switch it off and on again so macOS registers the new location.

## What it reads, writes and sends

| | What | Why |
|---|---|---|
| **Reads** | Keychain item `Claude Code-credentials`, read-only (via `/usr/bin/security`) | The OAuth token Claude Code stores. Clauwise never refreshes, changes or copies it. |
| | `~/.claude/projects/**/*.jsonl` | Today's token totals and the active model. |
| | `~/.claude/settings.json` | Only to show and manage the optional status line. |
| **Sends** | `GET https://api.anthropic.com/api/oauth/usage` | The usage numbers. Every 150 seconds, and when you open the menu, after sleep or when the network comes back, throttled to normally at most once every 90 seconds, with a longer pause after a rate-limit response. **Nothing else**: no analytics, no telemetry, no other servers. |
| **Writes** | `~/.clauwise/usage.json` | The latest snapshot, for other tools (see below). |
| | `~/Library/Logs/Clauwise.log` | Debug log: HTTP status codes and error types, never tokens or response bodies. |
| | App preferences (`io.github.c4t4ly5trh.clauwise`) | Your settings, plus refresh and notification bookkeeping. |
| | `~/.claude/settings.json`, **only if you opt in** | One `statusLine` entry marked `"_managedBy": "Clauwise"`. Your other settings are kept, a one-time backup is saved as `settings.json.clauwise-backup`, and a status line you set up yourself is never replaced. |
| | `~/.clauwise/recommendation-log.jsonl`, **off by default** | Optional usage history: one line per refresh, kept for 90 days. Turn it on with `defaults write io.github.c4t4ly5trh.clauwise recordUsageHistory -bool true`. |

### `usage.json`

Written atomically after every successful refresh, so a reader never sees a half-written file. Fields: `fetchedAt`, `fiveHourPercent`, `fiveHourResetsAt`, `sevenDayPercent`, `sevenDayResetsAt`, `extraUsageEnabled`, `extraUsagePercent`, `tokensTodayByModel`, `activeModel`.

### Claude Code status line

When it is on, Claude Code runs `Clauwise statusline`, which prints a line like `5h: 42%  7d: 19%  <model>  <current folder>` from `usage.json`. It makes no network requests. Claude Code re-runs it every 60 seconds and on its own events.

## Removing it

1. In the menu, switch off **Claude Code Status Line** (this removes only Clauwise's entry) and **Launch at Login**.
2. Quit Clauwise and delete `Clauwise.app`.
3. Optional clean-up: `rm -rf ~/.clauwise ~/Library/Logs/Clauwise.log` and `defaults delete io.github.c4t4ly5trh.clauwise`. The backup `~/.claude/settings.json.clauwise-backup` is yours to keep or delete.

## Limitations

- The usage endpoint is undocumented. Clauwise reads each field separately so one change doesn't break everything, but it can still stop working without notice.
- The endpoint allows only about one request every two minutes and is shared with Claude Code itself, so the numbers refresh every couple of minutes rather than live. Lowering the poll interval leads to rate-limit errors.
- Token totals and the active model cover Claude Code sessions on this Mac only.
- When the login expires, Clauwise asks you to open Claude Code once to refresh it; it never refreshes the token itself.
- Apple Silicon only.

## Licence

MIT. See [LICENSE](LICENSE).
