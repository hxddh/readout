import Foundation

/// Reads and parses one Markdown file off the main thread, the way agents
/// write it: rapid successive writes share one in-flight parse, a change that
/// lands mid-parse triggers one fresh re-read, identical bytes are ignored,
/// and a write that looks half-finished is retried briefly before it is shown.
///
/// Main-actor confined; completions run on the main actor.
@MainActor
public final class DocumentLoader {
    public struct ReadResult: Sendable {
        public let doc: ParsedDocument
        public let hash: UInt64
        public let size: Int
        public let decoded: FileContent.Decoded
    }

    public enum Change: Sendable {
        /// Same bytes as the last accepted read.
        case unchanged
        /// New content, accepted.
        case content(ReadResult)
    }

    public let url: URL
    private let resolver: @MainActor () -> FileResolver
    private let cache = MarkdownParser.RenderCache()
    private let parseQueue = DispatchQueue(label: "readout.parse", qos: .userInitiated)
    /// Delay before re-reading a write that looks half-finished.
    private let retryDelay: TimeInterval

    // Last accepted content.
    private var lastHash: UInt64?
    private var lastSize: Int?
    private var lastChangeAt: Date?
    private var halfWriteRetries = 0

    // Parse coalescing: rapid successive writes share one in-flight parse;
    // completions carry a generation and stale ones are dropped.
    private var readGeneration = 0
    private var readInFlight = false
    private var readAgain = false
    private var pendingCompletions: [(ReadResult?) -> Void] = []

    /// `resolver` is evaluated per read so workspace settings changes apply.
    public init(url: URL, retryDelay: TimeInterval = 0.12, resolver: @escaping @MainActor () -> FileResolver) {
        self.url = url
        self.retryDelay = retryDelay
        self.resolver = resolver
    }

    /// First read: accepted as-is (nil when the file cannot be read).
    public func loadInitial(_ completion: @escaping (ReadResult?) -> Void) {
        read { [weak self] result in
            if let self, let result {
                self.lastHash = result.hash
                self.lastSize = result.size
            }
            completion(result)
        }
    }

    /// Re-read after a change on disk. Unreadable files produce no callback;
    /// half-written files are retried and reported once complete.
    public func readChange(_ completion: @escaping (Change) -> Void) {
        read { [weak self] result in
            guard let self, let result else { return }
            if result.hash == self.lastHash { completion(.unchanged); return }
            let verdict = FileContent.verdict(newSize: result.size, previousSize: self.lastSize,
                                              secondsSincePreviousWrite: self.lastChangeAt.map { Date().timeIntervalSince($0) },
                                              truncatedTail: result.decoded.truncatedTail, retriesSoFar: self.halfWriteRetries)
            if verdict == .waitForMore {
                self.halfWriteRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay) { [weak self] in
                    MainActor.assumeIsolated { self?.readChange(completion) }
                }
                return
            }
            self.halfWriteRetries = 0
            self.lastHash = result.hash
            self.lastSize = result.size
            self.lastChangeAt = Date()
            completion(.content(result))
        }
    }

    private func read(_ completion: @escaping (ReadResult?) -> Void) {
        // Coalesce: if a parse is already running, queue the completion for
        // the follow-up read instead of queueing another full parse behind it.
        if readInFlight {
            readAgain = true
            pendingCompletions.append(completion)
            return
        }
        readInFlight = true
        readGeneration += 1
        let generation = readGeneration
        let url = self.url
        let resolver = self.resolver()
        let cache = self.cache
        parseQueue.async {
            var result: ReadResult?
            if let data = try? Data(contentsOf: url) {
                let decoded = FileContent.decode(data)
                cache.beginGeneration()
                let doc = MarkdownParser.parse(decoded.text, resolver: resolver, cache: cache)
                result = ReadResult(doc: doc, hash: XXHash64.hash(data), size: data.count, decoded: decoded)
            }
            let finished = result
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finishRead(generation: generation, result: finished) }
            }
        }
        // The initiating completion waits for this read like any other.
        pendingCompletions.append(completion)
    }

    private func finishRead(generation: Int, result: ReadResult?) {
        guard generation == readGeneration else { return }  // superseded by a newer read
        readInFlight = false
        if readAgain {
            // The file changed while we were parsing: re-read from disk, and
            // queued completions wait for that fresher result.
            readAgain = false
            read { [weak self] result in self?.drainCompletions(with: result) }
            return
        }
        drainCompletions(with: result)
    }

    private func drainCompletions(with result: ReadResult?) {
        let completions = pendingCompletions
        pendingCompletions = []
        for c in completions { c(result) }
    }
}
