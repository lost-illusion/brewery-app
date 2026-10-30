import Foundation
import Testing
@testable import BreweryCore

private func item(_ id: String, _ name: String, kind: BrewItem.Kind = .formula, tap: String?) -> BrewItem {
    BrewItem(id: id, kind: kind, name: name, fullName: id, tap: tap,
             installedVersions: ["1.0"], linkedVersion: "1.0", optlinkedVersion: nil, pinnedVersion: nil,
             latestVersion: nil, outdated: nil, infoOutdated: nil, infoVersion: nil, isPinned: false, isDeprecated: false, deprecationReason: nil,
             isDisabled: false, disabledReason: nil, deprecationDate: nil, disableDate: nil,
             replacementFormula: nil, replacementCask: nil, desc: nil, homepage: nil, installedAt: nil,
             kegOnly: false, autoUpdates: false, dependencies: [], sourceState: .complete)
}

// MARK: - Decoding

@Test func tapInfo_decodesRealTapInfoShape() throws {
    let taps = try TapInfo.decode(fixtureData("taps.json"))
    #expect(taps.count == 3)

    let external = try #require(taps.first { $0.name == "umputun/apps" })
    #expect(external.isExternal)
    #expect(external.installed)
    #expect(external.trusted == false)
    #expect(external.remote == "https://github.com/umputun/homebrew-apps")
    #expect(external.head == "1391b964968f7bea4711911f4500de2aadd88a85") // JSON key is "HEAD", not "head"
    #expect(external.branch == "master")
    #expect(external.lastCommitText == "2 days ago") // brew's own relative wording
    #expect(external.onDiskPath == "/opt/homebrew/Library/Taps/umputun/homebrew-apps")
    #expect(external.availableCount == 4) // 2 formulae + 2 casks offered, installed or not
    // *_files are lists of .rb paths, not counts (live output, verified 2026-10-30)
    #expect(external.formulaFiles == ["/opt/homebrew/Library/Taps/umputun/homebrew-apps/Formula/ralphex.rb",
                                      "/opt/homebrew/Library/Taps/umputun/homebrew-apps/Formula/revdiff.rb"])
    #expect(external.caskFiles.count == 2)
    #expect(external.commandFiles.isEmpty)

    let core = try #require(taps.first { $0.name == "homebrew/core" })
    #expect(!core.isExternal)
    #expect(!core.installed) // API mode: core is not a git checkout on disk
    #expect(core.formulaFiles.isEmpty && core.caskFiles.isEmpty && core.commandFiles.isEmpty) // git block absent
    #expect(core.resolvedRemote == "https://github.com/Homebrew/homebrew-core")
}

@Test func tapInfo_sortsExternalTapsFirst() throws {
    let sorted = sortedTapsForDisplay(try TapInfo.decode(fixtureData("taps.json")))
    #expect(sorted.map(\.name) == ["umputun/apps", "homebrew/cask", "homebrew/core"])
}

@Test func tapInfo_missingAndNullKeysDecodeToDefaults() throws {
    let taps = try TapInfo.decode(fixtureData("taps-adversarial.json"))

    let mini = try #require(taps.first { $0.name == "example/mini" })
    #expect(mini.installed == false)
    #expect(mini.trusted == nil) // absent → unknown, never "untrusted"
    #expect(mini.formulaNames.isEmpty)
    #expect(mini.user == "example" && mini.repo == "mini") // derived from the name
    #expect(mini.resolvedRemote == "https://github.com/example/homebrew-mini")

    let nulls = try #require(taps.first { $0.name == "example/nulls" })
    #expect(nulls.trusted == nil) // explicit null
    #expect(nulls.caskTokens.isEmpty) // null list
    #expect(nulls.remote == nil)
    #expect(nulls.availableCount == 0)

    let collide = try #require(taps.first { $0.name == "collide/tap" })
    #expect(collide.commandFiles.isEmpty) // null list
    #expect(taps.count == 3) // unknown keys elsewhere do not break the array
}

@Test func tapInfo_namesOnlyFallbackMarksHomebrewTapsOfficial() {
    let taps = parseTapNames("umputun/apps\nhomebrew/core (custom remote)\n\n").map(TapInfo.init(name:))
    #expect(taps.map(\.name) == ["umputun/apps", "homebrew/core"])
    #expect(taps[0].isExternal && taps[0].installed)
    #expect(!taps[1].isExternal)
    #expect(taps.allSatisfy { $0.availableCount == 0 }) // names carry no contents
}

@Test func tapInfo_textFallbackIgnoresJunkLines() {
    #expect(parseTapNames("\n   \nnota tap\nuser/repo extra\n") == ["user/repo"])
}

// MARK: - Name / remote validation (before any mutating brew call)

