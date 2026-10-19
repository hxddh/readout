import Foundation

/// Threads with a large stack for parsing. swift-markdown converts its tree
/// recursively, once per level of nesting, and a GCD thread's stack is
/// 512 KB on macOS: documents are parsed here, with `NestingCap` as the
/// guard on threads this does not cover (`IncrementalParser`'s concurrent
/// fragments).
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

    /// `work`'s result, run on such a thread.
    public static func run<T: Sendable>(qos: QualityOfService = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            start(qos: qos) { c.resume(returning: work()) }
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable { var value: T? }
