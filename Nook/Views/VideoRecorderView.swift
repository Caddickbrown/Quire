//
//  VideoRecorderView.swift
//  Nook
//
//  Record a video in-app and hand back the file URL. iOS uses the system camera
//  controller; macOS uses an AVCaptureSession with a live preview + record/stop.
//

import SwiftUI
@preconcurrency import AVFoundation

#if os(iOS)
import UIKit
import UniformTypeIdentifiers

struct VideoRecorderView: UIViewControllerRepresentable {
    var onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // Order matters: mediaTypes must include movie BEFORE setting .video mode.
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        if UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        picker.videoQuality = .typeHigh
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

#elseif os(macOS)
import AppKit

struct VideoRecorderView: View {
    var onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = CameraController()

    var body: some View {
        VStack(spacing: 0) {
            CameraPreview(session: cam.session)
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
        .task { await cam.configure() }
        .onDisappear { cam.teardown() }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = preview
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVCaptureVideoPreviewLayer)?.frame = view.bounds
    }
}

@MainActor
final class CameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    @Published var isRecording = false
    @Published var ready = false
    private var onFinish: ((URL) -> Void)?

    func configure() async {
        guard await request(.video) else { return }
        _ = await request(.audio)

        session.beginConfiguration()
        session.sessionPreset = .high
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        if let camera,
           let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let ainput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(ainput) {
            session.addInput(ainput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()

        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        ready = true
    }

    func startRecording(_ onFinish: @escaping (URL) -> Void) {
        self.onFinish = onFinish
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording() { movieOutput.stopRecording() }

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
}
#endif
