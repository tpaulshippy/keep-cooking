// Keep Cooking — Lane 3 Capture
// apps/ios/ShareExtension/ShareStore.swift
//
// App Group bridge between ShareExtension and host app.
// Group id: group.com.smidgen.share. Extension writes pending URLs;
// host app (ClipboardMonitor / ClipView) reads + clears them.

import Foundation

public enum ShareStore {
    public static let suiteName = "group.com.smidgen.share"
    public static let pendingKey = "smidgen.pendingShareURLs"

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// Append a shared URL (extension side). No-ops when App Group missing.
    public static func enqueue(url: String) {
        guard let d = defaults else { return }
        var arr = d.stringArray(forKey: pendingKey) ?? []
        if !arr.contains(url) { arr.append(url) }
        d.set(arr, forKey: pendingKey)
    }

    /// Read + clear pending URLs (host-app side).
    public static func drain() -> [String] {
        guard let d = defaults else { return [] }
        let arr = d.stringArray(forKey: pendingKey) ?? []
        d.removeObject(forKey: pendingKey)
        return arr
    }

    public static func pending() -> [String] {
        defaults?.stringArray(forKey: pendingKey) ?? []
    }
}
