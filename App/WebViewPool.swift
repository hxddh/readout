import AppKit
import WebKit
import ReadoutCore
import os

/// Keeps one reader page loaded and initialised in the background so a new window opens instantly.
@MainActor
final class WebViewPool: NSObject, WKNavigationDelegate {
    static let shared = WebViewPool()
    private var spare: ReaderWebView?
    /// The smoke test: whether the spare page runs in a process of its own.
    var spareForSmokeTest: ReaderWebView? { spare }

    func prewarm() {
        guard spare == nil else { return }
        let w = ReaderWebView(bundle: .main)
        w.navigationDelegate = self
        // Only a page still waiting as the spare warms up: one taken before
        // its ready (the first window at launch) shows a document and loads
        // what that document needs, not every preloaded grammar.
        w.whenReady { [weak self, weak w] in
            guard let self, let w, self.spare === w else { return }
            w.call("warm")
        }
        spare = w
        SmokeTest.noteLaunchPhase("spare_created")
    }

    /// The idle spare's web content process died (memory pressure, a crash):
    /// drop it, or the next window would open on a blank page. A new one is
    /// made shortly.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === spare else { return }
        spare = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.prewarm() }
    }

    /// When the next spare page is made: not while the page just taken is
    /// still loading (at launch, WebKit's first process start), but once a
    /// page has painted its first document, or a few seconds after the page
    /// taken is ready when none paints.
    private var plan = SparePagePlan()

    func take() -> ReaderWebView {
        let w = spare ?? ReaderWebView(bundle: .main)
        w.navigationDelegate = nil   // the window controller sets its own
        spare = nil
        let token = plan.taken()
        // The fallback counts from the page's ready, so the next spare never
        // competes with its load.
        w.whenReady { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + SparePagePlan.fallback) { [weak self] in
                guard let self, self.plan.fallbackFired(token) else { return }
                self.prewarm()
            }
        }
        return w
    }

    /// A window's page painted its first document: the spare page owed is made now.
    func pagePainted() {
        guard plan.painted() else { return }
        // After the frame that showed it, not inside the message reporting it.
        DispatchQueue.main.async { [weak self] in self?.prewarm() }
    }
}

/// Performance signposts (visible in Instruments): "open" spans a window
/// request to its first patch on screen; "applied" marks every patch.
enum ReaderPerf {
    static let signposter = OSSignposter(subsystem: "io.github.hxddh.readout", category: "perf")
}
