import Foundation

/// The only journal filesystem implementation used by Rust on Apple. The
/// folder's security-scoped access is owned by JournalStore for this lifetime.
/// No local_path is exposed: transcoding and backup remain native operations.
final class AppleVault: NativeVault, @unchecked Sendable {
    let base: URL
    private let fm = FileManager.default
    init(base: URL) { self.base = base.standardizedFileURL }

    private func url(_ rel: String) throws -> URL {
        guard !rel.hasPrefix("/"), !rel.contains("\\"), !rel.contains("\0"),
              !rel.split(separator: "/").contains("..") else { throw failure("Invalid journal path") }
        let url = rel.isEmpty ? base : base.appendingPathComponent(rel).standardizedFileURL
        let root = base.resolvingSymlinksInPath().path
        let resolved = try resolvedPath(url)
        guard resolved == root || resolved.hasPrefix(root + "/") else { throw failure("Path leaves the journal folder") }
        return url
    }

    /// `url` with every symlink resolved, including in a path whose last parts
    /// don't exist yet. Foundation leaves such a path unresolved, so a new file
    /// under a symlinked folder ("escape/new.md", escape → outside) would pass
    /// the check above. Resolves the deepest part that exists and re-appends
    /// the rest; a dangling symlink is refused, since writing through it would
    /// create its target wherever it points.
    private func resolvedPath(_ url: URL) throws -> String {
        var existing = url
        var tail: [String] = []
        while !fm.fileExists(atPath: existing.path) {
            if (try? fm.destinationOfSymbolicLink(atPath: existing.path)) != nil {
                throw failure("Path leaves the journal folder")
            }
            guard existing.pathComponents.count > 1 else { break }
            tail.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.path
    }
    private func failure(_ message: String) -> BridgeError { .Failure(message: message) }
    private func coordinated<T>(_ url: URL, writing: Bool, options: NSFileCoordinator.WritingOptions = .forReplacing, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { target in
                result = Result { try body(target) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
                result = Result { try body(target) }
            }
        }
        if let coordinationError { throw failure(coordinationError.localizedDescription) }
        guard let result else { throw failure("File coordination did not complete") }
        do { return try result.get() } catch { throw failure(error.localizedDescription) }
    }
    func read(rel: String) throws -> Data? {
        let target = try url(rel)
        if !fm.fileExists(atPath: target.path) && !fm.isUbiquitousItem(at: target) {
            let placeholder = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try fm.startDownloadingUbiquitousItem(at: target)
                throw failure("Journal files are downloading from iCloud. Try again shortly.")
            }
            return nil
        }
        // An evicted iCloud document must not be mistaken for a missing file.
        if fm.isUbiquitousItem(at: target) { try fm.startDownloadingUbiquitousItem(at: target) }
        return try coordinated(target, writing: false) { target in
            do { return try Data(contentsOf: target) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                if self.fm.isUbiquitousItem(at: target) { throw error }
                return nil
            }
        }
    }
    func write(rel: String, bytes: Data) throws {
        let target = try url(rel)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coordinated(target, writing: true) { target in
            let temp = target.deletingLastPathComponent().appendingPathComponent(".quire-\(UUID().uuidString).tmp")
            defer { try? self.fm.removeItem(at: temp) }
            try bytes.write(to: temp)
            if self.fm.fileExists(atPath: target.path) { _ = try self.fm.replaceItemAt(target, withItemAt: temp) }
            else { try self.fm.moveItem(at: temp, to: target) }
        }
    }
    func remove(rel: String) throws -> Bool {
        let target = try url(rel)
        guard fm.fileExists(atPath: target.path) else { return false }
        return try coordinated(target, writing: true, options: .forDeleting) { target in
            do { try self.fm.removeItem(at: target); return true }
            catch let error as CocoaError where error.code == .fileNoSuchFile { return false }
        }
    }
    func rename(from: String, to: String) throws {
        let source = try url(from), destination = try url(to)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var error: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forMoving,
            writingItemAt: destination, options: .forReplacing, error: &error) { a, b in
                result = Result { try self.fm.moveItem(at: a, to: b) }
            }
        if let error { throw failure(error.localizedDescription) }
        guard let result else { throw failure("Rename coordination did not complete") }
        do { try result.get() } catch { throw failure(error.localizedDescription) }
    }
    func list(rel: String) throws -> [VaultItem] {
        let target = try url(rel)
        guard fm.fileExists(atPath: target.path) else { return [] }
        return try coordinated(target, writing: false) { target in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let items: [URL]
            do { items = try self.fm.contentsOfDirectory(at: target, includingPropertiesForKeys: Array(keys)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
            return try items.map { item in
                let v = try item.resourceValues(forKeys: keys)
                // Ask iCloud to materialize placeholders, and fail this snapshot
                // rather than publishing an incomplete journal as if it is empty.
                if item.pathExtension == "icloud" {
                    try self.fm.startDownloadingUbiquitousItem(at: item)
                    throw self.failure("Journal files are downloading from iCloud. Try again shortly.")
                }
                let link = v.isSymbolicLink == true
                return VaultItem(name: item.lastPathComponent, isDir: !link && v.isDirectory == true,
                                 isFile: !link && v.isRegularFile == true, len: UInt64(max(0, v.fileSize ?? 0)))
            }.sorted { $0.name < $1.name }
        }
    }
    func isDir(rel: String) -> Bool { (try? url(rel).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    func isFile(rel: String) -> Bool { (try? url(rel).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    func len(rel: String) -> UInt64 { UInt64(max(0, (try? url(rel).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
    func modified(rel: String) -> UInt64? {
        guard let date = try? url(rel).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return UInt64(max(0, date.timeIntervalSince1970))
    }
}
