import Testing
@testable import BreweryCore

@Test func history_backForwardAcrossSelections() {
    var h = NavigationHistory()
    #expect(h.current == nil)
    #expect(!h.canGoBack && !h.canGoForward)

    h.select("a"); h.select("b"); h.select("c")
    #expect(h.current == "c")

    #expect(h.goBack() == "b")
    #expect(h.goBack() == "a")
    #expect(!h.canGoBack)
    #expect(h.goBack() == nil)

    #expect(h.goForward() == "b")
    #expect(h.goForward() == "c")
    #expect(!h.canGoForward)
    #expect(h.goForward() == nil)
}

@Test func history_reselectingCurrentIsNoOp() {
    var h = NavigationHistory()
    h.select("a"); h.select("b")
    h.goBack()                 // viewing "a" via back
    h.select("a")              // selection write-back must not duplicate the entry
    #expect(h.entries == ["a", "b"])
    #expect(h.index == 0)
    #expect(h.canGoForward)
}

@Test func history_newSelectionTruncatesForwardBranch() {
    var h = NavigationHistory()
    h.select("a"); h.select("b"); h.select("c")
    h.goBack()                 // at "b"; forward entry "c" still exists
    h.select("d")
    #expect(h.entries == ["a", "b", "d"])
    #expect(h.current == "d")
    #expect(!h.canGoForward)
}

@Test func history_emptyNavigationStaysSafe() {
    var h = NavigationHistory()
    #expect(h.goBack() == nil)
    #expect(h.goForward() == nil)
    #expect(h.entries.isEmpty && h.index == -1)
}
