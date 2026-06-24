//
//  ScanViewfinder.swift
//  BrownSign
//
//  The redesign's camera-first Scan tab leads with a LIVE inline
//  viewfinder. This is a deliberately lighter capture surface than the
//  full-screen `CameraView`: preview + shutter + flash + gallery + an
//  expand-to-full-camera button, but no pinch-zoom / tap-to-focus /
//  high-res capture (those stay in `CameraView`, which the launcher /
//  Siri / Control-Center path and the expand button still open, and
//  which is the right place for zooming in on a distant sign).
//
//  The two surfaces MUST NOT run a capture session at the same time, so
//  the parent passes `active = false` whenever the full-screen camera (or
//  a covering modal) is up, and the view stops its session on disappear.
//

import SwiftUI
import AVFoundation
import UIKit

// MARK: - Controller

/// Owns the inline capture session. Mirrors `CameraView`'s threading
/// under the project's main-actor-by-default isolation: the session is
/// CONFIGURED on the main actor (begin/add/commit are quick), and only the
/// blocking `start/stopRunning` calls are dispatched to a private serial
/// queue. The photo-output delegate is genuinely called off-main, so it's
/// `nonisolated` and hops back to the main actor to hand the bytes up.
/// `@Observable` (not ObservableObject) to match LocationManager and avoid
/// a Combine dependency; the session plumbing is `@ObservationIgnored`.
@Observable
final class ScanCameraController: NSObject, AVCapturePhotoCaptureDelegate {
    enum Status: Equatable { case idle, configuring, authorized, denied }

    private(set) var status: Status = .idle

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "com.seanmandable.brownsign.inline-session")
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var onCapture: ((Data) -> Void)?

    /// Wired once by the hosting view so a shutter tap can route the
    /// captured bytes into the same `ingestPhoto` pipeline a full-screen
    /// capture uses.
    func setOnCapture(_ handler: @escaping (Data) -> Void) { onCapture = handler }

    /// Begin (or resume) the live preview, requesting camera access the
    /// first time. Idempotent — safe to call from both `onAppear` and the
    /// `active` change handler.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureIfNeededAndRun()
        case .notDetermined:
            status = .configuring
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.configureIfNeededAndRun() } else { self.status = .denied }
                }
            }
        default: // .denied, .restricted, and any future case
            status = .denied
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture() {
        guard configured else { return }
        let settings = AVCapturePhotoSettings()
        // Auto flash for the quick inline capture — there's no flash control in
        // the inline viewfinder (the full-screen camera has one).
        if photoOutput.supportedFlashModes.contains(.auto) {
            settings.flashMode = .auto
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func configureIfNeededAndRun() {
        status = .authorized
        // Configure on the main actor (like CameraView) so the session +
        // `configured` flag are only ever touched here; only the blocking
        // run call goes to the session queue.
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .photo
            // Plain wide-angle is all the inline tile needs — no multi-lens
            // virtual device, since this surface intentionally doesn't zoom.
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()
            configured = true
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        // Stop the session immediately — the tile is about to be replaced by
        // the captured photo / result, and a second shutter mid-ingest is noise.
        Task { @MainActor [weak self] in
            self?.stop()
            self?.onCapture?(data)
        }
    }
}

// MARK: - Preview layer host

/// A `UIView` backed directly by an `AVCaptureVideoPreviewLayer`, so the
/// live feed fills the tile with no extra layer juggling.
private struct ScanCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

// MARK: - Framing brackets

/// Four white corner brackets drawn inside an inset rect — the viewfinder
/// framing cue from the mock.
struct ViewfinderBrackets: Shape {
    var inset: CGFloat = 16
    var length: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        let l = length
        // Top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        // Top-right
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        // Bottom-right
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        // Bottom-left
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

// MARK: - Viewfinder view

struct ScanViewfinder: View {
    var controller: ScanCameraController
    /// Parent-computed: the Scene is active AND nothing (the full-screen
    /// camera, a sheet, the photo picker) is covering the tile. Drives the
    /// session so it never runs alongside the full-screen camera.
    let active: Bool
    let onPickPhoto: () -> Void
    let onExpand: () -> Void
    let onCapture: (Data) -> Void

    var body: some View {
        ZStack {
            if controller.status == .denied {
                deniedTile
            } else {
                viewfinder
            }
        }
        // Matches the Detail view's hero-image height (260) — Sean's
        // deliberate footprint, not the mock's 226.
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            controller.setOnCapture(onCapture)
            if active { controller.start() }
        }
        .onDisappear { controller.stop() }
        .onChange(of: active) { _, isActive in
            isActive ? controller.start() : controller.stop()
        }
    }

    private var viewfinder: some View {
        ZStack {
            // Neutral dark ground shows through until the first camera frame
            // lands (and stands in entirely while access is still being
            // requested), so the tile is never a bright empty box.
            RadialGradient(
                colors: [Color(white: 0.20), Color(white: 0.08)],
                center: .center, startRadius: 8, endRadius: 240
            )
            if controller.status == .authorized {
                ScanCameraPreview(session: controller.session)
            }

            // The brackets frame the PREVIEW region only; the control row sits
            // in a band beneath them, so the brackets never overlap the
            // controls (matching the mock).
            VStack(spacing: 0) {
                ZStack {
                    ViewfinderBrackets()
                        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.8), lineWidth: 2)
                        .frame(width: 60, height: 60)
                    VStack {
                        Text("Point at a brown landmark sign")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .padding(.top, 14)
                        Spacer()
                    }
                }
                controlRow
                    .padding(.bottom, 14)
            }
        }
    }

    private var controlRow: some View {
        HStack {
            // Gallery → library picker: a BrandBrownForeground rounded-square
            // thumb (the mock's tan gallery button). contentShape makes the
            // whole tile tappable, not just the glyph.
            Button(action: onPickPhoto) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color("BrandBrownForeground"))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a photo")

            Spacer()

            // Shutter — the classic white capture button (filled disc + a thin
            // outer ring). contentShape(Circle()) makes the WHOLE circle the
            // tap target.
            Button(action: { controller.capture() }) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 3)
                        .frame(width: 60, height: 60)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 50, height: 50)
                }
                .frame(width: 60, height: 60)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(controller.status != .authorized)
            .opacity(controller.status == .authorized ? 1 : 0.4)
            .accessibilityLabel("Take photo")

            Spacer()

            // Expand to the full-screen camera (pinch-zoom / focus for a
            // distant sign). Lives lower-right now — there's no flash control
            // in the inline viewfinder (it's on the full-screen camera).
            circleButton("arrow.up.left.and.arrow.down.right", label: "Open full camera", action: onExpand)
        }
        .padding(.horizontal, 28)
    }

    private func circleButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.black.opacity(0.4)))
                // Whole circle tappable, not just the glyph — this is why the
                // gallery/expand buttons did nothing before.
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Compact in-tile permission state (the full-screen camera has the
    /// roomier version). Keeps the same dark ground + brackets so it reads
    /// as the viewfinder, just unavailable.
    private var deniedTile: some View {
        ZStack {
            RadialGradient(
                colors: [Color(white: 0.20), Color(white: 0.08)],
                center: .center, startRadius: 8, endRadius: 240
            )
            ViewfinderBrackets()
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            VStack(spacing: 10) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white)
                Text("Camera access needed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Turn on camera access to scan a sign.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(.horizontal, 24)
        }
    }
}
