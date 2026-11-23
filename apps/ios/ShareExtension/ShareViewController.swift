// Smidgen — Lane 3 Capture
// apps/ios/ShareExtension/ShareViewController.swift
//
// Share Sheet: imports URL from Safari / IG / TikTok → host app via App Group.
// Extension target links ShareStore; host app drains on foreground.
//
// Xcode setup (manual, one time):
//  1. Add "Share Extension" target named SmidgenShare, link this file + ShareStore.swift.
//  2. Enable App Groups capability on BOTH targets: group.com.smidgen.share.
//  3. NSExtensionActivationRule: NSExtensionActivationSupportsWebURLWithMaxCount = 1
//     (+ NSExtensionActivationSupportsText for caption shares).

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

public final class ShareViewController: UIViewController {
    private let status = UILabel()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = "Clipping to Smidgen…"
        status.textAlignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        extractAndStore()
    }

    private func extractAndStore() {
        guard let item = extensionContext?.inputItems.compactMap({ $0 as? NSExtensionItem }).first,
              let providers = item.attachments, !providers.isEmpty
        else { return done(message: "Nothing to share") }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] value, _ in
                    let s: String? = (value as? URL)?.absoluteString ?? (value as? String)
                    self?.store(s)
                }
                return
            }
        }
        // Fallback: plain text may contain a URL.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] value, _ in
                if let text = value as? String {
                    let url = ClipboardDetectorShim.firstURL(in: text) ?? text
                    self?.store(url)
                } else { self?.done(message: "Nothing to share") }
            }
            return
        }
        done(message: "Nothing to share")
    }

    private func store(_ s: String?) {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return done(message: "Nothing to share")
        }
        ShareStore.enqueue(url: s)
        done(message: "Saved to Smidgen ✓")
    }

    private func done(message: String) {
        DispatchQueue.main.async { self.status.text = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}

/// Minimal URL finder (mirrors ClipboardDetector; ShareExtension target
/// cannot import Features/Ingest, so this shim is intentional).
private enum ClipboardDetectorShim {
    static func firstURL(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s]+"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range),
              let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}
#endif
