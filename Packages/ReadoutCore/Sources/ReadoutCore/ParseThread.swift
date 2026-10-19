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
        start(qos: qos, kind: .large, work)
    }

    /// What the current thread is, as far as parsing goes.
    enum Kind: Int { case other = 0, large = 1, pool = 2 }
    private static let kindKey = "Readout.ParseThread.kind"
    static var current: Kind {
        (Thread.current.threadDictionary[kindKey] as? Int).flatMap(Kind.init(rawValue:)) ?? .other
    }

    static func start(qos: QualityOfService, kind: Kind, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread {
            Thread.current.threadDictionary[kindKey] = kind.rawValue
            work()
        }
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
    /// Returns once every iteration has. A caller on a large stack (a
    /// `ParseThread`) takes iterations too; one on the pool itself (a nested
    /// call) runs them all in place, so the pool never waits on itself;
    /// any other caller only waits.
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
final class ParsePool: @unchecked Sendable {
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
        let caller = ParseThread.current
        // On a pool thread (this pool's or another's): every worker may be
        // running an iteration that waits here, so nothing would take these.
        if caller == .pool {
            for k in 0..<iterations { body(k) }
            return
        }
        withoutActuallyEscaping(body) { body in
            // `body` does not outlive this call: the batch leaves the queue when its
            // last iteration is taken, this waits for that one to end, and
            // then lets go of it (workers may still hold the batch).
            let batch = Batch(iterations, body)
            lock.lock()
            batches.append(batch)
            while started < width {
                started += 1
                ParseThread.start(qos: .userInitiated, kind: .pool) { [self] in work() }
            }
            lock.broadcast()
            // A caller with a large stack takes iterations of its batch as the workers do.
            if caller == .large {
                while let k = take(batch) {
                    lock.unlock()
                    batch.body?(k)
                    lock.lock()
                    finish(batch)
                }
            }
            lock.unlock()
            batch.done.wait()
            lock.lock()
            batch.body = nil
            lock.unlock()
        }
    }

    /// The batch's next iteration (nil: all taken); under `lock`.
    private func take(_ batch: Batch) -> Int? {
        guard batch.next < batch.count else { return nil }
        let k = batch.next
        batch.next += 1
        if batch.next == batch.count, let i = batches.firstIndex(where: { $0 === batch }) { batches.remove(at: i) }
        return k
    }

    /// One iteration of the batch has ended; under `lock`.
    private func finish(_ batch: Batch) {
        batch.left -= 1
        if batch.left == 0 { batch.done.signal() }
    }

    private func work() {
        lock.lock()
        while true {
            while batches.isEmpty { lock.wait() }
            let batch = batches[0]
            guard let k = take(batch) else { continue }
            lock.unlock()
            batch.body?(k)
            lock.lock()
            finish(batch)
        }
    }
}
