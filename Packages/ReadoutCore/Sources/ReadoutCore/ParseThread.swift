import Foundation

/// Threads with a large stack for parsing. swift-markdown converts its tree
/// recursively, once per level of nesting, and a GCD thread's stack is
/// 512 KB on macOS: documents are parsed here, and `IncrementalParser`'s
/// concurrent fragments on such threads too (`concurrentPerform`), with
/// `NestingCap` as the guard against nesting no stack holds.
public enum ParseThread {
    /// 16 MB.
    public static let stackSize = 16 << 20

    /// Runs `work` on a new thread with a `stackSize` stack.
    public static func start(qos: QualityOfService = .userInitiated, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.stackSize = stackSize
        thread.qualityOfService = qos
        thread.start()
    }

    /// `work`'s result, run on such a thread; the calling thread waits.
    public static func sync<T: Sendable>(qos: QualityOfService = .userInitiated, _ work: @escaping @Sendable () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        start(qos: qos) { box.value = work(); done.signal() }
        done.wait()
        return box.value!
    }

    /// `body` for each of `0..<iterations`, concurrently, on a pool of
    /// threads with a `stackSize` stack (as many as the processors, at most
    /// 16): `DispatchQueue.concurrentPerform` without GCD's 512 KB stacks.
    /// Returns once every iteration has; the calling thread only waits.
    public static func concurrentPerform(iterations: Int, _ body: @Sendable (Int) -> Void) {
        guard iterations > 0 else { return }
        ParsePool.shared.perform(iterations, body)
    }

    /// `work`'s result, run on such a thread.
    public static func run<T: Sendable>(qos: QualityOfService = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            start(qos: qos) { c.resume(returning: work()) }
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable { var value: T? }

/// The threads `ParseThread.concurrentPerform` runs on, started when first
/// needed and kept: each takes the next iteration of the oldest batch.
private final class ParsePool: @unchecked Sendable {
    static let shared = ParsePool(width: min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 16))

    private final class Batch: @unchecked Sendable {
        var body: (@Sendable (Int) -> Void)?
        let count: Int
        var next = 0
        var left: Int
        let done = DispatchSemaphore(value: 0)
        init(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) { self.count = count; self.left = count; self.body = body }
    }

    private let width: Int
    private let lock = NSCondition()
    private var batches: [Batch] = []
    private var started = 0

    init(width: Int) { self.width = width }

    func perform(_ iterations: Int, _ body: @Sendable (Int) -> Void) {
        withoutActuallyEscaping(body) { body in
            // `body` does not outlive this call: the batch leaves the queue when its
            // last iteration is taken, this waits for that one to end, and
            // then lets go of it (workers may still hold the batch).
            let batch = Batch(iterations, body)
            lock.lock()
            batches.append(batch)
            while started < width {
                started += 1
                ParseThread.start { [self] in work() }
            }
            lock.broadcast()
            lock.unlock()
            batch.done.wait()
            lock.lock()
            batch.body = nil
            lock.unlock()
        }
    }

    private func work() {
        lock.lock()
        while true {
            while batches.isEmpty { lock.wait() }
            let batch = batches[0]
            let k = batch.next
            batch.next += 1
            if batch.next == batch.count { batches.removeFirst() }
            lock.unlock()
            batch.body?(k)
            lock.lock()
            batch.left -= 1
            if batch.left == 0 { batch.done.signal() }
        }
    }
}
