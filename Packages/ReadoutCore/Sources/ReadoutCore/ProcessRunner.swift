import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs a program, blocking the calling thread (never the main thread) for
/// at most `timeout`: its standard output when it exits with 0 in time and
/// writes no more than `limit` bytes; else nil (it is terminated).
public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                           timeout: TimeInterval, limit: Int, environment: [String: String] = [:]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        // Read as it is written (a full pipe would stall it), up to the limit,
        // never blocked for long: it looks every 20 ms whether to stop. Once
        // the program has exited, what it wrote is in the pipe; a child it
        // left running may hold the pipe open, so reading ends when the pipe
        // is empty, not at its end.
        let reader = Reader()
        let readDone = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        nonisolated(unsafe) let running = process
        DispatchQueue.global(qos: .userInitiated).async {
            reader.read(handle.fileDescriptor, limit: limit) { running.terminate() }
            try? handle.close()
            readDone.signal()
        }
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            reader.finish(.stop)
            return nil
        }
        reader.finish(.drain)
        // Draining takes a moment, unless a child goes on writing: no longer than the deadline
        // (a program exiting right at it gets the moment).
        guard readDone.wait(timeout: max(deadline, .now() + 0.05)) == .success else {
            reader.finish(.stop)
            return nil
        }
        guard !reader.over, process.terminationStatus == 0, process.terminationReason == .exit else { return nil }
        return reader.data
    }

    /// Readers still reading (for tests: none is left behind).
    static var liveReaders: Int { Reader.lock.withLock { Reader.live } }

    private static func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
        #else
        return Glibc.read(fd, buffer, count)
        #endif
    }

    private final class Reader: @unchecked Sendable {
        enum Finish { case drain, stop }
        static let lock = NSLock()
        nonisolated(unsafe) static var live = 0
        private let lock = NSLock()
        private var finishing: Finish? = nil
        private(set) var data = Data()
        private(set) var over = false

        func finish(_ how: Finish) { lock.withLock { if finishing != .stop { finishing = how } } }

        func read(_ fd: Int32, limit: Int, overflow: () -> Void) {
            Self.lock.withLock { Self.live += 1 }
            defer { Self.lock.withLock { Self.live -= 1 } }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let how = lock.withLock { finishing }
                if how == .stop { return }
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&p, 1, 20)
                if ready < 0 { if errno == EINTR { continue }; return }
                if ready == 0 { if how == .drain { return }; continue }
                let n = buffer.withUnsafeMutableBytes { systemRead(fd, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                if n == 0 { return }   // every writer closed it
                let isOver = lock.withLock {
                    data.append(buffer, count: n)
                    if data.count > limit { over = true }
                    return over
                }
                if isOver { overflow(); return }
            }
        }
    }
}