@Test func tapName_acceptsQualifiedNames() {
    guard case .success(let parts) = parseTapName("umputun/apps") else {
        Issue.record("rejected a well-formed tap name"); return
    }
    #expect(parts.user == "umputun" && parts.repo == "apps")

    guard case .success(let padded) = parseTapName("  Mi.User/homebrew-x_1 ") else {
        Issue.record("rejected a padded tap name"); return
    }
    #expect(padded.user == "Mi.User" && padded.repo == "homebrew-x_1")
}

@Test(arguments: ["", "umputun", "umputun/", "/repo", "a/b/c", "a b/c", "a/b c", "user/repo!"])
func tapName_rejectsMalformed(invalid: String) {
    switch parseTapName(invalid) {
    case .success: Issue.record("accepted invalid tap name “\(invalid)”")
    case .failure: break
    }
}

@Test func tapName_problemsCarryReadableMessages() {
    #expect(problem("umputun")?.message == "tap names look like user/repo")
    #expect(problem("")?.message == "enter a tap name")
    #expect(problem("umputun/")?.message == "both user and repo are required")
    #expect(problem("a/ b")?.message.contains("not allowed") == true)
}

private func problem(_ raw: String) -> TapNameProblem? {
    if case .failure(let p) = parseTapName(raw) { return p }
    return nil
}

@Test func tapRemote_validation() {
    #expect(validateTapRemote("") == nil) // empty means the GitHub shortcut form
    #expect(validateTapRemote("https://github.com/u/homebrew-r.git") == nil)
    #expect(validateTapRemote("git://host/repo") == nil)
    #expect(validateTapRemote("ssh://git@host/repo") == nil)
    #expect(validateTapRemote("github.com/u/homebrew-r") != nil) // no scheme → brew's two-arg form needs one
    #expect(validateTapRemote("https://host /repo") != nil)
    #expect(validateTapRemote("https:homebrew-r") != nil) // scheme without a repository
}

// MARK: - Contents vs inventory

@Test func tapContents_marksInstalledItemsAndLeavesTheRestNotInstalled() throws {
    let tap = try #require(try TapInfo.decode(fixtureData("taps.json")).first { $0.name == "umputun/apps" })
    let inventory = [
        item("agterm", "agterm", kind: .cask, tap: "umputun/apps"), // cask rows key on the bare token (§47)
        item("ralphex", "ralphex", tap: nil), // untrusted tap → brew info skipped it, so tap is unknown (§43)
        item("revdiff", "revdiff", tap: "homebrew/core"), // same name, different tap → not this one's
    ]
    let contents = tapContents(of: tap, inventory: inventory)

    #expect(contents.entries.map(\.name) == ["ralphex", "revdiff", "agterm", "revmux"]) // formulas then casks, tap order
    #expect(contents.installedCount == 2)
    #expect(contents.filtered("ag").map(\.name) == ["agterm"])
    #expect(contents.entries.first { $0.name == "agterm" }?.installed?.id == "agterm")
    #expect(contents.entries.first { $0.name == "ralphex" }?.installed?.id == "ralphex")
    #expect(contents.entries.first { $0.name == "revmux" }?.installed == nil)
    #expect(contents.entries.first { $0.name == "revdiff" }?.installed == nil) // tap mismatch, despite the name match
}

@Test func tapContents_listsClonedTapContentsBareThoughBrewReportsThemQualified() throws {
    // A cloned tap reports "umputun/apps/cronn"; an API tap reports "ace".
    let tap = try #require(try TapInfo.decode(fixtureData("taps.json")).first { $0.name == "umputun/apps" })
    #expect(tap.formulaNames.contains("umputun/apps/ralphex")) // raw form kept on TapInfo
    #expect(tapContents(of: tap, inventory: []).entries.map(\.name) == ["ralphex", "revdiff", "agterm", "revmux"])
}

@Test func tapContents_kindMismatchDoesNotCrossFormulaeAndCasks() throws {
    let tap = try #require(try TapInfo.decode(fixtureData("taps-adversarial.json")).first { $0.name == "collide/tap" })
    let inventory = [
        item("homebrew/core/ace", "ace", kind: .formula, tap: "homebrew/core"),
        item("firefox", "firefox", kind: .cask, tap: "homebrew/cask"),
    ]
    let contents = tapContents(of: tap, inventory: inventory)
    #expect(contents.installedCount == 0) // a core formula named "ace" is not collide/tap's "ace"
}

@Test func tapContents_officialTapCountsItsOwnInstalledRows() throws {
    let tap = try #require(try TapInfo.decode(fixtureData("taps.json")).first { $0.name == "homebrew/core" })
    let inventory = [item("ace", "ace", tap: "homebrew/core"), item("agterm", "agterm", kind: .cask, tap: "umputun/apps")]
    let contents = tapContents(of: tap, inventory: inventory)
    #expect(contents.entries.map(\.name) == ["ace", "bat"])
    #expect(contents.installedCount == 1)
}
