Early personal project — feedback welcome, no support promises.

**Getting past Gatekeeper.** Builds are ad-hoc codesigned (no Developer ID), and
browser downloads normally carry a quarantine flag Gatekeeper will block:

1. Unzip with Finder or `ditto` (other unzippers can damage bundle metadata).
2. Move Brewery.app to its final location (e.g. `/Applications`) **before**
   enabling the optional background update checks — the LaunchAgent records the
   executable path at enable time.
3. Open it; macOS will refuse once. Then **System Settings → Privacy &
   Security → "Open Anyway"**. (Right-click → Open no longer bypasses
   Gatekeeper since macOS 15 Sequoia.) Command route instead:
   `xattr -dr com.apple.quarantine "/Applications/Brewery.app"` — that clears
   quarantine, nothing more; the app is not notarized.
4. Needs macOS 26+, Homebrew installed, and an Apple Silicon (arm64) Mac.

Release builds run `swift test` first, then `Tools/make-app-bundle.sh`, on
GitHub's `macos-26` runner.
