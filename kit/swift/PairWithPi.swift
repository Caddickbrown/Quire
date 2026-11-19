// "Pair with the Pi": the phone's half of the pairing protocol (docs/DEVICES.md, sections 1 and 2).
// The app shows a code, Dan approves it on the server's Devices page (or, at the address the app is
// already set up with, approves itself with the main token it holds), and the app's next poll collects a
// key made for this phone alone. KitPairPolicy says who may get what: a server found on the Wi-Fi never
// gets the main token, and every code pairing is confirmed on the phone before the key is kept.
//
// This file is the part with no UI: the client for /.well-known/pair and /api/pair/*, the Keychain
// item, the certificate pin and the Bonjour browser. PairWithPiView.swift is the flow on screen.
//
//   let pairing = KitPairingStore.load(service: "com.caddickbrown.Pala.pairing")
//   request.setValue("Bearer \(pairing?.key ?? mainToken)", forHTTPHeaderField: "Authorization")
//   // in the app's URLSession delegate:
//   let (d, c) = KitCertPin.decide(challenge, pinned: pairing?.certSHA256, unpinned: oldBehaviour)
//
// The key is sent only as `Authorization: Bearer`. The leaf certificate the TLS handshake presented is
// hashed (SHA-256 of its DER bytes) while pairing and pinned with the key; a different certificate later
// is refused, never silently accepted. Plain-HTTP servers (an IP on the LAN) have no certificate to pin.

import CryptoKit
import Foundation
import Security
#if canImport(Network)
import Network
#endif

/// What `GET /.well-known/pair` says about a server.
nonisolated struct KitPairService: Decodable, Equatable {
    let service: String
    let name: String
    let version: String?
    let pair: String?
    let kinds: [String]?
    let cert_sha256: String?
}

/// What `POST /api/pair/start` gives back.
nonisolated struct KitPairStart: Decodable, Equatable {
    let code: String
    let token: String
    let expires_in: Int
    let url: String?
    let say: String?
}

/// One poll's answer.
nonisolated enum KitPollResult: Equatable {
    case waiting(expiresIn: Int)
    case paired(key: String, deviceID: Int?, deviceName: String, scopes: [String])
    case gone
}

/// What the phone keeps, in one Keychain item per server.
nonisolated struct KitPairing: Codable, Equatable {
    var address: String
    var key: String
    var certSHA256: String?
    var deviceID: Int?
    var deviceName: String
    var scopes: [String]
    var pairedAt: Date
    var serviceName: String

    func allows(_ scope: String) -> Bool { scopes.contains(scope) }
}

nonisolated enum KitPairError: LocalizedError, Equatable {
    case badAddress
    case unreachable(String)
    case tooOld(String)
    case wrongService(expected: String, found: String)
    case notTheSameServer
    case certificateChanged(String)
    case expired
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "That doesn't look like an address. Try 192.168.4.185:8960."
        case .unreachable(let name): return "Can't reach \(name). Check you're on the home Wi-Fi, then try again."
        case .tooOld(let name): return "\(name) on this server is too old to pair. Use the token under Advanced."
        case .wrongService(let expected, let found): return "That address is \(found), not \(expected)."
        case .notTheSameServer: return "This isn't the server the code came from."
        case .certificateChanged(let name):
            return "\(name)'s certificate has changed. If you renewed it, pair again."
        case .expired: return "That code ran out."
        case .refused(let why): return why
        }
    }
}

/// The words every app uses for a paired key that stops working (docs/DEVICES.md, Offline and errors).
nonisolated enum KitPairWords {
    static func removed(_ service: String, device: String = KitPairDevice.noun) -> String {
        "This \(device) was removed from \(service)."
    }
    static func notAllowed(_ service: String, what: String, device: String = KitPairDevice.noun) -> String {
        "This \(device) can't \(what). Allow it on \(service)'s Devices page."
    }
    static func paired(_ service: String, can: String, device: String = KitPairDevice.noun) -> String {
        "Paired with \(service). This \(device) can \(can)."
    }
}

nonisolated enum KitPairDevice {
    /// The hardware id, e.g. iPhone16,1, for the approve page's "Asking" line.
    static var model: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    /// This device's IPv4 address on the Wi-Fi (en0), for comparing with the "From" line on the
    /// server's /pair page. nil when there isn't one.
    static var wifiAddress: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found = String(cString: host)
                break
            }
        }
        return found
    }

    /// "iPhone", "iPad" or "Mac".
    static var noun: String {
        #if os(iOS)
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
        #else
        return "Mac"
        #endif
    }
}

