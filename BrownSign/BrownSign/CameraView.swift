//
//  CameraView.swift
//  BrownSign
//
//  UIKit camera VC wrapped as a SwiftUI UIViewControllerRepresentable.
//  Full-screen preview with back wide-angle camera, 70pt white capture
//  button, tap-to-focus with yellow focus ring, auto flash.
//

import SwiftUI
import AVFoundation
import UIKit

struct CameraView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCapture = onCapture
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

final class CameraViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let sessionQueue = DispatchQueue(label: "com.seanmandable.brownsign.session")
    private var captureButton: UIButton!
    private var closeButton: UIButton!
    /// True once the capture session + preview have been wired up, which
    /// only happens with camera authorization. Gates session start/stop so
    /// the denied state (no session) never touches an unconfigured session
    /// or a nil `previewLayer`.
    private var captureConfigured = false
    /// Whether the view is currently on screen. Guards the async camera-
    /// permission completion so it never starts the session after the user
    /// has already dismissed the camera (which would otherwise leave the
    /// capture session running until the VC deallocates).
    private var isAppeared = false

    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // The close button is always available so the user can back out of
        // every state, including the permission-denied one.
        configureCloseButton()
        requestCameraAccessAndConfigure()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isAppeared = true
        startSessionIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isAppeared = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // nil in the permission-denied state, where no preview was built.
        previewLayer?.frame = view.bounds
    }

    // MARK: - Authorization

    /// Branch on camera authorization: configure capture when allowed,
    /// prompt when undecided, and show an in-view "access needed" state
    /// (instead of a silent black screen) when denied or restricted.
    private func requestCameraAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUpCaptureUI()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.setUpCaptureUI()
                        // `viewWillAppear` already ran (and no-op'd) while the
                        // system prompt was up, so kick the session off now.
                        self.startSessionIfNeeded()
                    } else {
                        self.showPermissionDeniedState()
                    }
                }
            }
        default: // .denied, .restricted, and any future case
            showPermissionDeniedState()
        }
    }

    private func setUpCaptureUI() {
        configureSession()
        configurePreviewLayer()
        configureCaptureButton()
        configureTapToFocus()
        captureConfigured = true
        // Keep the close button above the freshly-inserted preview + capture
        // button so it stays tappable.
        view.bringSubviewToFront(closeButton)
    }

    private func startSessionIfNeeded() {
        // `isAppeared` guards the async-permission path: the requestAccess
        // completion can land after the user dismissed the camera while the
        // system prompt was up — don't start a session on an off-screen VC.
        guard captureConfigured, isAppeared else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    // MARK: - Configuration

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
    }

    private func configurePreviewLayer() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        // Insert at the bottom: the close button is added as a subview before
        // the preview exists, so a plain `addSublayer` would cover it.
        view.layer.insertSublayer(previewLayer, at: 0)
    }

    private func configureCaptureButton() {
        captureButton = UIButton(type: .custom)
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 35
        captureButton.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        captureButton.layer.borderWidth = 3
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        view.addSubview(captureButton)

        NSLayoutConstraint.activate([
            captureButton.widthAnchor.constraint(equalToConstant: 70),
            captureButton.heightAnchor.constraint(equalToConstant: 70),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -24
            )
        ])
    }

    private func configureCloseButton() {
        closeButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        closeButton.layer.cornerRadius = 22
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 16
            ),
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 16
            )
        ])
    }

    private func configureTapToFocus() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        view.addGestureRecognizer(tap)
    }

    // MARK: - Permission denied

    /// Shown in place of the live preview when camera access is denied or
    /// restricted. Explains why the camera is needed and offers a jump to
    /// Settings, instead of leaving the user staring at a black screen with
    /// a capture button that does nothing.
    private func showPermissionDeniedState() {
        let icon = UIImageView(image: UIImage(systemName: "video.slash.fill"))
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        icon.isAccessibilityElement = false

        let title = UILabel()
        title.text = "Camera access needed"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 0

        let message = UILabel()
        message.text = "Brown Sign uses the camera to read brown tourist signs. Turn on camera access in Settings to snap a sign."
        message.font = .preferredFont(forTextStyle: .subheadline)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = UIColor.white.withAlphaComponent(0.75)
        message.textAlignment = .center
        message.numberOfLines = 0

        var config = UIButton.Configuration.borderedProminent()
        config.title = "Open Settings"
        config.baseBackgroundColor = .white
        config.baseForegroundColor = .black
        config.cornerStyle = .large
        let settingsButton = UIButton(
            configuration: config,
            primaryAction: UIAction { [weak self] _ in self?.openSystemSettings() }
        )

        let stack = UIStackView(arrangedSubviews: [icon, title, message, settingsButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(24, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Host the content in a scroll view so the largest Dynamic Type
        // sizes scroll instead of clipping off-screen on short devices. The
        // `content` wrapper is pinned at least as tall as the viewport (low
        // priority), so the stack stays vertically centred when it fits and
        // only scrolls when it genuinely overflows.
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)

        let content = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(content)
        content.addSubview(stack)

        let contentHeight = content.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        contentHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentHeight,

            stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        view.bringSubviewToFront(closeButton)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Cancel

    @objc private func closeTapped() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onCancel?()
        }
    }

    // MARK: - Capture

    @objc private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(.auto) {
            settings.flashMode = .auto
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            return
        }

        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(image)
        }
    }

    // MARK: - Tap-to-focus

    @objc private func handleTapToFocus(_ recognizer: UITapGestureRecognizer) {
        // The recognizer is only installed in `setUpCaptureUI`, so these are
        // non-nil here — but guard explicitly so a future change can't crash
        // in the denied state, where the preview and buttons were never built.
        guard captureConfigured, let previewLayer else { return }
        let point = recognizer.location(in: view)
        // Don't refocus when the user is tapping the UI chrome.
        if captureButton.frame.contains(point) || closeButton.frame.contains(point) {
            return
        }
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)

        // Attempt to set focus on the underlying device.
        if let input = session.inputs.first as? AVCaptureDeviceInput {
            let device = input.device
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                do {
                    try device.lockForConfiguration()
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                    device.unlockForConfiguration()
                } catch {
                    // Non-fatal — just skip focus adjustment.
                }
            }
        }

        showFocusRing(at: point)
    }

    private func showFocusRing(at point: CGPoint) {
        let ring = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        ring.center = point
        ring.layer.cornerRadius = 40
        ring.layer.borderColor = UIColor.yellow.cgColor
        ring.layer.borderWidth = 2
        ring.backgroundColor = .clear
        ring.alpha = 1
        view.addSubview(ring)

        UIView.animate(
            withDuration: 0.6,
            animations: { ring.alpha = 0 },
            completion: { _ in ring.removeFromSuperview() }
        )
    }
}
