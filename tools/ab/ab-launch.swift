// DIAG (temporary): spawns a Readout binary with the caller's environment and
// records, from outside the app, when its first large window (a reader
// window) is on screen (CGWindowList), and when the document's text is on
// screen in it (the window's pixels, read every few ms: dark pixels in the
// page's area), then waits for it to quit.
// Usage: ab-launch BINARY OUT.json
import CoreGraphics
import Foundation

typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
let createImage = dlsym(handle, "CGWindowListCreateImage").map { unsafeBitCast($0, to: CreateImage.self) }

/// Dark pixels in the page's part of the window (right of the sidebar, below the toolbar).
func darkPixels(_ img: CGImage) -> Int {
    let w = img.width, h = img.height
    guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return -1 }
    let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
    guard bpp >= 3 else { return -1 }
    var n = 0
    var y = h * 18 / 100
    while y < h * 90 / 100 {
        var x = w * 40 / 100
        while x < w * 95 / 100 {
            let o = y * bpr + x * bpp
            if Int(p[o]) < 110 && Int(p[o + 1]) < 110 && Int(p[o + 2]) < 110 { n += 1 }
            x += 2
        }
        y += 2
    }
    return n
}

let args = CommandLine.arguments
let p = Process()
p.executableURL = URL(fileURLWithPath: args[1])
p.environment = ProcessInfo.processInfo.environment
let now = { Date().timeIntervalSince1970 }
let spawn = now()
try p.run()
let pid = p.processIdentifier
var visible: Double?
var anyWindow: Double?
var docVisible: Double?
var windowID: UInt32?
var captures = 0
var captureMs = 0.0
var trace: [[Double]] = []
while p.isRunning {
    if visible == nil, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let bounds = w[kCGWindowBounds as String] as? [String: Any]
            let h = (bounds?["Height"] as? Double) ?? 0
            if anyWindow == nil, layer == 0 { anyWindow = now() }
            if layer == 0, h >= 300 { visible = now(); windowID = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value; break }
        }
    }
    if let windowID, let createImage, docVisible == nil, now() - spawn < 40 {
        let t0 = now()
        // kCGWindowListOptionIncludingWindow = 8; kCGWindowImageBoundsIgnoreFraming = 1 | NominalResolution = 16
        if let img = createImage(.null, 8, windowID, 1 | 16)?.takeRetainedValue() {
            let n = darkPixels(img)
            captures += 1
            if trace.count < 400 { trace.append([((t0 - spawn) * 1000).rounded(), Double(n)]) }
            if n > 40 { docVisible = t0 }
        }
        captureMs += (now() - t0) * 1000
    }
    usleep(visible == nil ? 1000 : (docVisible == nil ? 4000 : 50000))
    if now() - spawn > 120 { p.terminate(); break }
}
p.waitUntilExit()
var out: [String: Any] = ["spawn": spawn, "exit": Int(p.terminationStatus), "captures": captures, "capture_ms": captureMs.rounded(), "trace": trace]
if let visible { out["window_visible"] = visible }
if let anyWindow { out["any_window"] = anyWindow }
if let docVisible { out["doc_visible"] = docVisible }
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: args[2]))
