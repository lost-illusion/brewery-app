import Foundation
import Testing
@testable import BreweryCore

@Test func infoJSON_decode_realFixture() throws {
    let info = try InfoSnapshot.decode(fixtureData("info.json"))
    let ace = try #require(info.formulae.first { $0.name == "ace" })
    #expect(ace.installed.first?.version == "8.0.8")
    #expect(ace.installed.first?.time != nil) // epoch seconds → Date
    #expect(ace.bottleTag == "arm64_golden_gate")
    #expect(ace.tap == "homebrew/core")
    #expect(ace.linkedKeg == "8.0.8")
    let wireshark = try #require(info.casks.first { $0.token == "wireshark-app" })
    #expect(wireshark.installedVersion == "4.6.9") // cask installed is a STRING, not an array
    #expect(wireshark.versionLatest == "4.6.9")
    #expect(wireshark.autoUpdates == true)
    let agterm = try #require(info.casks.first { $0.token == "agterm" })
    #expect(agterm.autoUpdates == false) // null → false
}

@Test func infoJSON_decode_adversarial_missingOptionals() throws {
    let info = try InfoSnapshot.decode(fixtureData("info-adversarial.json"))
    let ace = try #require(info.formulae.first { $0.name == "ace" })
    #expect(ace.linkedKeg == nil)
    #expect(ace.deprecationReason == nil)
    #expect(ace.desc != nil) // surviving fields still decode
    #expect(ace.versionsStable == "8.0.8")
    #expect(info.casks.count == 3)
}

@Test func infoJSON_decode_caskDependsOn() throws {
    // depends_on is a mixed hash: formula/cask are name arrays, arch/macos are
    // requirement objects observed live (§45) — they must not break decoding.
    let info = try InfoSnapshot.decode(Data(#"""
    {"formulae":[],
     "casks":[{"token":"wireshark-app","installed":"4.6.9",
       "depends_on":{"formula":["wireshark"],"cask":["other-app"],
                     "macos":{">=":["14"]},"arch":[{"type":"arm","bits":64}]}}]}
    """#.utf8))
    let c = try #require(info.casks.first)
    #expect(c.dependsFormula == ["wireshark"])
    #expect(c.dependsCask == ["other-app"])
}

@Test func infoJSON_decode_deprecationFields() throws {
    let info = try InfoSnapshot.decode(Data(#"""
    {"formulae":[{"name":"py","full_name":"homebrew/core/py","installed":[],
      "deprecated":true,"deprecation_date":"2025-10-15","deprecation_reason":"deprecated_upstream",
      "disabled":true,"disable_date":"2026-10-15","disable_reason":"deprecated_upstream",
      "disable_replacement_formula":"py@3"}],
     "casks":[{"token":"old-app","installed":"1.0","deprecated":true,
      "deprecation_reason":"moved_to_mas","deprecation_replacement_cask":"new-app"}]}
    """#.utf8))
    let f = try #require(info.formulae.first)
    #expect(f.deprecationDate == "2025-10-15")
    #expect(f.disableDate == "2026-10-15")
    #expect(f.disabledReason == "deprecated_upstream")
    #expect(f.disableReplacementFormula == "py@3")
    #expect(f.deprecationReplacementCask == nil)
    let c = try #require(info.casks.first)
    #expect(c.deprecated == true)
    #expect(c.deprecationReason == "moved_to_mas")
    #expect(c.disabled == false) // missing key → false
    #expect(c.deprecationReplacementCask == "new-app")
}
