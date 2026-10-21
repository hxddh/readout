// DIAG (temporary): spawns a Readout binary with the caller's environment and
// records, from outside the app, when its first large window (a reader
// window) is on screen (CGWindowList), then waits for it to quit.
// Usage: ab-launch BINARY OUT.json
import CoreGraphics
import Foundation

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
while p.isRunning {
    if visible == nil, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
            let layer = w[kCGWindowLayer as String] as? Int ?? -1
            let bounds = w[kCGWindowBounds as String] as? [String: Any]
            let h = (bounds?["Height"] as? Double) ?? 0
            if anyWindow == nil, layer == 0 { anyWindow = now() }
            if layer == 0, h >= 300 { visible = now(); break }
        }
    }
    usleep(visible == nil ? 1000 : 50000)
    if now() - spawn > 120 { p.terminate(); break }
}
p.waitUntilExit()
var out: [String: Any] = ["spawn": spawn, "exit": Int(p.terminationStatus)]
if let visible { out["window_visible"] = visible }
if let anyWindow { out["any_window"] = anyWindow }
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try data.write(to: URL(fileURLWithPath: args[2]))
