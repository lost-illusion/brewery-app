import Foundation
import Testing
@testable import BreweryCore

private func item(_ kind: BrewItem.Kind, _ name: String, _ outdated: OutdatedState?,
                  pinned: Bool = false) -> BrewItem {
    BrewItem(id: name, kind: kind, name: name, fullName: name, tap: "homebrew/core",
             installedVersions: ["1.0"], linkedVersion: "1.0", optlinkedVersion: nil,
             pinnedVersion: nil, latestVersion: nil, outdated: outdated,
             infoOutdated: nil, infoVersion: nil, isPinned: pinned,
             isDeprecated: false, deprecationReason: nil, isDisabled: false, disabledReason: nil,
             deprecationDate: nil, disableDate: nil, replacementFormula: nil, replacementCask: nil,
             desc: nil, homepage: nil, installedAt: nil, kegOnly: false,
             autoUpdates: false, dependencies: [], sourceState: .complete)
}

private func key(_ kind: BrewItem.Kind, _ name: String, _ version: String) -> UpdateKey {
    UpdateKey(kind: kind, fullName: name, targetVersion: version)
}

@Test func eligible_onlyConcreteUpdateAvailable() {
    let items = [
        item(.formula, "ace", .updateAvailable(latest: "8.1.0")),
        item(.cask, "wireshark-app", .updateAvailable(latest: "4.4.6")),
        item(.formula, "pinnedpkg", .updateAvailable(latest: "2.0"), pinned: true),
        item(.cask, "selfcask", .selfUpdating(latestKnown: "3.1")),
        item(.formula, "unk", .unknown),
        item(.formula, "cur", .upToDate),
        item(.formula, "nil", nil),
    ]
    #expect(eligibleUpdateKeys(items: items) == [key(.formula, "ace", "8.1.0"),
                                                  key(.cask, "wireshark-app", "4.4.6")])
}

@Test func decision_firstCheckAnnouncesWholeBacklog() {
    let current: Set<UpdateKey> = [key(.formula, "ace", "8.1.0"), key(.cask, "wi", "4.4.6")]
    let outcome = digestDecision(current: current, stored: UpdateNotifyState(), now: Date())
    #expect(outcome.newState?.announced == current)
    #expect(outcome.newState?.lastDigestAt != nil)
    if case .announce(let text, let total) = outcome.action {
        #expect(total == 2)
        #expect(text.title == "2 packages have newer versions")
        #expect(text.body == "1 formula and 1 cask. Open brewery to review.")
    } else { Issue.record("expected announce") }
}

@Test func decision_announcedPairsDoNotReFire() {
    var stored = UpdateNotifyState()
    stored.announced = [key(.formula, "ace", "8.1.0")]
    stored.lastDigestAt = Date().addingTimeInterval(-100_000)
    let outcome = digestDecision(current: [key(.formula, "ace", "8.1.0")], stored: stored, now: Date())
    #expect(outcome.action == .nothing)
    #expect(outcome.newState?.announced == stored.announced)
}

/// Regression: a still-outdated, already-announced backlog is NOT "resolved" —
/// the coordinator withdrew the delivered digest on this outcome, so a headless
/// 10:00 digest vanished the moment the GUI checked again.
@Test func decision_partiallyResolvedBacklogIsNotResolved() {
    var stored = UpdateNotifyState()
    stored.announced = [key(.formula, "ace", "8.1.0"), key(.cask, "wi", "4.4.6")]
    stored.lastDigestAt = Date().addingTimeInterval(-60)
    let outcome = digestDecision(current: [key(.cask, "wi", "4.4.6")], stored: stored, now: Date())
    #expect(outcome.action == .nothing)
    #expect(outcome.newState?.announced == [key(.cask, "wi", "4.4.6")])
}

@Test func decision_versionBumpRefiresEvenWithSameTotal() {
    var stored = UpdateNotifyState()
    stored.announced = [key(.formula, "ace", "8.1.0")]
    stored.lastDigestAt = Date().addingTimeInterval(-100_000)
    let outcome = digestDecision(current: [key(.formula, "ace", "8.2.0")], stored: stored, now: Date())
    if case .announce = outcome.action { } else { Issue.record("expected announce") }
    #expect(outcome.newState?.announced == [key(.formula, "ace", "8.2.0")])
}

@Test func decision_withinDigestWindowDefersNewPairs() {
    var stored = UpdateNotifyState()
    stored.lastDigestAt = Date().addingTimeInterval(-60)
    let outcome = digestDecision(current: [key(.formula, "ace", "8.1.0")], stored: stored, now: Date())
    #expect(outcome.action == .deferredNew)
    #expect(outcome.newState?.announced.isEmpty == true) // pending, not consumed
    #expect(outcome.newState?.lastDigestAt == stored.lastDigestAt)
}

