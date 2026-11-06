//
//  AudioRecorder.swift
//  Nook
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
        // Double-tapping the record button used to strand the first recorder:
        // it kept running with nothing holding it, and `stop()` returned the
        // second (empty) file.
        guard !isRecording else { return }

        let granted = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        // The await above is a suspension point, so re-check: a second tap can
        // have got its permission answer first and already be recording.
        guard granted, !isRecording else { return }

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
        // `record()` reports failure rather than throwing (a busy session, an
        // interruption); flipping isRecording anyway showed a banner counting
        // up over a file that was never written.
        guard rec.record() else {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return
        }
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
        #if os(iOS)
        // Hand the audio session back — leaving it active kept other apps'
        // audio ducked long after the memo ended.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        defer { tempURL = nil }
        guard let url = tempURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }
}

/// A prominent "Recording… [Stop]" banner shown while recording.
struct RecordingBanner: View {
    let elapsed: String
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text("Recording \(elapsed)").font(.callout.monospacedDigit())
            Button("Stop", action: onStop)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 16)
        .transition(.opacity)
    }
}
