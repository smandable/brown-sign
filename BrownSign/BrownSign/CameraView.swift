//
//  CameraView.swift
//  BrownSign
//
//  UIKit camera VC wrapped as a SwiftUI UIViewControllerRepresentable.
//  Full-screen preview with the back camera (a multi-lens virtual device when
//  the phone has one, so pinch-zoom reaches the optical telephoto; plain
//  wide-angle with digital zoom otherwise), 70pt white capture button,
//  tap-to-focus with yellow focus ring, pinch-to-zoom with a live readout,
//  full-resolution capture when zoomed, auto flash.
//

import SwiftUI
import AVFoundation
import CoreMedia
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct CameraView: UIViewControllerRepresentable {
    var onCapture: (Data) -> Void
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
    /// The device's `videoZoomFactor` captured at the start of a pinch, so the
    /// gesture scales relative to where the zoom already was rather than
    /// snapping back to 1.0 each time a new pinch begins. Reset on `.began`.
    private var pinchStartZoom: CGFloat = 1.0
    /// The active back-camera device: a multi-lens virtual device (triple or
    /// dual) when the phone has a telephoto, so pinch-zoom can cross into the
    /// optical lens; otherwise the plain wide-angle camera. Held so pinch-zoom
    /// and tap-to-focus drive the same device.
    private var videoDevice: AVCaptureDevice?
    /// Zoom factor of the normal 1x wide view, and the floor for pinch-zoom. On
    /// a multi-lens device factor 1.0 is the ultra-wide (0.5x), so this holds
    /// the ultra-wide→wide switch-over factor; on a wide-only device it is 1.0.
    private var baselineZoom: CGFloat = 1.0
    /// The small "1×/2×/5×" readout that appears while pinching and fades once
    /// the gesture ends. Built only in the configured (authorized) state.
    private var zoomPill: UIView!
    private var zoomLabel: UILabel!
    /// Pending fade-out of the zoom pill, cancelled and rescheduled on each
    /// pinch so the readout stays up while the user is actively zooming.
    private var zoomPillFadeWork: DispatchWorkItem?
    /// Invisible adjustable element overlaying the preview so VoiceOver and
    /// Switch Control users can zoom. Pinch is otherwise the ONLY zoom
    /// affordance — unreachable for Switch Control and awkward through
    /// VoiceOver's pass-through gesture — even though zoom is what feeds the
    /// high-res OCR path for distant signs.
    private var zoomAccessibilityElement: ZoomAccessibilityElement?

    /// UIView that forwards the accessibility "adjustable" increment and
    /// decrement actions (VoiceOver swipe up/down with the element focused).
    private final class ZoomAccessibilityElement: UIView {
        var onAdjust: ((Int) -> Void)?
        override func accessibilityIncrement() { onAdjust?(1) }
        override func accessibilityDecrement() { onAdjust?(-1) }
    }
    /// Full-resolution photo dimensions (the sensor's max, e.g. 48MP) and a
    /// lighter ~12MP standard size. Zoomed shots capture at the full size so the
    /// digital-zoom crop comes off the high-res readout and stays sharp;
    /// un-zoomed shots use the standard size for a snappier shutter. On a 12MP
    /// phone both collapse to 12MP, so capture is unchanged there.
    private var maxPhotoDimensions: CMVideoDimensions?
    private var standardPhotoDimensions: CMVideoDimensions?

    var onCapture: ((Data) -> Void)?
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
        // Keep the readout a perfect capsule whatever its content height.
        zoomPill?.layer.cornerRadius = (zoomPill?.bounds.height ?? 0) / 2
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
        configurePhotosButton()
        configureFlashButton()
        configureZoomLabel()
        configureTapToFocus()
        configurePinchToZoom()
        configureZoomAccessibility()
        captureConfigured = true
        // Keep the chrome above the freshly-inserted preview + capture button
        // so it stays tappable.
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(flashButton)
        view.bringSubviewToFront(photosButton)
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

        if let device = bestBackCamera(),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            videoDevice = device
            baselineZoom = baselineZoomFactor(for: device)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()

        configureHighResolutionCapture()

        // Open at the normal 1x view. On a multi-lens device zoom factor 1.0 is
        // the ultra-wide (0.5x), so without this the camera would launch wider
        // and more distorted than every other camera app.
        applyZoom(baselineZoom)
    }

    /// Raise the photo output's ceiling to the sensor's largest size (48MP on
    /// phones that have it) so `capturePhoto` can opt a zoomed shot into a
    /// full-resolution frame. A 12MP phone reports only the one size, so this
    /// leaves capture unchanged there.
    private func configureHighResolutionCapture() {
        guard let device = videoDevice else { return }
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        guard let maxDims = supported.last else { return }
        maxPhotoDimensions = maxDims
        // Largest size at or below ~12MP (4032 wide) for un-zoomed shots.
        standardPhotoDimensions = supported.last(where: { $0.width <= 4032 }) ?? supported.first
        photoOutput.maxPhotoDimensions = maxDims
    }

    /// Pick the back camera, preferring a multi-lens virtual device so pinch-
    /// zoom can cross into the optical telephoto on phones that have one, and
    /// falling back to the wide-angle camera (digital zoom only) otherwise.
    /// Order: triple (UW+W+T) → dual (W+T) → wide-angle. Dual-wide (UW+W) is
    /// skipped deliberately: it only adds the ultra-wide, which this app never
    /// zooms out to, so it buys nothing over the plain wide-angle camera.
    private func bestBackCamera() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        for type in preferred {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }

    /// The zoom factor at which the normal 1x wide view begins. For a virtual
    /// device whose widest lens is the ultra-wide, factor 1.0 is 0.5x and the
    /// first switch-over factor is where the wide (1x) takes over; for a wide-
    /// or tele-based device, 1.0 is already 1x.
    private func baselineZoomFactor(for device: AVCaptureDevice) -> CGFloat {
        if device.constituentDevices.first?.deviceType == .builtInUltraWideCamera,
           let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(firstSwitchOver.doubleValue)
        }
        return 1.0
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
        // The button itself is the outer RING: clear center, white border.
        captureButton.backgroundColor = .clear
        captureButton.layer.cornerRadius = 35
        captureButton.layer.borderColor = UIColor.white.cgColor
        captureButton.layer.borderWidth = 3
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.accessibilityLabel = "Take photo"
        captureButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)

        // Inner white disc with a small gap inside the ring — the classic
        // disc + ring shutter, matching the inline viewfinder's button.
        // Non-interactive so taps fall through to the button.
        let innerDisc = UIView()
        innerDisc.backgroundColor = .white
        innerDisc.isUserInteractionEnabled = false
        innerDisc.layer.cornerRadius = 29
        innerDisc.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addSubview(innerDisc)

        view.addSubview(captureButton)

        NSLayoutConstraint.activate([
            captureButton.widthAnchor.constraint(equalToConstant: 70),
            captureButton.heightAnchor.constraint(equalToConstant: 70),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -24
            ),
            innerDisc.widthAnchor.constraint(equalToConstant: 58),
            innerDisc.heightAnchor.constraint(equalToConstant: 58),
            innerDisc.centerXAnchor.constraint(equalTo: captureButton.centerXAnchor),
            innerDisc.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor)
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
        closeButton.accessibilityLabel = "Close camera"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            // Top-RIGHT (the flash control takes the top-left).
            closeButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -16
            ),
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 16
            )
        ])
    }

    // MARK: - Flash control

    /// Flash mode for full-screen captures, toggled by the top-left button
    /// (auto → on → off). The inline viewfinder always uses auto and has no
    /// control of its own.
    private var flashMode: AVCaptureDevice.FlashMode = .auto
    private var flashButton: UIButton!

    private func configureFlashButton() {
        flashButton = UIButton(type: .system)
        flashButton.tintColor = .white
        flashButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        flashButton.layer.cornerRadius = 22
        flashButton.translatesAutoresizingMaskIntoConstraints = false
        flashButton.addTarget(self, action: #selector(toggleFlash), for: .touchUpInside)
        view.addSubview(flashButton)

        NSLayoutConstraint.activate([
            flashButton.widthAnchor.constraint(equalToConstant: 44),
            flashButton.heightAnchor.constraint(equalToConstant: 44),
            flashButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 16
            ),
            flashButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 16
            )
        ])
        updateFlashButtonIcon()
    }

    private func updateFlashButtonIcon() {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        let name: String
        let label: String
        switch flashMode {
        case .on: name = "bolt.fill"; label = "Flash on"
        case .off: name = "bolt.slash.fill"; label = "Flash off"
        default: name = "bolt.badge.a.fill"; label = "Flash auto"
        }
        flashButton.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
        flashButton.accessibilityLabel = label
    }

    @objc private func toggleFlash() {
        switch flashMode {
        case .auto: flashMode = .on
        case .on: flashMode = .off
        default: flashMode = .auto
        }
        updateFlashButtonIcon()
    }

    // MARK: - Library picker

    /// "Choose a photo" button to the LEFT of the shutter — the same library-
    /// import affordance the inline viewfinder has (a tan rounded square with
    /// the photo glyph). A pick routes through `onCapture`, exactly like a
    /// shutter capture, so the full-screen camera and inline tile import the
    /// same way.
    private var photosButton: UIButton!

    private func configurePhotosButton() {
        photosButton = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        photosButton.setImage(UIImage(systemName: "photo.on.rectangle.angled", withConfiguration: config), for: .normal)
        photosButton.tintColor = .white
        photosButton.backgroundColor = UIColor(named: "BrandBrownForeground")
        photosButton.layer.cornerRadius = 12
        photosButton.translatesAutoresizingMaskIntoConstraints = false
        photosButton.accessibilityLabel = "Choose a photo"
        photosButton.addTarget(self, action: #selector(presentPhotoPicker), for: .touchUpInside)
        view.addSubview(photosButton)

        NSLayoutConstraint.activate([
            photosButton.widthAnchor.constraint(equalToConstant: 50),
            photosButton.heightAnchor.constraint(equalToConstant: 50),
            // Vertically centred on the shutter, near the leading edge.
            photosButton.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
            photosButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 40
            )
        ])
    }

    @objc private func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func configureTapToFocus() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        view.addGestureRecognizer(tap)
    }

    private func configurePinchToZoom() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchToZoom(_:)))
        view.addGestureRecognizer(pinch)
    }

    /// Adjustable zoom element for assistive tech, pinned over the preview
    /// area (above the capture button). Not user-interactive, so touches —
    /// tap-to-focus, pinch — pass straight through it; VoiceOver reaches it
    /// via the accessibility tree, where swipe up/down steps the zoom ±25%
    /// through the same clamped range as the pinch. The element's value
    /// auto-announces after each step.
    private func configureZoomAccessibility() {
        let element = ZoomAccessibilityElement()
        element.translatesAutoresizingMaskIntoConstraints = false
        element.backgroundColor = .clear
        element.isUserInteractionEnabled = false
        element.isAccessibilityElement = true
        element.accessibilityTraits = .adjustable
        element.accessibilityLabel = "Camera zoom"
        element.accessibilityValue = accessibilityZoomValue()
        element.onAdjust = { [weak self] direction in
            self?.adjustZoomForAccessibility(direction)
        }
        view.addSubview(element)
        zoomAccessibilityElement = element

        NSLayoutConstraint.activate([
            element.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            element.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            element.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            element.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -12)
        ])
    }

    /// Current zoom as a VoiceOver-friendly value ("2x", not the "×" glyph,
    /// which VoiceOver reads oddly).
    private func accessibilityZoomValue() -> String {
        zoomText(forFactor: videoDevice?.videoZoomFactor ?? baselineZoom)
            .replacingOccurrences(of: "×", with: "x")
    }

    private func adjustZoomForAccessibility(_ direction: Int) {
        guard captureConfigured, let device = videoDevice else { return }
        let factor = direction > 0
            ? device.videoZoomFactor * 1.25
            : device.videoZoomFactor / 1.25
        showZoomPill()
        applyZoom(factor)
        scheduleZoomPillFade()
    }

    private func configureZoomLabel() {
        let pill = UIView()
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.alpha = 0 // hidden until the first pinch
        pill.isUserInteractionEnabled = false
        view.addSubview(pill)
        zoomPill = pill

        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = zoomText(forFactor: videoDevice?.videoZoomFactor ?? baselineZoom)
        pill.addSubview(label)
        zoomLabel = label

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),

            pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -12)
        ])
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
        // "Roadside signs", matching the camera permission prompt, the App
        // Store copy, and every other surface (this overlay was the one
        // place that said "tourist signs").
        message.text = "Brown Sign uses the camera to read brown roadside signs. Turn on camera access in Settings to snap a sign."
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
        // User-chosen flash mode from the top-left control (default auto).
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        // Capture at full sensor resolution once zoomed in, so the crop is taken
        // from the high-res readout (a crisp 2x is a 12MP center crop of 48MP)
        // rather than an upscaled bin; an un-zoomed shot keeps the lighter
        // standard size for a snappier shutter.
        if let device = videoDevice,
           let maxDims = maxPhotoDimensions,
           let stdDims = standardPhotoDimensions {
            let zoomedIn = device.videoZoomFactor > baselineZoom * 1.1
            settings.maxPhotoDimensions = zoomedIn ? maxDims : stdDims
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            return
        }

        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }

        // Hand up the raw photo data so the consumer can downsample straight
        // from it; a 48MP frame is never fully decoded into a UIImage here.
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(data)
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
        if let device = videoDevice,
           device.isFocusPointOfInterestSupported,
           device.isFocusModeSupported(.autoFocus) {
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
                device.unlockForConfiguration()
            } catch {
                // Non-fatal — just skip focus adjustment.
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

    // MARK: - Pinch-to-zoom

    /// Continuous pinch-to-zoom. Scales from the zoom factor captured at
    /// `.began`; on a multi-lens phone the system crosses into the optical
    /// telephoto partway up the range. `applyZoom` does the clamping.
    @objc private func handlePinchToZoom(_ recognizer: UIPinchGestureRecognizer) {
        // The recognizer is only installed in `setUpCaptureUI`, so the device
        // is non-nil here — but guard so a future change can't reach a device
        // in the denied state, where no session was built.
        guard captureConfigured, let device = videoDevice else { return }
        switch recognizer.state {
        case .began:
            pinchStartZoom = device.videoZoomFactor
            showZoomPill()
        case .changed:
            applyZoom(pinchStartZoom * recognizer.scale)
        case .ended, .cancelled, .failed:
            if let device = videoDevice {
                UIAccessibility.post(
                    notification: .announcement,
                    // Use "x" not the "×" glyph, which VoiceOver reads oddly.
                    argument: "Zoom \(zoomText(forFactor: device.videoZoomFactor).replacingOccurrences(of: "×", with: "x"))"
                )
            }
            scheduleZoomPillFade()
        default:
            break
        }
    }

    /// Set the device zoom factor, clamped to the allowed range and wrapped in
    /// the required configuration lock. No-ops if locking fails (non-fatal).
    private func applyZoom(_ factor: CGFloat) {
        guard let device = videoDevice else { return }
        let clamped = max(minZoom(for: device), min(factor, maxZoom(for: device)))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            // Non-fatal — leave the zoom where it is.
        }
        zoomLabel?.text = zoomText(forFactor: device.videoZoomFactor)
        // Keep the adjustable element's value in sync however the zoom moved
        // (pinch or accessibility adjustment).
        zoomAccessibilityElement?.accessibilityValue = accessibilityZoomValue()
    }

    /// Floor: never pinch out below the normal 1x view. The ultra-wide's wider,
    /// more distorted frame isn't useful for reading a sign.
    private func minZoom(for device: AVCaptureDevice) -> CGFloat {
        max(device.minAvailableVideoZoomFactor, baselineZoom)
    }

    /// Ceiling: up to 10x the 1x view. On a tele phone the optical lens engages
    /// partway up (sharp), with a little digital headroom past it for a distant
    /// sign; clamped to what the device actually supports.
    private func maxZoom(for device: AVCaptureDevice) -> CGFloat {
        min(device.maxAvailableVideoZoomFactor, baselineZoom * 10.0)
    }

    /// The user-facing zoom multiple ("1×", "2.4×", "5×") for a raw device zoom
    /// factor, taken relative to the 1x baseline so a multi-lens device reads in
    /// familiar terms (factor 2.0 on a Pro shows "1×", not "2×").
    private func zoomText(forFactor factor: CGFloat) -> String {
        let multiple = max(1.0, factor / baselineZoom)
        let oneDecimal = String(format: "%.1f", Double(multiple))
        let trimmed = oneDecimal.hasSuffix(".0") ? String(oneDecimal.dropLast(2)) : oneDecimal
        return trimmed + "×"
    }

    /// Bring the readout up immediately and hold it there for the pinch.
    private func showZoomPill() {
        zoomPillFadeWork?.cancel()
        zoomPillFadeWork = nil
        UIView.animate(withDuration: 0.15) { self.zoomPill?.alpha = 1 }
    }

    /// Fade the readout out a beat after the pinch ends, so it doesn't linger
    /// over the shot. Re-scheduling cancels any in-flight fade.
    private func scheduleZoomPillFade() {
        zoomPillFadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.zoomPill?.alpha = 0 }
        }
        zoomPillFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

// MARK: - Library picker delegate

extension CameraViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        // Hand the chosen photo's bytes up through onCapture — the same path a
        // shutter press uses — so it ingests/OCRs identically. Prefer the raw
        // data representation (ingestPhoto downsamples from it via ImageIO);
        // fall back to a re-encoded UIImage if the provider won't vend data.
        let typeID = UTType.image.identifier
        if provider.hasItemConformingToTypeIdentifier(typeID) {
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { [weak self] data, _ in
                guard let self, let data else { return }
                DispatchQueue.main.async { self.onCapture?(data) }
            }
        } else if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let self, let image = object as? UIImage,
                      let data = image.jpegData(compressionQuality: 0.9) else { return }
                DispatchQueue.main.async { self.onCapture?(data) }
            }
        }
    }
}
