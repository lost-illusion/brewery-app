<!-- Release ritual: before tagging, replace the Changes section below with a
     user-visible summary of the commits since the last tag (combine related
     commits, drop implementation detail), and the <VERSION> in the asset
     filename. The install section is reusable — keep it as-is. -->

## Changes

Since v0.2.0:

- Changed: background update checks now run **hourly on the hour** (was daily at 10:00), and a scheduled run performs `brew update` first so the catalog is fresh before versions are compared. Runs missed while the Mac slept coalesce into one catch-up on wake.
- Changed: the middle bar is pinned to 230 pt, and version text never wraps mid-number.
- Fixed: the background update agent now installs correctly when Brewery lives in a folder whose name contains `&` (e.g. `/Applications/foo & bar/Brewery.app`) — the recorded path was breaking the LaunchAgent plist.
- Known issues / upgrade notes: if the background agent was enabled under v0.2.0, just relaunch Brewery once — it rewrites and reloads the agent automatically.

## Download and compatibility

Download `brewery-v0.2.1-macos-arm64.zip` from Assets below.

Requires macOS 26+, an Apple Silicon (arm64) Mac, and Homebrew installed.
Verified against Homebrew 7.0.11.

Early personal project — feedback welcome, no support promises; behavior may
still change during 0.x.

## Install or update

1. Quit Brewery if it is running.
2. Unzip with Finder or `ditto` (other unzippers can damage bundle metadata).
3. Move Brewery.app to its final location (e.g. `/Applications`), replacing
   the previous copy — **before** enabling the optional background update
   checks; the LaunchAgent records the executable path at enable time.
4. Open it; macOS will refuse once. Then **System Settings → Privacy &
   Security → "Open Anyway"**. (Right-click → Open no longer bypasses
   Gatekeeper since macOS 15 Sequoia.) Command route instead:
   `xattr -dr com.apple.quarantine "/Applications/Brewery.app"` — that clears
   quarantine, nothing more; the app is ad-hoc codesigned (no Developer ID),
   not notarized.
