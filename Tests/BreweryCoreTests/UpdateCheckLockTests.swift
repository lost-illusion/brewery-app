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
    guard let again = UpdateCheckLock.tryAcquire(directory: dir) else { // re-acquirable after release
        Issue.record("re-acquire after release should succeed"); return
    }
    again.release() // release it too — a held fd would leak into the rest of the test process
}
