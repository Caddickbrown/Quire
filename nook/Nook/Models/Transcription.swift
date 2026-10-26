//
//  Transcription.swift
//  Nook
//
//  Voice-memo transcription (Speech framework). On-device when the recogniser
//  supports it — the transcript is inserted into the entry body beneath the
//  audio's `![](assets/…)` link, so the words become ordinary searchable,
//  taggable text and nothing new lands on disk.
//

import Foundation
import Speech

enum Transcriber {
    enum TranscriptionError: LocalizedError {
        case notAuthorized
        case unavailable
        case empty

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Allow speech recognition in Settings to transcribe voice memos."
            case .unavailable:   return "Speech recognition isn't available for your language on this device."
            case .empty:         return "No speech was recognised in this recording."
            }
        }
    }

    /// Transcribe one audio file to text. Prefers on-device recognition and
    /// falls back to the recogniser's default only when on-device isn't
    /// supported for the current locale.
    static func transcribe(url: URL) async throws -> String {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let text: String = try await withCheckedThrowingContinuation { cont in
            // The callback can arrive on any queue; the lock makes the
            // single-resume guarantee airtight rather than probabilistic.
            let resumed = NSLock()
            var done = false
            func resumeOnce(_ body: () -> Void) {
                resumed.lock(); defer { resumed.unlock() }
                guard !done else { return }
                done = true
                body()
            }
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    resumeOnce { cont.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    resumeOnce { cont.resume(throwing: error) }
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.empty }
        return trimmed
    }

    /// The audio asset links in a body that don't already have a transcript
    /// paragraph following them.
    static func audioPaths(in body: String) -> [String] {
        MediaLinks.paths(in: body).filter { MediaKind(path: $0) == .audio }
    }

    /// Insert `transcript` on its own paragraph directly after the `![](path)`
    /// link in `body`. Returns the updated body (unchanged if the link is gone).
    static func insert(transcript: String, after path: String, in body: String) -> String {
        guard let linkRange = body.range(of: "](\(path))") else { return body }
        // End of the link's line.
        let afterLink = body[linkRange.upperBound...]
        let insertAt = afterLink.firstIndex(of: "\n") ?? body.endIndex
        var out = body
        out.insert(contentsOf: "\n\n\(transcript)", at: insertAt)
        return out
    }
}

// MARK: - Transcribed-asset records + Transcribe All

/// Which voice memos have already been transcribed, so auto-transcribe and
/// the batch action never insert a transcript twice. Same shape as the Data
/// Saver tally: each device owns one `.nook/transcribed-<id>.json`, the union
/// is consulted, so a memo transcribed on any device is skipped everywhere.
extension JournalStore {
    static let autoTranscribeKey = "autoTranscribe"

    private struct TranscribedRecord: Codable { var assets: [String] = [] }

    private var transcribedFileURL: URL? {
        baseURL?.appendingPathComponent(".nook", isDirectory: true)
            .appendingPathComponent("transcribed-\(deviceRecordID).json")
    }

    /// Asset uuids transcribed on ANY device.
    func transcribedAssetIDs() -> Set<String> {
        guard let dir = baseURL?.appendingPathComponent(".nook", isDirectory: true),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        let records = items
            .filter { $0.lastPathComponent.hasPrefix("transcribed-") && $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(TranscribedRecord.self, from: $0) }
        return Set(records.flatMap(\.assets))
    }

    func markTranscribed(assetID: String) {
        guard let url = transcribedFileURL else { return }
        var record = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(TranscribedRecord.self, from: $0) }
            ?? TranscribedRecord()
        guard !record.assets.contains(assetID) else { return }
        record.assets.append(assetID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(record) { try? data.write(to: url, options: .atomic) }
    }

    /// Sweep the whole journal for voice memos no device has transcribed yet
    /// and insert each transcript beneath its link, file by file. Serial (one
    /// recognition at a time) with the same progress row the media compressor
    /// uses. Returns (transcribed, failed).
    @discardableResult
    func transcribeAllMemos() async -> (done: Int, failed: Int) {
        let already = transcribedAssetIDs()
        var work: [(file: URL, path: String)] = []
        for file in allContentFileURLs() {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for path in Transcriber.audioPaths(in: content) {
                let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                if !already.contains(id) { work.append((file, path)) }
            }
        }
        guard !work.isEmpty else { return (0, 0) }

        var done = 0, failed = 0
        setMediaProgress((0, work.count))
        for (i, item) in work.enumerated() {
            defer { setMediaProgress((i + 1, work.count)) }
            guard let url = assetURL(forRelative: item.path) else { failed += 1; continue }
            let id = ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
            do {
                let transcript = try await Transcriber.transcribe(url: url)
                // Re-read after the await: recognition takes seconds to
                // minutes, and the composer autosaves the inbox every 500ms —
                // inserting into the snapshot taken before it would write the
                // file back as it was when this run started.
                guard let fresh = try? JournalStore.readForRewrite(item.file),
                      fresh.contains("](\(item.path))") else { continue }
                rewriteContentFile(item.file,
                                   Transcriber.insert(transcript: transcript, after: item.path, in: fresh))
                markTranscribed(assetID: id)
                done += 1
            } catch Transcriber.TranscriptionError.empty {
                // Nothing recognisable — mark it so it isn't retried forever.
                markTranscribed(assetID: id)
            } catch {
                failed += 1
            }
        }
        setMediaProgress(nil)
        reload()
        return (done, failed)
    }
}
