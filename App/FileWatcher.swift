import Foundation
import CoreServices
import ReadoutCore

/// Thin wrapper over an FSEvents stream with file-level events.
///
/// The stream retains a box holding the handler (context retain/release), so a
/// callback already running never sees freed memory, and `stop()` invalidates
/// the stream on its own queue: once it returns, no callback runs any more.
/// Confined to its queue (callbacks, stop): safe to hand to it.
final class FSEventsStream: @unchecked Sendable {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
        var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
        var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
        var isFile: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 }
        var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
        var isRootChanged: Bool { flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }
    }

    /// What the stream's context retains.
    private final class Box {
        let handler: ([Event]) -> Void
        init(_ handler: @escaping ([Event]) -> Void) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue

    /// `excluding`: folders whose events FSEvents filters out before the app
    /// is woken (at most WatchExclusions.limit).
    init?(paths: [String], latency: TimeInterval, queue: DispatchQueue, sinceNow: Bool = true, excluding: [String] = [],
          handler: @escaping ([Event]) -> Void) {
        self.queue = queue
        queue.markForRunSync()
        let box = Box(handler)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<AnyObject>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<AnyObject>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<min(count, arr.count) { events.append(Event(path: arr[i], flags: flags[i])) }
            withExtendedLifetime(box) { box.handler(events) }
        }
        // FSEventStreamCreate retains the box through the context's retain callback.
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        if !excluding.isEmpty { _ = FSEventStreamSetExclusionPaths(s, Array(excluding.prefix(WatchExclusions.limit)) as CFArray) }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    /// Stops and invalidates the stream on its queue, so it never races a callback.
    func stop() { queue.runSync { stopOnQueue() } }

    /// Stops it once the queue is free, without waiting: for a caller on the
    /// main thread while long work (a folder scan) may hold the queue. Events
    /// delivered before then still reach the handler, which must drop them.
    func stopAsync() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)   // releases the box
    }

    deinit { stop() }
}

/// Watches one file for changes, surviving atomic replace (write temp + rename),
/// delete/recreate and a symlink pointed at another file (`ln -sf`).
/// Delivers debounced change notifications on the main queue.
/// Its state is touched on its queue only, its callbacks sent to the main thread: safe to hand to either.
final class FileWatcher: @unchecked Sendable {
    enum Change { case modified, deleted }

    let url: URL
    /// The real paths events are compared with (FSEvents reports /private/tmp/…).
    /// Touched only on `queue`.
    private var target: WatchTarget
    private var watchedDirectories: [String] = []
    private var stream: FSEventsStream?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "readout.filewatcher", qos: .userInitiated)
    private let onChange: (Change) -> Void
    /// The opened path (a symlink) now resolves to another file (its real path). On the main queue.
    private let onRetarget: (String) -> Void
    /// Set on `queue`, read there and on the main queue: under a lock.
    private let stoppedLock = NSLock()
    private var _stopped = false
    private var stopped: Bool {
        get { stoppedLock.withLock { _stopped } }
        set { stoppedLock.withLock { _stopped = newValue } }
    }

    // Debounce: the first event after a quiet spell is reported at once; a
    // burst after it waits for 80 ms without events, but never more than
    // 400 ms. DocumentLoader retries a write that looks half-finished, and
    // drops a re-read of identical bytes.
    private var pending: DispatchWorkItem?
    private var debounce = WriteDebounce(trailing: 0.08, maxWait: 0.4)

    private var lastPollSignature: [Int]?

    init(url: URL, onChange: @escaping (Change) -> Void, onRetarget: @escaping (String) -> Void = { _ in }) {
        self.url = url
        self.target = WatchTarget(path: url.path)
        self.onChange = onChange
        self.onRetarget = onRetarget
        queue.markForRunSync()
        let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
        queue.sync { self.start(isLocal: isLocal) }
    }

    deinit { stop() }

    func stop() { queue.runSync { stopOnQueue() } }

    private func stopOnQueue() {
        stopped = true
        stream?.stop(); stream = nil
        pollTimer?.cancel(); pollTimer = nil
        pending?.cancel(); pending = nil
    }

    private func start(isLocal: Bool) {
        if isLocal { startStream() }
        if stream == nil { startPolling() }
    }

    /// Watches the folder of the file shown and, for a symlink, the link's own
    /// folder, without what a build, a package install or a commit writes into
    /// them (`.git`, `node_modules`, `.build`, `DerivedData`, …): those events
    /// never wake the app.
    private func startStream() {
        stream?.stop()
        watchedDirectories = target.directories
        let excluded = WatchExclusions.paths(for: watchedDirectories, keep: [target.target, target.linkPath])
        stream = FSEventsStream(paths: watchedDirectories, latency: 0.03, queue: queue, excluding: excluded) { [weak self] events in
            self?.handle(events)
        }
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            // stat(2), not URL resource values: those are cached on the URL and
            // never refresh off the run loop.
            var st = stat()
            let sig: [Int] = stat(self.url.path, &st) == 0
                ? [Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec), Int(st.st_size), Int(st.st_ino)]
                : [-1]
            self.retarget()
            if let last = self.lastPollSignature, last != sig { self.schedule() }
            self.lastPollSignature = sig
        }
        t.resume()
        pollTimer = t
    }

    private func handle(_ events: [FSEventsStream.Event]) {
        guard !stopped else { return }
        var changed = events.contains { target.isTarget($0.path) }
        if events.contains(where: { target.isLink($0.path) }) {
            // The link itself was written: it may point to another file now.
            retarget()
            changed = true
        }
        // A watched-root change (directory moved/removed) also warrants a re-check.
        if events.contains(where: \.isRootChanged) {
            retarget()
            changed = true
        }
        if changed { schedule() }
    }

    /// Resolves the opened path again; when it points to another file, says so
    /// (the window is keyed by the file it shows) and, when that file is in
    /// another folder, watches that one (after this callback returns: a stream
    /// is not invalidated from inside its own callback).
    private func retarget() {
        guard target.reresolve() else { return }
        let newTarget = target.target
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onRetarget(newTarget)
        }
        guard target.directories != watchedDirectories else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped, self.stream != nil else { return }
            self.startStream()
        }
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func schedule() {
        switch debounce.event(at: Self.now()) {
        case .fire:
            report()
        case .schedule(let delay):
            pending?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.pending = nil
                self.debounce.fired(at: Self.now())
                self.report()
            }
            pending = item
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    /// On `queue`.
    private func report() {
        let exists = FileManager.default.fileExists(atPath: url.path)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.onChange(exists ? .modified : .deleted)
        }
    }
}

extension DispatchQueue {
    private static let identityKey = DispatchSpecificKey<ObjectIdentifier>()

    /// Marks the queue so `runSync` can tell when it already runs on it.
    func markForRunSync() { setSpecific(key: Self.identityKey, value: ObjectIdentifier(self)) }

    /// Runs `work` on this queue and waits for it; inline when already on it.
    func runSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.identityKey) == ObjectIdentifier(self) { work() } else { sync(execute: work) }
    }
}
