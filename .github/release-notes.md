<!-- Release ritual: before tagging, replace the Changes section below with a
     user-visible summary of the commits since the last tag (combine related
     commits, drop implementation detail), and the <VERSION> in the asset
     filename. The install section is reusable — keep it as-is. -->

## Changes

Since v0.2.1:

- Changed: package list rows are now two lines — name, then version (and description) starting at the name's left edge. Versions read as a digit-aligned column; a too-long version truncates with `…` in the middle instead of being clipped, and the full string stays in the tooltip.
- Changed: tap list rows get the same two-line treatment — name, then a left-aligned stats line; names no longer split mid-slash.
- Fixed: a failed tap action (bad tap name, refused untap, …) no longer locks the app — previously one failure disabled every button that could clear it and pinned the error banner. Every failure banner now has a **Dismiss** button, and the add-tap sheet lets you fix the name and retry in place.
- Fixed: the add-tap preview now names the exact repository `brew tap` will clone.

## Download and compatibility

Download `brewery-v0.2.2-macos-arm64.zip` from Assets below.

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
