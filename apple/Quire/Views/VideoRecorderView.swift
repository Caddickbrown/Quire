//
//  VideoRecorderView.swift
//  Quire
//
//  Capture from the camera in-app and hand back a file URL — a video
//  (`VideoRecorderView`) or a still photo (`PhotoCaptureView`). iOS uses the
//  system camera controller; macOS uses an AVCaptureSession with a live preview.
//

import SwiftUI
@preconcurrency import AVFoundation

/// Shared camera helpers.
enum CameraCapture {
    /// Park captured JPEG data in a temp file, so a photo hands back a URL just
    /// like a recorded video does.
    static func writeTemporaryJPEG(_ data: Data?) -> URL? {
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

struct VideoRecorderView: UIViewControllerRepresentable {
    var onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // No camera on the Simulator (or when one is restricted) — asking for
        // `.camera` anyway raises rather than opening black, so fall back to
        // the library exactly as the photo path below does.
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
        picker.sourceType = hasCamera ? .camera : .photoLibrary
        // Order matters: mediaTypes must include movie BEFORE setting .video mode.
        picker.mediaTypes = [UTType.movie.identifier]
        if hasCamera {
            picker.cameraCaptureMode = .video
            if UIImagePickerController.isCameraDeviceAvailable(.front) {
                picker.cameraDevice = .front
            }
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VideoRecorderView
        init(_ parent: VideoRecorderView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { parent.onFinish(url) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Take a photo with the camera. Hands back a file URL like the video recorder,
/// so both attach through the same `importAsset` path.
struct PhotoCaptureView: UIViewControllerRepresentable {
    var onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // No camera on the Simulator — fall back to the library so the sheet
        // still does something rather than opening black.
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
        picker.sourceType = hasCamera ? .camera : .photoLibrary
        picker.mediaTypes = [UTType.image.identifier]
        if hasCamera { picker.cameraCaptureMode = .photo }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PhotoCaptureView
        init(_ parent: PhotoCaptureView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // A library pick carries a URL; a fresh capture only has the image.
            if let url = info[.imageURL] as? URL {
                parent.onFinish(url)
            } else if let image = info[.originalImage] as? UIImage,
                      let url = CameraCapture.writeTemporaryJPEG(image.jpegData(compressionQuality: 0.9)) {
                parent.onFinish(url)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

#elseif os(macOS)
import AppKit

struct VideoRecorderView: View {
    var onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraController()

    var body: some View {
        VStack(spacing: 0) {
            CameraPreview(session: cam.session, device: cam.camera)
                .frame(minWidth: 480, minHeight: 360)
                .background(Color.black)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(cam.isRecording ? "● Recording" : (cam.ready ? "Ready" : "Starting camera…"))
                    .font(.callout).foregroundStyle(cam.isRecording ? .red : .secondary)
                Spacer()
                Button(cam.isRecording ? "Stop" : "Record") {
                    if cam.isRecording {
                        cam.stopRecording()
                    } else {
                        cam.startRecording { url in onFinish(url); dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!cam.ready)
            }
            .padding()
        }
        .frame(width: 560, height: 460)
        .task { await cam.configure(mode: .video) }
        .onDisappear { cam.teardown() }
    }
}

/// Take a photo with the camera. Hands back a file URL like the video recorder,
/// so both attach through the same `importAsset` path.
struct PhotoCaptureView: View {
    var onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraController()

    var body: some View {
        VStack(spacing: 0) {
            CameraPreview(session: cam.session, device: cam.camera)
                .frame(minWidth: 480, minHeight: 360)
                .background(Color.black)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Text(cam.ready ? "Ready" : "Starting camera…")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Take Photo") {
                    cam.capturePhoto { url in onFinish(url); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!cam.ready)
            }
            .padding()
        }
        .frame(width: 560, height: 460)
        .task { await cam.configure(mode: .photo) }
        .onDisappear { cam.teardown() }
    }
}

/// The live preview. Fit, not fill, so a feed whose shape differs from the
/// sheet (a Continuity Camera iPhone held upright) is letterboxed rather than
/// cropped; a rotation coordinator keeps it level as that camera turns; the
/// layer is re-fitted on every layout pass, not only when SwiftUI updates.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var device: AVCaptureDevice?
    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = session
        view.attach(device)
        return view
    }
    func updateNSView(_ view: PreviewView, context: Context) {
        view.attach(device)
        view.needsLayout = true
    }

    final class PreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        private var device: AVCaptureDevice?
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            preview.videoGravity = .resizeAspect
            layer = preview
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            preview.frame = bounds
        }

        /// Follow `device`'s rotation; a no-op while it is unchanged.
        func attach(_ device: AVCaptureDevice?) {
            guard device !== self.device else { return }
            self.device = device
            observation = nil
            rotation = nil
            guard let device else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
            rotation = coordinator
            apply(coordinator.videoRotationAngleForHorizonLevelPreview)
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                              options: [.new]) { [weak self] _, change in
                guard let angle = change.newValue else { return }
                DispatchQueue.main.async { self?.apply(angle) }
            }
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = preview.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }
}

@MainActor
final class CameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate,
                              AVCapturePhotoCaptureDelegate {
    /// What the session is wired up for. Photo mode skips the microphone
    /// entirely, so taking a picture never asks for mic access.
    enum Mode { case video, photo }

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    @Published var isRecording = false
    @Published var ready = false
    /// The camera in use, once configured — the preview follows its rotation.
    @Published private(set) var camera: AVCaptureDevice?
    private var onFinish: ((URL) -> Void)?
    private var onCapture: ((URL) -> Void)?

    func configure(mode: Mode = .video) async {
        guard await request(.video) else { return }
        if mode == .video { _ = await request(.audio) }

        session.beginConfiguration()
        session.sessionPreset = .high
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        if let camera,
           let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
            self.camera = camera
        }
        switch mode {
        case .video:
            if let mic = AVCaptureDevice.default(for: .audio),
               let ainput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(ainput) {
                session.addInput(ainput)
            }
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        case .photo:
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        }
        session.commitConfiguration()

        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        ready = true
    }

    func startRecording(_ onFinish: @escaping (URL) -> Void) {
        self.onFinish = onFinish
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        level(movieOutput.connection(with: .video))
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording() { movieOutput.stopRecording() }

    /// Take one still. JPEG when the output offers it, so the `.jpg` the file
    /// gets written as always matches its contents.
    func capturePhoto(_ onCapture: @escaping (URL) -> Void) {
        self.onCapture = onCapture
        let settings = photoOutput.availablePhotoCodecTypes.contains(.jpeg)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg.rawValue])
            : AVCapturePhotoSettings()
        level(photoOutput.connection(with: .video))
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// Record level with the horizon, as the preview shows it.
    private func level(_ connection: AVCaptureConnection?) {
        guard let camera, let connection else { return }
        let angle = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: nil)
            .videoRotationAngleForHorizonLevelCapture
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    func teardown() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { if session.isRunning { session.stopRunning() } }
    }

    private func request(_ type: AVMediaType) async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: type) { cont.resume(returning: $0) }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            if error == nil { self.onFinish?(outputFileURL) }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil,
              let url = CameraCapture.writeTemporaryJPEG(photo.fileDataRepresentation()) else { return }
        Task { @MainActor in self.onCapture?(url) }
    }
}
#endif
