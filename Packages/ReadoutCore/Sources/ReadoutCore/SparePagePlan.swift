import Foundation

/// When the reader page pool makes its next spare page, after one is taken.
///
/// Made right away, the next spare page competed with the page just taken
/// while that one was still loading its first document (at launch: WebKit's
/// first process start). It is made once a page has painted its first
/// document, or `fallback` seconds after the page taken is ready when none
/// paints (the app starts that timer at the page's ready, never before).
public struct SparePagePlan: Equatable, Sendable {
    public static let fallback: TimeInterval = 3

    /// A spare page is owed: one was taken and the next is not made yet.
    public private(set) var waiting = false
    private var generation = 0

    public init() {}

    /// A spare page was taken. Returns the token its fallback timer (started
    /// once the page taken is ready) presents to `fallbackFired`.
    public mutating func taken() -> Int {
        waiting = true
        generation += 1
        return generation
    }

    /// A page painted its first document: true when the next spare page is to be made now.
    public mutating func painted() -> Bool {
        defer { waiting = false }
        return waiting
    }

    /// The fallback timer of `token` fired: true when the spare page is still
    /// owed and no later take started a timer of its own.
    public mutating func fallbackFired(_ token: Int) -> Bool {
        guard waiting, token == generation else { return false }
        waiting = false
        return true
    }
}
