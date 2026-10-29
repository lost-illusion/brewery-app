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
