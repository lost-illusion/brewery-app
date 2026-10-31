import Darwin
import Foundation

/// Cross-process advisory lock serializing the GUI digest check and the launchd
/// headless check (design §Scheduling & Homebrew safety): a persistent lock
/// file with flock, never unlinked, so the two processes keep the same inode
/// and never write notification state at the same time. Failing to acquire is a
/// normal outcome — the other process is mid-check and this cycle is skipped.
public struct UpdateCheckLock: Sendable {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    /// Non-blocking. nil = someone else holds it (or the file system said no).
    public static func tryAcquire(directory: URL) -> UpdateCheckLock? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("notify.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return UpdateCheckLock(fd: fd)
    }

    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
