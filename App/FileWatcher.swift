import Foundation
import CoreServices

/// Thin wrapper over an FSEvents stream with file-level events.
final class FSEventsStream {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
        var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
        var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
        var isFile: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 }
        var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
    }

    private var stream: FSEventStreamRef?
    private let handler: ([Event]) -> Void
    private let queue: DispatchQueue

    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue, sinceNow: Bool = true, handler: @escaping ([Event]) -> Void) {
        self.handler = handler
        self.queue = queue
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FSEventsStream>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<min(count, arr.count) { events.append(Event(path: arr[i], flags: flags[i])) }
            me.handler(events)
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Watches one file for changes, surviving atomic replace (write temp + rename) and delete/recreate.
/// Delivers debounced change notifications on the main queue.
final class FileWatcher {
    enum Change { case modified, deleted }

    let url: URL
    private let canonicalExactPath: String
    private let canonicalPath: String
    private var stream: FSEventsStream?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "readout.filewatcher", qos: .userInitiated)
    private let onChange: (Change) -> Void

    // Debounce: trailing 80 ms, but never hold an update for more than 400 ms during continuous writes.
    private var pending: DispatchWorkItem?
    private var firstPendingAt: Date?
    private let trailing: TimeInterval = 0.08
    private let maxWait: TimeInterval = 0.4

    private var lastPollSignature: (Date, Int)?

    init(url: URL, onChange: @escaping (Change) -> Void) {
        self.url = url
        self.canonicalExactPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        self.canonicalPath = canonicalExactPath.lowercased()
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    func stop() {
        stream?.stop(); stream = nil
        pollTimer?.cancel(); pollTimer = nil
        pending?.cancel()
    }

    private func start() {
        let dir = url.resolvingSymlinksInPath().deletingLastPathComponent().path
        let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
        if isLocal {
            stream = FSEventsStream(paths: [dir], latency: 0.03, queue: queue) { [weak self] events in
                self?.handle(events)
            }
        }
        if stream == nil { startPolling() }
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let values = try? self.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let sig = (values?.contentModificationDate ?? .distantPast, values?.fileSize ?? -1)
            if let last = self.lastPollSignature, last.0 != sig.0 || last.1 != sig.1 { self.schedule() }
            self.lastPollSignature = sig
        }
        t.resume()
        pollTimer = t
    }

    private func handle(_ events: [FSEventsStream.Event]) {
        for e in events {
            // Exact match first: on case-sensitive volumes "Readme.md" and
            // "README.md" are different files and must not alias each other.
            if e.path == canonicalExactPath || e.path.lowercased() == canonicalPath {
                schedule()
                return
            }
        }
        // A watched-root change (directory moved/removed) also warrants a re-check.
        if events.contains(where: { $0.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }) { schedule() }
    }

    private func schedule() {
        let now = Date()
        if firstPendingAt == nil { firstPendingAt = now }
        pending?.cancel()
        let waited = now.timeIntervalSince(firstPendingAt!)
        let delay = max(0, min(trailing, maxWait - waited))
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firstPendingAt = nil
            let exists = FileManager.default.fileExists(atPath: self.url.path)
            DispatchQueue.main.async { self.onChange(exists ? .modified : .deleted) }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
