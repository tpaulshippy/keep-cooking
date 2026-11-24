// Keep Cooking — Lane 3 Capture
// apps/ios/Features/Ingest/ClipboardBanner.swift
//
// Clipboard auto-detect on foreground with dismissable prompt.
// If the clipboard holds a URL (or recipe-ish text), show a banner:
// "Clip this link? [Clip] [Dismiss]". Never auto-import without consent.

import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Pure detector — unit-testable without UIKit.
public enum ClipboardDetector {
    /// Returns the URL string if text contains an http(s) URL, else nil.
    public static func firstURL(in text: String) -> String? {
        guard let detector = try? NSRegularExpression(pattern: #"https?://[^\s]+"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = detector.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text)
        else { return nil }
        return String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,);\"'"))
    }

    /// Heuristic: looks like a recipe share (URL or ≥2 ingredient-ish lines).
    public static func looksLikeRecipe(_ text: String) -> Bool {
        if firstURL(in: text) != nil { return true }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return false }
        return lines.filter { IngredientParser.parse($0).quantity != nil }.count >= 1
    }
}

public struct ClipboardBanner: View {
    var detectedURL: String?
    var onClip: (String) -> Void
    var onDismiss: () -> Void

    public init(detectedURL: String?, onClip: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.detectedURL = detectedURL; self.onClip = onClip; self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack {
            Image(systemName: "link.badge.plus").foregroundStyle(.blue)
            VStack(alignment: .leading) {
                Text("Clip this link?").font(.subheadline.bold())
                if let u = detectedURL {
                    Text(u).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button("Clip") { if let u = detectedURL { onClip(u) } }
                .buttonStyle(.borderedProminent)
            Button("Dismiss") { onDismiss() }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

/// Host wrapper: checks UIPasteboard on foreground, shows ClipboardBanner.
/// Drop into any Ingest entry view.
public struct ClipboardMonitor: View {
    @State private var pendingURL: String?
    @State private var dismissed: String?
    var onClipURL: (String) -> Void

    public init(onClipURL: @escaping (String) -> Void) { self.onClipURL = onClipURL }

    public var body: some View {
        Group {
            if let url = pendingURL, url != dismissed {
                ClipboardBanner(detectedURL: url, onClip: { onClipURL($0); pendingURL = nil }, onDismiss: { dismissed = url; pendingURL = nil })
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            checkClipboard()
        }
        .task { checkClipboard() }
        #endif
    }

    #if os(iOS)
    private func checkClipboard() {
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        if let url = ClipboardDetector.firstURL(in: text) {
            if url != dismissed { pendingURL = url }
        }
    }
    #endif
}
