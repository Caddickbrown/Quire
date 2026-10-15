import Foundation

/// Values at the Rust boundary. `file`, `index` and `raw` are kept together;
/// the core refuses stale edits and relocates an entry when its index moves.
struct CoreEntry: Decodable {
    let file: String
    let index: Int
    let source: String
    let split: String?
    let ts: String
    let date: String
    let title: String
    let starred: Bool
    let body: String
    let raw: String

    var entry: Entry {
        Entry(file: file, fileIndex: index, date: date, ts: ts,
              suffix: title.isEmpty ? (starred ? "*" : "") : title + (starred ? " *" : ""),
              body: body, raw: raw)
    }
}

struct CoreWritten: Decodable { let file: String; let index: Int; let raw: String }

final class CoreJournal: @unchecked Sendable {
    private let journal: NativeJournal
    init(base: URL) { journal = NativeJournal(vault: AppleVault(base: base)) }

    func call<T: Decodable>(_ op: String, _ fields: [String: Any] = [:], as: T.Type = T.self) throws -> T {
        var request = fields
        request["op"] = op
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let response = try journal.execute(request: String(decoding: data, as: UTF8.self))
        return try JSONDecoder().decode(T.self, from: Data(response.utf8))
    }
    func load() throws -> [CoreEntry] { try call("load") }
    func inbox() throws -> [CoreEntry] { try call("inbox") }
    func migrate() throws { let _: Bool = try call("migrate") }
    func reference(_ entry: Entry) throws -> [String: Any] {
        guard let file = entry.file, let index = entry.fileIndex else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "This entry has no journal location. Reload it before editing."])
        }
        return ["file": file, "index": index, "raw": entry.raw]
    }
    func update(_ entry: Entry, text: String) throws -> CoreWritten {
        // Escape any extra header before parsing, so a one-entry editor cannot
        // silently discard the body after a pasted timestamp.
        let guarded = text.components(separatedBy: "\n").enumerated().map { i, line in
            i > 0 && headerLine(line: line) ? "\\" + line : line
        }.joined(separator: "\n")
        guard let edited = JournalParser.parseEntries(guarded).first else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "An entry needs a timestamp header."])
        }
        var fields = try reference(entry)
        fields["ts"] = edited.ts; fields["title"] = edited.suffix; fields["body"] = edited.body
        return try call("update", fields)
    }
    func delete(_ entry: Entry) throws { let _: Bool = try call("delete", reference(entry)) }
    func text(_ rel: String) throws -> String { try call("read", ["file": rel]) }
    func write(_ rel: String, _ content: String) throws { let _: Bool = try call("write", ["file": rel, "content": content]) }
    func sidecar(write: Bool = false) throws -> String { try call("sidecar", ["write": write]) }
}

func journalErrorMessage(_ error: Error) -> String {
    if let bridge = error as? BridgeError {
        switch bridge { case .Failure(let message): return message }
    }
    return error.localizedDescription
}
