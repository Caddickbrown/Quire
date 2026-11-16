//
//  Transcription.swift
//  Quire
//
//  Voice-memo transcription (Speech framework). On this device only, unless
//  Apple's servers have been allowed by name (`Transcriber.allowServerKey`) —
//  the transcript is inserted into the entry body beneath the
//  audio's `![](assets/…)` link, so the words become ordinary searchable,
//  taggable text and nothing new lands on disk.
//

import Foundation
import Speech

enum Transcriber {
    enum TranscriptionError: LocalizedError {
        case notAuthorized
        case unavailable
        case onDeviceUnavailable
        case empty

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Allow speech recognition in Settings to transcribe voice memos."
            case .unavailable:   return "Speech recognition isn't available for your language on this device."
            case .onDeviceUnavailable:
                return "This device can't transcribe your language by itself, and Quire doesn't send recordings to Apple's servers unless you allow it."
            case .empty:         return "No speech was recognised in this recording."
            }
        }
    }

    /// Off unless switched on: let a recording go to Apple's servers when this
    /// device can't recognise the language by itself. No screen sets it yet.
    static let allowServerKey = "transcribeAllowServer"

    enum Route: Equatable { case onDevice, server }

    /// Where a recording may be recognised, or nil when it may not be at all.
    /// On the device whenever that is possible. Apple's servers only when the
    /// device can't and they have been allowed: it used to go to them quietly
    /// whenever the device couldn't, automatic transcription included, while
    /// the app said "on this device".
    static func route(supportsOnDevice: Bool, allowServer: Bool) -> Route? {
        if supportsOnDevice { return .onDevice }
        return allowServer ? .server : nil
    }

    /// Transcribe one audio file to text, on this device (see `route`).
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
        guard let route = route(supportsOnDevice: recognizer.supportsOnDeviceRecognition,
                                allowServer: UserDefaults.standard.bool(forKey: allowServerKey)) else {
            throw TranscriptionError.onDeviceUnavailable
        }
        request.requiresOnDeviceRecognition = route == .onDevice
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
/// Saver tally: each device owns one `.quire/transcribed-<id>.json`, the union
/// is consulted, so a memo transcribed on any device is skipped everywhere.
extension JournalStore {
    static let autoTranscribeKey = "autoTranscribe"

    private struct TranscribedRecord: Codable { var assets: [String] = [] }

    func transcribedAssetIDs() -> Set<String> {
        do {
            let records = try sidecarRecords(prefix: "transcribed-").map { try JSONDecoder().decode(TranscribedRecord.self, from: $0) }
            return Set(records.flatMap(\.assets))
        } catch { lastWriteError = journalErrorMessage(error); return [] }
    }
    func markTranscribed(assetID: String) {
        do {
            let name = "transcribed-\(deviceRecordID).json"
            var record = try readSidecar(name: name).map { try JSONDecoder().decode(TranscribedRecord.self, from: $0) } ?? TranscribedRecord()
            guard !record.assets.contains(assetID) else { return }
            record.assets.append(assetID)
            try writeSidecar(name: name, data: JSONEncoder().encode(record))
        } catch { lastWriteError = journalErrorMessage(error) }
    }

    /// Sweep the whole journal for voice memos no device has transcribed yet
    /// and insert each transcript beneath its link, file by file. Serial (one
    /// recognition at a time) with the same progress row the media compressor
    /// uses. Returns (transcribed, failed).
    @discardableResult
    func transcribeAllMemos() async -> (done: Int, failed: Int) {
        guard let base = baseURL else { return (0, 0) }
        let already = transcribedAssetIDs()
        // The sweep reads every file in the journal: off the main actor, on a
        // journal handle of its own (it used to hold the app still meanwhile).
        let work: [(file: URL, path: String)] = await Task.detached(priority: .userInitiated) {
            let core = CoreJournal(base: base)
            guard let files: [String] = try? core.call("files") else { return [] }
            var found: [(file: URL, path: String)] = []
            for rel in files {
                guard let content = try? core.text(rel) else { continue }
                for path in Transcriber.audioPaths(in: content) {
                    let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    if !already.contains(id) { found.append((base.appendingPathComponent(rel), path)) }
                }
            }
            return found
        }.value
        guard baseURL == base, !work.isEmpty else { return (0, 0) }

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
                guard let fresh = try? readContentFile(item.file),
                      fresh.contains("](\(item.path))") else { continue }
                guard rewriteContentFile(item.file,
                    Transcriber.insert(transcript: transcript, after: item.path, in: fresh), replacing: fresh) else { failed += 1; continue }
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
