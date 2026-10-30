import Foundation
import Testing
@testable import BreweryCore

@Test func parseChangelogBlocks_agtermStyleBody() {
    // Shape modeled on the live umputun/agterm v0.39.1 body probe (2026-10-30).
    let body = """
    ### Improved

    - the GUI `ask` dialog matches the box: a lighter rounded box
      with a thin outline
    - second item

    Some closing **paragraph** line one
    line two joins as one paragraph.
    """
    let blocks = parseChangelogBlocks(body)
    #expect(blocks.map(\.kind) == [.heading, .bullet, .bullet, .paragraph])
    #expect(blocks[0].text == "Improved")
    #expect(blocks[0].level == 3)
    #expect(blocks[1].marker == "•")
    #expect(blocks[1].text == "the GUI `ask` dialog matches the box: a lighter rounded box with a thin outline") // lazy continuation merged
    #expect(blocks[3].text == "Some closing **paragraph** line one line two joins as one paragraph.")
    #expect(blocks.map(\.id) == [0, 1, 2, 3])
}

@Test func parseChangelogBlocks_numberedKeepsMarkerNestedIndents() {
    let blocks = parseChangelogBlocks("1. first\n2) second\n  - nested under nothing\n")
    #expect(blocks.map(\.kind) == [.bullet, .bullet, .bullet])
    #expect(blocks[0].marker == "1.")
    #expect(blocks[1].marker == "2.")
    #expect(blocks[2].marker == "•")
    #expect(blocks[2].level == 1) // 2 spaces = one indent depth
    #expect(blocks[0].level == 0)
}

@Test func parseChangelogBlocks_codeFencePassesThroughRaw() {
    let body = "Before\n\n```sh\n$ brew install wget\n<b>raw</b>\n```\n\nAfter"
    let blocks = parseChangelogBlocks(body)
    #expect(blocks.map(\.kind) == [.paragraph, .code, .paragraph])
    #expect(blocks[1].text == "$ brew install wget\n<b>raw</b>") // no language tag, no inline parsing
}

@Test func parseChangelogBlocks_numberedVersionStaysParagraph() {
    // "1.25.0 is out" is prose; CommonMark needs whitespace after "1." for a list.
    let blocks = parseChangelogBlocks("1.25.0 is out")
    #expect(blocks.count == 1)
    #expect(blocks[0].kind == .paragraph)
    #expect(blocks[0].text == "1.25.0 is out")
}

@Test func parseChangelogBlocks_headingNeedsHashesAndSpace() {
    let blocks = parseChangelogBlocks("#NoSpace stays prose\n## Real\n###### Six\n####### Seven is prose")
    #expect(blocks.map(\.kind) == [.paragraph, .heading, .heading, .paragraph])
    #expect(blocks[1].level == 2)
    #expect(blocks[2].level == 6)
    #expect(blocks[0].text == "#NoSpace stays prose")
}

@Test func parseChangelogBlocks_emptyAndBlankBodies() {
    #expect(parseChangelogBlocks("").isEmpty)
    #expect(parseChangelogBlocks("\n\n   \n").isEmpty)
}

@Test func parseChangelogBlocks_bulletsEndParagraphs() {
    // A bullet closes the paragraph above it without a blank line (GitHub does).
    let blocks = parseChangelogBlocks("intro line\n- item")
    #expect(blocks.map(\.kind) == [.paragraph, .bullet])
}
