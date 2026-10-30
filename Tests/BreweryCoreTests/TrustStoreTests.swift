import Foundation
import Testing
@testable import BreweryCore

// `brew trust --json=v1` shape (captured 2026-10-30, compat §22) and brew's
// on-disk store shape (~/.homebrew/trust.json) — one decoder for both.

@Test func trustStore_decodesCLIShape() throws {
    let store = try TrustStore.decode(fixtureData("trust.json"))
    #expect(store.formulae == ["umputun/apps/revdiff"])
    #expect(store.casks == ["umputun/apps/agterm", "umputun/apps/revmux"])
    #expect(store.taps.isEmpty)
    #expect(store.isTrusted(qualified: "umputun/apps/revdiff", kind: .formula))
    #expect(!store.isTrusted(qualified: "umputun/apps/revdiff", kind: .cask)) // grants are kind-qualified
    #expect(!store.isTrusted(qualified: "umputun/apps/cronn", kind: .formula))
}

@Test func trustStore_decodesOnDiskStoreKeys() throws {
    let json = """
    {"trustedcasks":["umputun/apps/agterm"],"trustedformulae":["umputun/apps/revdiff"]}
    """
    let store = try TrustStore.decode(Data(json.utf8))
    #expect(store.formulae == ["umputun/apps/revdiff"])
    #expect(store.casks == ["umputun/apps/agterm"])
    #expect(store.taps.isEmpty && store.commands.isEmpty) // missing arrays → empty, not an error
}

@Test func trustStore_toleratesUnknownAndMissingKeys() throws {
    let store = try TrustStore.decode(Data("""
    {"taps":["someone/tap"],"future_key":{"nested":true}}
    """.utf8))
    #expect(store.taps == ["someone/tap"])
    #expect(store.formulae.isEmpty && store.casks.isEmpty)
}
