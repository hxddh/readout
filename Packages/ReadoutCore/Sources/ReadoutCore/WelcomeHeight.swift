import Foundation

/// Adaptive Welcome-window height: the base layout plus one row per recent
/// file (capped at 5), so a single recent leaves no big blank area. Pure so
/// it is unit-tested on Linux; WelcomeView in App/AppDelegate.swift calls it.
public enum WelcomeHeight {
    public static func height(forRecentCount count: Int) -> Double {
        400 + Double(min(max(count, 0), 5)) * 24 + (count > 0 ? 30 : 0)
    }
}
