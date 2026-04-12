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

    var onCapture: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        configurePreviewLayer()
        configureCaptureButton()
        configureCloseButton()
        configureTapToFocus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
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
        view.layer.addSublayer(previewLayer)
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
