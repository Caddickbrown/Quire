import Foundation

/// The only journal filesystem implementation used by Rust on Apple. The
/// folder's security-scoped access is owned by JournalStore for this lifetime.
/// No local_path is exposed: transcoding and backup remain native operations.
final class AppleVault: NativeVault, @unchecked Sendable {
    let base: URL
    private let fm = FileManager.default
    /// The folder's real path, with symlinks resolved — worked out once: every
    /// call checks its path against it, and resolving it each time was a
    /// noticeable share of the cost of reading a journal.
    private let rootPath: String
    /// Whether the folder is inside the app's own container (not iCloud), where
    /// files are plain local files and nothing needs coordinating.
    private let baseIsInAppContainer: Bool
    init(base: URL) {
        self.base = base.standardizedFileURL
        let root = self.base.resolvingSymlinksInPath().path
        rootPath = root
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        baseIsInAppContainer = root.hasPrefix(home + "/") && !root.contains("/Mobile Documents/")
    }

    /// Directories already checked to be real (no symlink anywhere in their
    /// path) and inside the journal folder, so a folder of hundreds of day
    /// files is verified once and not once per file.
    private let verifiedLock = NSLock()
    private var verifiedDirectories = Set<String>()

    private func url(_ rel: String) throws -> URL {
        guard !rel.hasPrefix("/"), !rel.contains("\\"), !rel.contains("\0"),
              !rel.split(separator: "/").contains("..") else { throw failure("Invalid journal path") }
        let url = rel.isEmpty ? base : base.appendingPathComponent(rel).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        verifiedLock.lock(); let known = verifiedDirectories.contains(parent.path); verifiedLock.unlock()
        // The folder is known-good; only the item itself could still be a link.
        if known, (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil { return url }
        let root = rootPath
        let resolved = try resolvedPath(url)
        guard resolved == root || resolved.hasPrefix(root + "/") else { throw failure("Path leaves the journal folder") }
        if let resolvedParent = try? resolvedPath(parent), resolvedParent == parent.path,
           resolvedParent == root || resolvedParent.hasPrefix(root + "/") {
            verifiedLock.lock(); verifiedDirectories.insert(parent.path); verifiedLock.unlock()
        }
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
    /// Read the file. Coordinating a read, or asking iCloud about it first, costs
    /// milliseconds a file (about 25 ms on a file-provider folder), which made a
    /// journal of a few thousand entries take most of a minute to open. Nook
    /// just read the file, and so does this: iCloud is only consulted when the
    /// file turns out not to be there.
    func read(rel: String) throws -> Data? {
        let target = try url(rel)
        do { return try Data(contentsOf: target) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // Missing: an evicted iCloud document must not be mistaken for a
            // file that doesn't exist.
            let placeholder = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".icloud")
            if fm.fileExists(atPath: placeholder.path) {
                try fm.startDownloadingUbiquitousItem(at: target)
                throw failure("Journal files are downloading from iCloud. Try again shortly.")
            }
            if fm.isUbiquitousItem(at: target) {
                try fm.startDownloadingUbiquitousItem(at: target)
                return try coordinated(target, writing: false) { try Data(contentsOf: $0) }
            }
            return nil
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
    /// Run a read without file coordination, reporting errors as the bridge's.
    private func plain<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as BridgeError { throw error } catch { throw failure(error.localizedDescription) }
    }
    func list(rel: String) throws -> [VaultItem] {
        let target = try url(rel)
        guard fm.fileExists(atPath: target.path) else { return [] }
        return try plain { 
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