@Test func decision_pendingPairsRideIntoNextEligibleDigest() {
    // A pair deferred at T+10m must be named by the digest at T+25h even though
    // it was already "known outdated" at the later check.
    let backlogDate = Date(timeIntervalSinceReferenceDate: 0)
    var stored = UpdateNotifyState()
    stored.lastDigestAt = backlogDate
    let deferred = digestDecision(current: [key(.formula, "ace", "8.1.0")], stored: stored,
                                  now: backlogDate.addingTimeInterval(600))
    #expect(deferred.action == .deferredNew)
    let later = digestDecision(current: [key(.formula, "ace", "8.1.0")], stored: deferred.newState!,
                               now: backlogDate.addingTimeInterval(25 * 3_600))
    if case .announce = later.action { } else { Issue.record("expected announce") }
    #expect(later.newState?.announced == [key(.formula, "ace", "8.1.0")])
}

@Test func decision_resolvedPairsLeaveAnnouncedSoTheyCanAnnounceAgain() {
    var stored = UpdateNotifyState()
    stored.announced = [key(.formula, "ace", "8.1.0")]
    stored.lastDigestAt = Date().addingTimeInterval(-100_000)
    let cleared = digestDecision(current: [], stored: stored, now: Date())
    #expect(cleared.action == .backlogResolved)
    #expect(cleared.newState?.announced.isEmpty == true)
    // Same pair outdated again later: it is "new" once more.
    let again = digestDecision(current: [key(.formula, "ace", "8.1.0")], stored: cleared.newState!, now: Date())
    if case .announce = again.action { } else { Issue.record("expected announce") }
}

@Test func store_roundTripAndMissingFileFreshStart() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("brewery-test-\(UUID().uuidString)")
    let store = UpdateNotifyStore(directory: dir)
    #expect(store.load()?.announced.isEmpty == true) // no file yet → fresh state
    var state = UpdateNotifyState()
    state.announced = [key(.cask, "wi", "4.4.6")]
    state.lastDigestAt = Date(timeIntervalSince1970: 1_000)
    try store.save(state)
    let loaded = store.load()
    #expect(loaded == state)
}

// MARK: - Gate 5 tails (2026-11-10): crash window + delivery-failure re-arm

@Test func decision_crashAfterSaveBeforePost_neverDuplicates() {
    // Measured blast radius of the coordinator's at-most-once order (save state
    // → post UN). A crash in that window leaves the pairs persisted as announced
    // with no banner delivered: the next check sees no new pairs → .nothing, so
    // a duplicate post is structurally impossible. The loss is exactly one
    // digest per crash — and bounded: the Outdated pane still lists the pair,
    // and its NEXT version bump re-announces (second half).
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    var crashed = UpdateNotifyState()
    crashed.announced = [key(.formula, "ace", "8.1.0")]
    crashed.lastDigestAt = t0 // as written by the announce save
    let next = digestDecision(current: [key(.formula, "ace", "8.1.0")], stored: crashed,
                              now: t0.addingTimeInterval(25 * 3_600))
    #expect(next.action == .nothing)
    let bump = digestDecision(current: [key(.formula, "ace", "8.2.0")], stored: next.newState!,
                              now: t0.addingTimeInterval(26 * 3_600))
    if case .announce = bump.action { } else { Issue.record("expected announce") }
}

@Test func reArm_deliveryFailureUnannouncesOnlyTheFailedPairs() {
    var stored = UpdateNotifyState()
    stored.announced = [key(.formula, "ace", "8.1.0"), key(.cask, "wi", "4.4.6")]
    stored.lastDigestAt = Date(timeIntervalSinceReferenceDate: 0)
    let rearmed = reArmAnnounced(stored, failed: [key(.formula, "ace", "8.1.0")])
    #expect(rearmed.announced == [key(.cask, "wi", "4.4.6")])
    #expect(rearmed.lastDigestAt == stored.lastDigestAt) // cooldown not consumed a second time
    // Keys the state never held: no-op.
    #expect(reArmAnnounced(stored, failed: [key(.formula, "ghost", "1.0")]) == stored)
}

@Test func decision_reArmedPairReAnnouncesOnNextCheckPastCooldown() {
    // reArmAnnounced alone doesn't re-post — the next eligible check does. With
    // lastDigestAt kept, the hourly check lands past the 1 h cooldown.
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    var stored = UpdateNotifyState()
    stored.announced = [key(.formula, "ace", "8.1.0")]
    stored.lastDigestAt = t0
    let rearmed = reArmAnnounced(stored, failed: [key(.formula, "ace", "8.1.0")])
    let outcome = digestDecision(current: [key(.formula, "ace", "8.1.0")], stored: rearmed,
                                 now: t0.addingTimeInterval(3_700))
    if case .announce(let text, let total) = outcome.action {
        #expect(total == 1)
        #expect(text.title == "1 package has a newer version")
    } else { Issue.record("expected announce") }
}

@Test func store_corruptFileSurfacesAsNilNotEmpty() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("brewery-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("update-notifications.json"))
    #expect(UpdateNotifyStore(directory: dir).load() == nil)
}
