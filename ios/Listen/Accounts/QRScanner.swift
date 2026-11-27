@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// QR metadata only. No frame buffers, images, photos, recordings or model input.
struct QRScanner: View {
    var title = "Scan Listen code"
    var manualEntry: (() -> Void)? = nil
    let scanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var controller = QRCaptureController()
    @State private var delegate: QRMetadataDelegate?
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                CameraPreview(session: controller.session).ignoresSafeArea()
                Text("Point the camera at a Listen QR code. Images stay on this device.")
                    .font(.subheadline).padding().background(.regularMaterial, in: .rect(cornerRadius: 16)).padding()
                if let failure { ContentUnavailableView("Camera unavailable", systemImage: "qrcode.viewfinder", description: Text(failure)).background(.background) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("scanner.cancel")
                }
                if let manualEntry {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Paste link") { manualEntry(); dismiss() }
                            .accessibilityIdentifier("scanner.manualEntry")
                    }
                }
            }
            .task {
                let allowed: Bool
                if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { allowed = true }
                else { allowed = await AVCaptureDevice.requestAccess(for: .video) }
                guard !Task.isCancelled else { return }
                guard allowed else { failure = "Allow camera access for Listen in Settings to scan codes."; return }
                let delegate = QRMetadataDelegate { value in controller.stop(); scanned(value); dismiss() }
                self.delegate = delegate
                controller.start(delegate: delegate) { failure = "The camera could not start. Try again on the device." }
            }
            .onDisappear { controller.stop(); delegate = nil }
        }
    }
}

@MainActor private final class QRMetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private var sent = false
    let scanned: (String) -> Void
    init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first, value.utf8.count <= 4096 else { return }
        Task { @MainActor in guard !sent else { return }; sent = true; scanned(value) }
    }
}

private final class QRCaptureController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Listen.setup-qr.camera")
    private var configured = false
    func start(delegate: QRMetadataDelegate, failed: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = self.session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
                guard let camera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: camera), self.session.canAddInput(input) else {
                    self.session.commitConfiguration(); Task { @MainActor in failed() }; return
                }
                self.session.addInput(input)
                do {
                    try camera.lockForConfiguration()
                    if let normal = camera.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue {
                        camera.videoZoomFactor = min(max(CGFloat(normal), camera.minAvailableVideoZoomFactor), camera.maxAvailableVideoZoomFactor)
                    }
                    if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                    if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                    if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                    camera.isSubjectAreaChangeMonitoringEnabled = true
                    camera.unlockForConfiguration()
                } catch { /* Keep the camera's automatic defaults when configuration is unavailable. */ }
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(output) else { self.session.commitConfiguration(); Task { @MainActor in failed() }; return }
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(delegate, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.session.commitConfiguration(); self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); view.preview.session = session; view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: Preview, context: Context) {}
}
