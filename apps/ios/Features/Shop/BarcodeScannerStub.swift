// Smidgen — Lane 4 Shop: barcode scan stub via AVFoundation
// Seam for a real AVCaptureSession scanner. Today: a sheet with a stubbed
// capture-preview placeholder + manual entry fallback. The AVFoundation
// import + session scaffold stay so the real metadata-output wiring lands
// here without touching call sites.
//
// Contract: the view reports a scanned string (EAN/UPC digits) via onScan.

import SwiftUI
import AVFoundation

/// Barcode scanner sheet (stub). Shows camera-permission state and a manual
/// entry field; `onScan` fires for manual entries today and for live
/// AVCaptureMetadataOutput codes once the session is wired.
public struct BarcodeScannerStub: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manualCode: String = ""
    @State private var permission: String = BarcodeScannerStub.cameraPermission()

    public init(onScan: @escaping (String) -> Void) {
        self.onScan = onScan
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(height: 220)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "barcode.viewfinder")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Scanner preview (stub)")
                                .font(.headline)
                            Text("Camera: \(permission)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                TextField("Enter barcode manually", text: $manualCode)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                Button("Use this code") {
                    let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !code.isEmpty else { return }
                    onScan(code)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding()
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: AVFoundation seam

    /// Current camera authorization state as a display string.
    static func cameraPermission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    /// Future live-scan wiring point: configures a capture session emitting
    /// EAN-13 / EAN-8 / UPC-E codes. Currently returns nil (stub).
    static func makeCaptureSession() -> AVCaptureSession? {
        // TODO(lane4-followup): attach AVCaptureDeviceInput(.video) +
        // AVCaptureMetadataOutput([.ean13, .ean8, .upce]) and forward
        // didOutput metadata strings to onScan.
        nil
    }
}