// MARK: - Addresses

nonisolated enum KitPairAddress {
    /// "192.168.4.185:8960" -> http(s)://192.168.4.185:8960, with the app's usual scheme when none is typed.
    /// Trailing slashes and spaces go. nil for something that can't be an address.
    /// With `defaultPort`, an address typed without a port gets the app's usual one (192.168.4.185 -> :8915).
    static func normalise(_ typed: String, defaultScheme: String = "https", defaultPort: Int? = nil) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "\(defaultScheme)://\(text)" }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty else { return nil }
        if parts.port == nil, let defaultPort { parts.port = defaultPort }
        return parts.url
    }

    /// The first 16 hex characters, in four groups, for comparing by eye with the Devices page.
    static func shortHash(_ hex: String?) -> String? {
        guard let hex, hex.count >= 16 else { return nil }
        let s = Array(hex.prefix(16))
        return stride(from: 0, to: 16, by: 4).map { String(s[$0..<$0 + 4]) }.joined(separator: " ")
    }
}

// MARK: - Who may get what (review K1, 18 Nov)

/// Where the address being paired came from.
nonisolated enum KitPairOrigin: Equatable {
    /// Listed under "On this Wi-Fi". Anything on the Wi-Fi can advertise, so it's untrusted.
    case discovered
    /// Typed by the person.
    case typed
    /// The address the app is already set up with (KitPairConfig.defaultAddress), where it sends its token.
    case configured
}

nonisolated enum KitPairPlan: Equatable {
    /// Approve the code with the main token ("Pair this iPhone instead").
    case selfApprove
    /// Show the code; it's approved on the server's /pair page and confirmed on the phone before the key is kept.
    case code
    case refuse(String)
}

/// The rules that keep a rogue device on the Wi-Fi from getting the main token or a key:
/// - a Bonjour entry never gets the main token and is never self-approved; its TXT can't set the scheme
///   or the expected certificate;
/// - "Pair this iPhone instead" works only at the configured address, after the token has been seen to
///   work there;
/// - every code pairing ends with the phone asking whether its certificate and address matched the
///   /pair page before the key is kept.
nonisolated enum KitPairPolicy {
    /// A Bonjour result as a list entry, or nil when it's not this app's service. The scheme is the
    /// app's own (the TXT `scheme` is ignored), and the TXT `cert` is not carried: the advertiser chose it.
    static func candidate(name: String, txt: [String: String], service: String, host: String, port: UInt16,
                          appScheme: String) -> KitPairCandidate? {
        guard txt["service"] == service else { return nil }
        var h = host
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.contains(":") { h = "[\(h)]" }
        let scheme = appScheme.lowercased() == "http" ? "http" : "https"
        return KitPairCandidate(name: name, address: "\(scheme)://\(h):\(port)")
    }

    /// The certificate hash a pairing session expects before it has seen one. Never from a TXT record.
    static func expectedCert(origin: KitPairOrigin, hint: String?) -> String? {
        origin == .discovered ? nil : hint
    }

    /// The pin a pairing session holds the server to, given the certificate this app already trusts at its
    /// configured address (`KitPairConfig.trustedCert`, e.g. Shelf's seed pin). It applies whenever the session
    /// is going to that server, typed, configured or found on the Wi-Fi, so pairing never accepts less than the
    /// app's normal requests would. Another server, plain http, or no pin held: nil (review K2, 18 Nov).
    static func expectedCert(address: URL, configured: URL?, trusted: String?) -> String? {
        guard let trusted = trusted?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trusted.isEmpty,
              address.scheme?.lowercased() == "https", let configured, sameServer(address, configured) else { return nil }
        return trusted
    }

    /// Both rules together: the app's pin at its configured server, else a QR's hint (never a TXT's).
    static func expectedCert(origin: KitPairOrigin, hint: String?, address: URL, configured: URL?, trusted: String?) -> String? {
        expectedCert(address: address, configured: configured, trusted: trusted) ?? expectedCert(origin: origin, hint: hint)
    }

    /// What the phone says when the server's certificate isn't the one the app already trusts.
    static func pinMismatch(server: String) -> String {
        "\(server) at this address showed a different certificate from the one this app trusts, so nothing was sent. If you renewed the certificate, update it in the app first; otherwise something on this Wi-Fi may be posing as \(server)."
    }

    static func sameServer(_ a: URL, _ b: URL) -> Bool {
        KitPairFallback.server(a) == KitPairFallback.server(b)
    }

    static func plan(origin: KitPairOrigin, address: URL, configured: URL?, hasToken: Bool, selfApprove: Bool) -> KitPairPlan {
        guard selfApprove else { return .code }
        guard origin == .configured, let configured, sameServer(address, configured) else {
            return .refuse("The token only goes to the address this app is set up with. Show a pairing code instead.")
        }
        guard hasToken else { return .refuse("There's no token saved in this app. Show a pairing code instead.") }
        return .selfApprove
    }

    /// `GET /api/paired` with the main token: only a 200 shows the token works at that address.
    static func tokenCheckPassed(status: Int) -> Bool { status == 200 }
}

