# Changelog

## 1.0 (first public release)

### Fixed

- Respects the usage endpoint's rate limit: a cooldown after a rate-limit response, a throttle that survives a relaunch, and one refresh schedule instead of several overlapping ones.
- One unexpected field in the API response no longer breaks the whole display; each field is read on its own.
- Usage notifications no longer repeat after a relaunch, or when the reported reset time shifts by a second or two.
- Pace indicator: readings from before a reset no longer distort the new window, a short pause no longer drops it straight to "idle", and its history survives a relaunch.
- Advice no longer flips back and forth between refreshes, and no longer says "critical" in the last half hour before a reset.
- Shows "no active session" instead of a frozen "refreshing…" when no 5-hour window is running.
- Extra-usage amounts are shown in the right currency units.
- No longer keeps the Mac from going to sleep.
- The Claude Code status line no longer shows stale numbers after the Mac wakes.
- A quick relaunch no longer leaves the menu stuck on the loading placeholder.
- The status-line setup never overwrites a status line you set up yourself.
