import Foundation
import Testing
@testable import BreweryCore

@Test func textList_singleVersion() {
    let rows = parseTextListVersions("ace 8.0.8\n")
    #expect(rows.count == 1)
    #expect(rows[0].name == "ace")
    #expect(rows[0].versions == ["8.0.8"])
}

@Test func textList_multiVersion() {
    let rows = parseTextListVersions("node 25.2.1 24.10.0\n")
    #expect(rows.count == 1)
    #expect(rows[0].name == "node")
    #expect(rows[0].versions == ["25.2.1", "24.10.0"]) // order preserved
}

@Test func textList_emptyAndBlankLines() {
    #expect(parseTextListVersions("").isEmpty)
    #expect(parseTextListVersions("\n\n   \n").isEmpty)
    #expect(parseTextListVersions("ace 8.0.8\n\n\nnode 25.2.1\n").count == 2)
}

@Test func textList_realFixture_hasRalphex() throws {
    let text = try #require(String(data: fixtureData("text-list-real.txt"), encoding: .utf8))
    let rows = parseTextListVersions(text)
    let ralphex = try #require(rows.first { $0.name == "ralphex" })
    #expect(ralphex.versions == ["1.0.1"]) // fallback keeps untrusted-tap rows the info JSON omits
    #expect(rows.contains { $0.name == "ace" })
}