// MARK: - The certificate pin

nonisolated enum KitCertPin {
    /// SHA-256 of the leaf certificate's DER bytes, lower-case hex.
    static func leafSHA256(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return sha256Hex(SecCertificateCopyData(leaf) as Data)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// For an app's URLSession delegate. With a pin: that certificate and no other. Without one (not
    /// paired yet, or paired over plain HTTP): whatever the app did before, passed as `unpinned`.
    static func decide(_ challenge: URLAuthenticationChallenge, pinned: String?,
                       unpinned: (URLSession.AuthChallengeDisposition, URLCredential?)) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard let pinned, !pinned.isEmpty else { return unpinned }
        guard let seen = leafSHA256(trust), seen == pinned.lowercased() else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// True when a failed request was refused by the pin (so the app can say the certificate changed).
    static func isPinFailure(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return code == NSURLErrorCancelled || code == NSURLErrorServerCertificateUntrusted
            || code == NSURLErrorSecureConnectionFailed
    }
}

/// The session pairing runs on: it accepts the server's self-signed certificate (that's what is being
/// paired with), remembers the hash the handshake presented, and refuses any other once one is seen
/// or expected.
nonisolated final class KitPairSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: String?
    private var _refusedExpected = false
    private let expected: String?

    init(expected: String?) { self.expected = expected?.lowercased() }

    var seen: String? { lock.lock(); defer { lock.unlock() }; return _seen }
    /// True once the handshake showed a certificate other than the expected one.
    var refusedExpected: Bool { lock.lock(); defer { lock.unlock() }; return _refusedExpected }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust, let hash = KitCertPin.leafSHA256(trust) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        lock.lock()
        let earlier = _seen
        if _seen == nil { _seen = hash }
        lock.unlock()
        // A QR may carry only the first 16 hex characters. A Bonjour TXT never sets this (KitPairPolicy).
        let notExpected = expected.map { !hash.hasPrefix($0) } ?? false
        let mismatch = (earlier.map { $0 != hash } ?? false) || notExpected
        if notExpected { lock.lock(); _refusedExpected = true; lock.unlock() }
        if mismatch {
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

// MARK: - The client

nonisolated struct KitPairClient {
    let base: URL
    let expectedService: String
    let serviceName: String
    let delegate: KitPairSessionDelegate
    let session: URLSession

    /// `expectedCert` is a hash from a QR or an earlier pin, never from a Bonjour TXT.
    init(base: URL, service: String, name: String, expectedCert: String? = nil) {
        self.base = base
        self.expectedService = service
        self.serviceName = name
        delegate = KitPairSessionDelegate(expected: expectedCert)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// The certificate hash the handshake presented, nil over plain HTTP.
    var certSHA256: String? { delegate.seen }

    private func url(_ path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + path)!
    }

    private func send(_ path: String, body: [String: Any]? = nil, bearer: String? = nil,
                      timeout: TimeInterval = 10) async throws -> (Int, Data) {
        var req = URLRequest(url: url(path), timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled, delegate.refusedExpected {
                throw KitPairError.refused(KitPairPolicy.pinMismatch(server: serviceName))
            }
            if (error as NSError).code == NSURLErrorCancelled, delegate.seen != nil { throw KitPairError.notTheSameServer }
            throw KitPairError.unreachable(serviceName)
        }
    }

    static func message(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    /// Checks the address is this app's server and can pair.
    func service() async throws -> KitPairService {
        let (status, data) = try await send("/.well-known/pair")
        guard status == 200, let info = try? JSONDecoder().decode(KitPairService.self, from: data) else {
            throw KitPairError.tooOld(serviceName)
        }
        guard info.service == expectedService else {
            throw KitPairError.wrongService(expected: serviceName, found: info.name)
        }
        if let claimed = info.cert_sha256?.lowercased(), !claimed.isEmpty, let seen = certSHA256, claimed != seen {
            throw KitPairError.notTheSameServer
        }
        return info
    }

    func start(name: String) async throws -> KitPairStart {
        let body: [String: Any] = ["kind": "app", "model": KitPairDevice.model, "name": name]
        let (status, data) = try await send("/api/pair/start", body: body)
        guard status == 200, let start = try? JSONDecoder().decode(KitPairStart.self, from: data) else {
            throw KitPairError.refused(Self.message(data) ?? "\(serviceName) didn't start pairing (\(status)).")
        }
        return start
    }

    func poll(token: String, wait: Int = 25) async throws -> KitPollResult {
        let (status, data) = try await send("/api/pair/poll?wait=\(wait)", bearer: token, timeout: TimeInterval(wait + 10))
        return try Self.pollResult(status: status, data: data, name: serviceName)
    }

    static func pollResult(status: Int, data: Data, name: String) throws -> KitPollResult {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 202: return .waiting(expiresIn: obj["expires_in"] as? Int ?? 0)
        case 410: return .gone
        case 200:
            guard let key = obj["key"] as? String, !key.isEmpty else { throw KitPairError.refused("\(name) sent no key.") }
            let device = obj["device"] as? [String: Any] ?? [:]
            return .paired(key: key, deviceID: device["id"] as? Int, deviceName: device["name"] as? String ?? "",
                           scopes: obj["scopes"] as? [String] ?? [])
        default:
            throw KitPairError.refused(message(data) ?? "\(name) answered \(status).")
        }
    }

    /// Before "Pair this iPhone instead": the token has to work here already (a signed-in list of paired
    /// devices), so a server that doesn't know it never gets asked to approve.
    func tokenWorks(_ bearer: String) async throws -> Bool {
        let (status, _) = try await send("/api/paired", bearer: bearer)
        return KitPairPolicy.tokenCheckPassed(status: status)
    }

    /// "Pair this iPhone instead": an app that already holds the main token approves its own code.
    func approve(code: String, name: String, bearer: String) async throws {
        let (status, data) = try await send("/api/pair/approve", body: ["code": code, "kind": "app", "name": name], bearer: bearer)
        guard status == 200 else {
            if status == 401 { throw KitPairError.refused("\(serviceName) didn't accept the token, so it can't approve this \(KitPairDevice.noun). Approve the code on the Devices page instead.") }
            throw KitPairError.refused(Self.message(data) ?? "\(serviceName) answered \(status).")
        }
    }

    /// Signing out: the key stops working on the server. Errors are ignored (the phone forgets it anyway).
    func unpair(key: String) async {
        _ = try? await send("/api/device/unpair", body: [:], bearer: key)
    }
}

// MARK: - Falling back to the token

/// A paired key that gets 401 from a server that doesn't know pairing at all (an older build, or the other
/// language's server, is running on the Pi) isn't a removed phone: the app should carry on with the main
/// token it still holds, and say so. `checkAfter401` asks `/.well-known/pair` once: anything but a 200
/// naming this service (404, or 401 from a server whose token gate covers every path) means "doesn't
/// pair", and the address is remembered for this run of the app, so `credential(for:)` returns the token
/// for it. A 200 naming this service means a real revoke; no answer at all changes nothing. Nothing is
/// written to disk and nothing is wiped.
///
///   if status == 401, usedPairedKey, await KitPairFallback.checkAfter401(base: url, service: "pala") {
///       retry once with the main token; show KitPairFallback.note("Pala")
///   }
nonisolated enum KitPairFallback {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var noPairing: Set<String> = []
    /// Where the "never the token" list is kept. Not secret: server addresses only.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard
    private static let refusedKey = "kit.pair.noTokenServers"

    /// A server this phone paired with from the Wi-Fi list or a typed address that isn't the one the app
    /// is set up with: the main token never falls back to it.
    static func refuseToken(for url: URL) {
        lock.lock(); defer { lock.unlock() }
        var list = Set(defaults.stringArray(forKey: refusedKey) ?? [])
        list.insert(server(url))
        defaults.set(list.sorted(), forKey: refusedKey)
        noPairing.remove(server(url))
    }

    /// Paired at the configured address (where the token already goes): the fallback may use it again.
    static func allowToken(for url: URL) {
        lock.lock(); defer { lock.unlock() }
        var list = Set(defaults.stringArray(forKey: refusedKey) ?? [])
        list.remove(server(url))
        defaults.set(list.sorted(), forKey: refusedKey)
    }

    static func tokenRefused(for url: URL) -> Bool {
        (defaults.stringArray(forKey: refusedKey) ?? []).contains(server(url))
    }

    /// host:port, the same way for a URL and a stored address.
    static func server(_ url: URL) -> String {
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return "\(url.scheme?.lowercased() ?? "")://\((url.host ?? "").lowercased()):\(port)"
    }

    /// True once this run has found that the server at `url` doesn't pair: send the main token there.
    static func usingToken(for url: URL) -> Bool {
        if tokenRefused(for: url) { return false }
        lock.lock(); defer { lock.unlock() }
        return noPairing.contains(server(url))
    }

    static func mark(_ url: URL) {
        if tokenRefused(for: url) { return }
        lock.lock(); noPairing.insert(server(url)); lock.unlock()
    }

    /// Pairing worked again (or the phone paired anew): use the key.
    static func clear() {
        lock.lock(); noPairing.removeAll(); lock.unlock()
    }

    /// After a 401 to a paired key: true (and remembered) when the server doesn't pair at all.
    static func checkAfter401(base url: URL, service: String, session: URLSession = .shared) async -> Bool {
        if tokenRefused(for: url) { return false }
        if usingToken(for: url) { return true }
        guard let probe = URL(string: server(url) + "/.well-known/pair") else { return false }
        var req = URLRequest(url: probe, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else {
            return false
        }
        // Only a 200 naming this service means "pairs". An older server answers 404, or 401 when its
        // token gate covers every path (Hub). Using the token there is safe: it still has to be right.
        let info = http.statusCode == 200 ? try? JSONDecoder().decode(KitPairService.self, from: data) : nil
        let pairs = info?.service == service
        if !pairs { mark(url) }
        return !pairs
    }

    static func note(_ service: String, device: String = KitPairDevice.noun) -> String {
        "\(service) on the Pi doesn't pair yet, so this \(device) is using the token for now."
    }
}

// MARK: - The Keychain

nonisolated enum KitPairingStore {
    /// One item per server, never synced through iCloud and never restored to another phone:
    /// the key belongs to this phone. `accessGroup` shares it with the app's extensions.
    static func load(service: String, accessGroup: String? = nil) -> KitPairing? {
        var q = query(service, accessGroup)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(KitPairing.self, from: data)
    }

    @discardableResult
    static func save(_ pairing: KitPairing, service: String, accessGroup: String? = nil) -> Bool {
        guard let data = try? JSONEncoder().encode(pairing) else { return false }
        SecItemDelete(query(service, accessGroup) as CFDictionary)
        var add = query(service, accessGroup)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func remove(service: String, accessGroup: String? = nil) {
        SecItemDelete(query(service, accessGroup) as CFDictionary)
    }

    private static func query(_ service: String, _ group: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: "pairing"]
        if let group { q[kSecAttrAccessGroup as String] = group }
        return q
    }
}

// MARK: - Finding the server

/// A server found on the Wi-Fi.
/// Untrusted: anything on the Wi-Fi can advertise. It may only start a code pairing (KitPairPolicy).
nonisolated struct KitPairCandidate: Identifiable, Equatable {
    var id: String { address }
    let name: String
    let address: String
}

#if canImport(Network)
/// Browses `_dcbhome._tcp` for servers whose TXT says `service=<this app's service>`, and resolves each
/// to an address. Only TXT `service` is read: the scheme is the app's own and a TXT `cert` is ignored,
/// since the advertiser chooses both. Needs NSBonjourServices and NSLocalNetworkUsageDescription.
nonisolated final class KitPairBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "kit.pair.browser")

    func start(service: String, scheme: String = "https", found: @escaping @Sendable (KitPairCandidate) -> Void) {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_dcbhome._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txt) = result.metadata, txt["service"] == service else { continue }
                self?.resolve(result.endpoint, name: name, service: service, scheme: scheme, found: found)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func resolve(_ endpoint: NWEndpoint, name: String, service: String, scheme: String,
                         found: @escaping @Sendable (KitPairCandidate) -> Void) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak conn] state in
            guard case .ready = state, let conn else { return }
            if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint,
               let c = KitPairPolicy.candidate(name: name, txt: ["service": service], service: service,
                                               host: "\(host)", port: port.rawValue, appScheme: scheme) {
                found(c)
            }
            conn.cancel()
        }
        connections.append(conn)
        conn.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        connections.forEach { $0.cancel() }
        connections = []
    }
}
#endif
