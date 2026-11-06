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
    /// Normalised (see `normalised`), and worked out again if a path doesn't
    /// match it, because a folder that didn't exist yet resolves differently.
    private var rootPath: String
    /// Whether the folder was itself a symlink when opened. A link appearing
    /// there later is a swap, and the root isn't re-resolved through it.
    private let baseWasLink: Bool
    init(base: URL) {
        self.base = base.standardizedFileURL
        rootPath = Self.normalised(self.base.resolvingSymlinksInPath().path)
        baseWasLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: self.base.path)) != nil
    }

    /// /var, /tmp and /etc are links to /private/…, and Foundation gives either
    /// spelling depending on whether the path exists yet. They name the same
    /// place, so paths are compared with the prefix taken off.
    private static func normalised(_ path: String) -> String {
        for top in ["/private/var", "/private/tmp", "/private/etc"] where path == top || path.hasPrefix(top + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// Whether a resolved path is in the journal folder. On a mismatch the root
    /// is resolved again, in case it was worked out before the folder existed.
    private func isInsideRoot(_ resolved: String) -> Bool {
        let path = Self.normalised(resolved)
        verifiedLock.lock(); defer { verifiedLock.unlock() }
        if Self.isInside(path, rootPath) { return true }
        if !baseWasLink, (try? fm.destinationOfSymbolicLink(atPath: base.path)) != nil { return false }
        let fresh = Self.normalised(base.resolvingSymlinksInPath().path)
        guard fresh != rootPath else { return false }
        rootPath = fresh
        verifiedDirectories.removeAll()
        return Self.isInside(path, fresh)
    }

    /// Directories already checked to be real (no symlink anywhere in their
    /// path) and inside the journal folder, so a folder of hundreds of day
    /// files is verified once and not once per file.
    private let verifiedLock = NSLock()
    private var verifiedDirectories = Set<String>()

    private func url(_ rel: String) throws -> URL {
        guard !rel.hasPrefix("/"), !rel.contains("\\"), !rel.contains("\0"),
              !rel.split(separator: "/").contains("..") else { throw failure("Invalid journal path") }
        // Checked on every call, cached folders included: a folder that has gone
        // (a drive removed, a folder moved) must never read as an empty journal,
        // or be made again by a write.
        guard fm.fileExists(atPath: base.path) else {
            throw failure("The journal folder can't be reached. Check that its drive or iCloud is available.")
        }
        let url = rel.isEmpty ? base : base.appendingPathComponent(rel).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        verifiedLock.lock(); let known = verifiedDirectories.contains(parent.path); verifiedLock.unlock()
        // The folder was checked; the item, and the folder itself (a sync can
        // replace a folder with a link after it was cached), could still be links.
        if known, (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
           (try? fm.destinationOfSymbolicLink(atPath: parent.path)) == nil { return url }
        let resolved = try resolvedPath(url)
        guard isInsideRoot(resolved) else { throw failure("Path leaves the journal folder") }
        if let resolvedParent = try? resolvedPath(parent),
           Self.normalised(resolvedParent) == Self.normalised(parent.path), isInsideRoot(resolvedParent) {
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
        try coordinated(target, writing: true) { try self.replace($0, with: bytes) }
    }
    private func replace(_ target: URL, with bytes: Data) throws {
        let temp = target.deletingLastPathComponent().appendingPathComponent(".quire-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temp) }
        try bytes.write(to: temp)
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temp) }
        else { try fm.moveItem(at: temp, to: target) }
    }
    /// The core's compare-and-swap. The read happens inside the same write
    /// coordination as the swap, so iCloud and every other coordinated writer
    /// (the app, an intent, the share extension) wait for it: nothing can land
    /// between the compare and the replace. This is the writing path only; the
    /// plain read above stays uncoordinated and fast. `.forMerging` is the
    /// option for a read-then-write, and has iCloud bring the file up to date.
    func replaceIfUnchanged(rel: String, expected: Data?, bytes: Data?) throws -> Bool {
        let target = try url(rel)
        if bytes != nil { try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true) }
        return try coordinated(target, writing: true, options: bytes == nil ? .forDeleting : .forMerging) { target in
            // Evicted: the real file is missing but its content isn't gone, so
            // "no file" must not be taken for what the caller expected.
            let placeholder = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".icloud")
            if self.fm.fileExists(atPath: placeholder.path) {
                try self.fm.startDownloadingUbiquitousItem(at: target)
                throw self.failure("Journal files are downloading from iCloud. Try again shortly.")
            }
            let current: Data?
            do { current = try Data(contentsOf: target) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { current = nil }
            guard current == expected else { return false }
            if let bytes { try self.replace(target, with: bytes) }
            else if current != nil { try self.fm.removeItem(at: target) }
            return true
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
