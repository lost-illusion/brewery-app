<!-- Release ritual: before tagging, replace the Changes section below with a
     user-visible summary of the commits since the last tag (combine related
     commits, drop implementation detail), and the <VERSION> in the asset
     filename. The install section is reusable — keep it as-is. -->

## Changes

- Added: <user-visible capability — omit if none>
- Changed: <workflow or UI change — omit if none>
- Fixed: <observable problem — omit if none>
- Known issues / upgrade notes: <release-specific caveats — omit if none>

## Download and compatibility

Download `brewery-v<VERSION>-macos-arm64.zip` from Assets below.

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
