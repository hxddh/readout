import Foundation
import WebKit

/// The smoke test's hooks, as the app that ships has them: none. The harness
/// itself (Smoke/SmokeTest.swift, tools/smoke-run.py) is built only into the
/// Smoke configuration, which leaves this file out (project.yml).
@MainActor
enum SmokeTest {
    static var launchFile: URL? { nil }
    static var isBootPass: Bool { false }
    static func didOpen() {}
    static func run(controller: ReaderWindowController, webView: WKWebView) {}
    static func noteLaunchPhase(_ name: String) {}
    static func noteAutoOpened(_ paths: [String]) {}
    static func noteBackgroundRequest(_ path: String) {}
    static func noteApplied() {}
    static func notePainted() {}
    static func noteFirstApply(_ url: URL, seconds: Double) {}
    static func noteFirstPaint(_ url: URL, seconds: Double) {}
    static func noteLanded(index: Int, total: Int, kind: String) {}
    static func noteFound() {}
    static func noteCompared(_ notice: String) {}
    /// Print as usual (false): the smoke build records what would print instead.
    static func capturePrint(_ webView: WKWebView) -> Bool { false }
}
