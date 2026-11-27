import Foundation
import Darwin

/// One audio owner across the GUI and terminal processes. The OS releases the lock on exit;
/// the file stays in place so another opener never locks a different inode by accident.
final class RecordingLease {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private let descriptor: Int32

    static var file: URL { URL.applicationSupportDirectory.appending(path: "Listen/recording.lock") }

    init(file: URL = RecordingLease.file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure(message: "The shared recording lock could not be opened.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw Failure(message: "Another Listen instance is using audio. Stop its conversation or switch off its idle microphone first.")
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
