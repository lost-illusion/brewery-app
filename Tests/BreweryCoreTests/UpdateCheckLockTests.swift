import Foundation
import Testing
@testable import BreweryCore

// Second flock on the same file must fail while the first holds it.
@Test func lock_secondAcquireFailsUntilRelease() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("brewery-lock-\(UUID().uuidString)")
    guard let first = UpdateCheckLock.tryAcquire(directory: dir) else {
        Issue.record("first acquire should succeed"); return
    }
    #expect(UpdateCheckLock.tryAcquire(directory: dir) == nil) // busy — the other process checks instead
    first.release()
    #expect(UpdateCheckLock.tryAcquire(directory: dir) != nil) // re-acquirable after release
}
