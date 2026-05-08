# Codex Limits

Codex Limits is a small native macOS menu bar utility for watching Codex usage limits.

It reads the local Codex auth file, calls Codex's structured usage endpoint, and shows:

- the lowest active limit in the menu bar
- 5-hour and weekly remaining percentages
- reset times
- credit status
- local trend history with hoverable time-series charts
- optional low-limit notifications

The app does not use screenshots, OCR, or screen recording.

## Requirements

- macOS 14 or newer
- Xcode command line tools
- A signed-in Codex installation with `~/.codex/auth.json`

## Build

```sh
swift build
swift test
```

## Probe

```sh
swift run codex-limits-probe
```

The probe prints the parsed `RateLimitSnapshot` JSON or a clear error.

## Run

```sh
./scripts/create-app-bundle.sh
open ".build/Codex Limits.app"
```

The menu bar app refreshes on launch, every 5 minutes, and whenever you click Refresh.

## Package

```sh
./scripts/package-local.sh
```

This creates `dist/Codex Limits.app` and `dist/Codex Limits.zip`, adds a local icon, and signs the app ad hoc for local use.

## Privacy

Codex Limits reads `~/.codex/auth.json` to make the same structured usage request that Codex uses. It does not store tokens or credentials. It only stores parsed, non-secret usage snapshots and local history under:

```text
~/Library/Application Support/Codex Limits/
```

Do not publish local build output, packaged apps, copied snapshots, history files, or auth files.
