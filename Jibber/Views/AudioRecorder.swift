//
//  AudioRecorder.swift
//  Jibber
//
//  Record a voice memo (AAC/.m4a) and hand the data back so it can be saved into
//  the journal's assets folder. Plus a small toolbar RecordButton wrapper.
//

import SwiftUI
import AVFoundation

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed = 0

    private var recorder: AVAudioRecorder?
    private var tempURL: URL?
    private var timer: Timer?

    var elapsedString: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }

    func start() async {
        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        guard granted else { return }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        rec.record()
        recorder = rec
        tempURL = url
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed += 1 }
        }
    }

    /// Stop recording and return the recorded audio data (temp file removed).
    func stop() -> Data? {
        timer?.invalidate(); timer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        defer { tempURL = nil }
        guard let url = tempURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }
}

/// Toolbar button that records audio and returns the data when stopped.
struct RecordButton: View {
    @StateObject private var recorder = AudioRecorder()
    let onFinish: (Data) -> Void

    var body: some View {
        Button {
            if recorder.isRecording {
                if let data = recorder.stop() { onFinish(data) }
            } else {
                Task { await recorder.start() }
            }
        } label: {
            if recorder.isRecording {
                Label(recorder.elapsedString, systemImage: "stop.circle.fill")
                    .foregroundStyle(.red)
                    .monospacedDigit()
            } else {
                Label("Record Audio", systemImage: "mic")
            }
        }
        .help(recorder.isRecording ? "Stop recording" : "Record audio")
    }
}
