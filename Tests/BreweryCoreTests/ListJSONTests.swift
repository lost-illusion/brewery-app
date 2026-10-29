import Foundation
import Testing
@testable import BreweryCore

@Test func listJSON_decode_realFixture() throws {
    let snapshot = try ListSnapshot.decode(fixtureData("list.json"))
    let ace = try #require(snapshot.formulae.first { $0.name == "ace" })
    #expect(ace.linkedVersion == "8.0.8")
    #expect(snapshot.formulae.contains { $0.name == "ralphex" })
    #expect(snapshot.casks.map(\.token).sorted() == ["agterm", "revmux", "wireshark-app"])
    #expect(snapshot.casks.map(\.versions).allSatisfy { !$0.isEmpty })
}

@Test func listJSON_decode_adversarial_unknownKeysAndNulls() throws {
    let snapshot = try ListSnapshot.decode(fixtureData("list-adversarial.json"))
    let ace = try #require(snapshot.formulae.first { $0.name == "ace" })
    #expect(ace.linkedVersion == nil) // linked_version forced null; brand_new_field ignored
    #expect(snapshot.formulae.count == 2)
    #expect(snapshot.casks.count == 3)
}
