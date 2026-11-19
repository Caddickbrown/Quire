// "Pair with the Pi" on screen (docs/DEVICES.md section 2): find the server, show the code, keep the key.
// Built only from system controls (Form, Button, Text) with no colours of its own, so it takes the app's
// tint and type. The app puts it behind Settings › Pair with the Pi and keeps its token field under
// Advanced as the fallback:
//
//   NavigationLink("Pair with the Pi") {
//       KitPairView(config: .init(service: "pala", name: "Pala", defaultAddress: "http://192.168.4.185:8960",
//                                 keychainService: "com.caddickbrown.Pala.pairing", can: "read and change your notes",
//                                 mainToken: { TokenStore.load() })) { pairing in store.reconnect() }
//   }
//   KitPairStatus(config: config, pairing: pairing) { store.reconnect() }   // once paired

#if canImport(SwiftUI)
import Combine
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct KitPairConfig {
    /// The service id in /.well-known/pair, e.g. "pala".
    var service: String
    /// How the app names the server, e.g. "Pala".
    var name: String
    /// The address the app is set up with (where it already sends its token), e.g.
    /// "https://192.168.4.185:8773". Prefilled in "Type an address", and the only address
    /// "Pair this iPhone instead" will send the main token to.
    var defaultAddress: String
    /// The Keychain item, e.g. "com.caddickbrown.Pala.pairing".
    var keychainService: String
    var accessGroup: String? = nil
    /// Finishes "This iPhone can …", e.g. "read and change your notes".
    var can: String
    /// The main token the app already holds, if any: offers "Pair this iPhone instead" at `defaultAddress`.
    var mainToken: () -> String? = { nil }
    /// The scheme used when an address is typed without one.
    var defaultScheme: String = "https"
    /// The port used when an address is typed without one, e.g. 8915.
    var defaultPort: Int? = nil
    /// The certificate this app already trusts at `defaultAddress` (full SHA-256 hex of the leaf, as
    /// `KitCertPin` makes it), e.g. a pin it shipped with or saved. Pairing with that server then refuses any
    /// other certificate, wherever the address came from (0.9.4, review K2). nil: trust on first use, as before.
    var trustedCert: () -> String? = { nil }
}

@MainActor
final class KitPairFlow: ObservableObject {
    enum Step: Equatable {
        case find
        case working(String)
        case showing(code: String, expires: Date, link: String?, cert: String?)
        /// The server approved the code. Before the key is kept, the person says whether the certificate and
        /// address the phone showed matched the /pair page.
        case confirm(KitPairing, cert: String?)
        case done(KitPairing)
        case failed(String, canRetry: Bool)
    }

    @Published var step: Step = .find
    @Published var found: [KitPairCandidate] = []
    let config: KitPairConfig
    private var task: Task<Void, Never>?
    private var pending: (pairing: KitPairing, origin: KitPairOrigin, onPaired: (KitPairing) -> Void)?
    #if canImport(Network)
    private let browser = KitPairBrowser()
    #endif

    init(config: KitPairConfig) { self.config = config }

    func browse() {
        #if canImport(Network)
        browser.start(service: config.service, scheme: config.defaultScheme) { [weak self] candidate in
            Task { @MainActor in
                guard let self, !self.found.contains(candidate) else { return }
                self.found.append(candidate)
            }
        }
        #endif
    }

    func stop() {
        task?.cancel()
        task = nil
        #if canImport(Network)
        browser.stop()
        #endif
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
        step = .find
    }

    var configuredAddress: URL? {
        KitPairAddress.normalise(config.defaultAddress, defaultScheme: config.defaultScheme, defaultPort: config.defaultPort)
    }

    /// The person saw the same certificate and address on the /pair page: keep the key.
    func keep() {
        guard let p = pending, case .confirm = step else { return }
        pending = nil
        save(p.pairing, origin: p.origin, onPaired: p.onPaired)
    }

    /// They didn't match: the key is dropped and never used. The server still lists the entry, so say
    /// to remove it there.
    func reject() {
        guard let p = pending else { return }
        pending = nil
        step = .failed("Not paired. Something on this Wi-Fi may be posing as \(config.name). On \(config.name)'s Devices page, revoke \"\(p.pairing.deviceName)\" from \(p.pairing.pairedAt.formatted(date: .omitted, time: .shortened)), then pair again by typing the address.", canRetry: true)
    }

    private func save(_ pairing: KitPairing, origin: KitPairOrigin, onPaired: (KitPairing) -> Void) {
        guard KitPairingStore.save(pairing, service: config.keychainService, accessGroup: config.accessGroup) else {
            step = .failed("Couldn't save the key in the Keychain. Try again.", canRetry: true)
            return
        }
        KitPairFallback.clear()
        if let url = URL(string: pairing.address) {
            // The token fallback only ever goes where the token already went.
            if let configured = configuredAddress, KitPairPolicy.sameServer(url, configured) {
                KitPairFallback.allowToken(for: url)
            } else {
                KitPairFallback.refuseToken(for: url)
            }
        }
        step = .done(pairing)
        onPaired(pairing)
    }

    /// Shows a code for Dan to approve on the server's /pair page, or, with `selfApprove` at the configured
    /// address, approves it with the main token. `origin` says where the address came from (KitPairPolicy).
    func pair(address: String, origin: KitPairOrigin = .typed, selfApprove: Bool = false,
              onPaired: @escaping (KitPairing) -> Void) {
        task?.cancel()
        pending = nil
        let config = self.config
        let configured = configuredAddress
        task = Task { [weak self] in
            guard let self else { return }
            guard let base = KitPairAddress.normalise(address, defaultScheme: config.defaultScheme, defaultPort: config.defaultPort) else {
                self.step = .failed(KitPairError.badAddress.localizedDescription, canRetry: false)
                return
            }
            let token = config.mainToken() ?? ""
            let plan = KitPairPolicy.plan(origin: origin, address: base, configured: configured,
                                          hasToken: !token.isEmpty, selfApprove: selfApprove)
            if case let .refuse(why) = plan {
                self.step = .failed(why, canRetry: true)
                return
            }
            let client = KitPairClient(base: base, service: config.service, name: config.name,
                                       expectedCert: KitPairPolicy.expectedCert(origin: origin, hint: nil, address: base,
                                                                             configured: configured, trusted: config.trustedCert()))
            let device = KitPairDevice.noun
            do {
                self.step = .working("Checking \(base.host ?? address)…")
                let info = try await client.service()
                if plan == .selfApprove {
                    // The token has to work here already before it approves anything.
                    guard try await client.tokenWorks(token) else {
                        throw KitPairError.refused("\(config.name) at this address didn't accept the token saved in this app. Show a pairing code instead.")
                    }
                }
                let start = try await client.start(name: device)
                let expires = Date().addingTimeInterval(TimeInterval(start.expires_in))
                if plan == .selfApprove {
                    self.step = .working("Approving this \(device)…")
                    try await client.approve(code: start.code, name: device, bearer: token)
                } else {
                    self.step = .showing(code: start.code, expires: expires, link: start.url,
                                         cert: KitPairAddress.shortHash(client.certSHA256))
                }
                while !Task.isCancelled {
                    let result: KitPollResult
                    do {
                        result = try await client.poll(token: start.token)
                    } catch KitPairError.unreachable(let name) {
                        if Date() >= expires { throw KitPairError.expired }
                        if case .showing = self.step {} else { throw KitPairError.unreachable(name) }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    switch result {
                    case .waiting:
                        if Date() >= expires { throw KitPairError.expired }
                    case .gone:
                        throw KitPairError.expired
                    case let .paired(key, id, name, scopes):
                        let pairing = KitPairing(address: base.absoluteString, key: key, certSHA256: client.certSHA256,
                                                 deviceID: id, deviceName: name.isEmpty ? device : name, scopes: scopes,
                                                 pairedAt: Date(), serviceName: info.name)
                        if plan == .selfApprove {
                            self.save(pairing, origin: origin, onPaired: onPaired)
                        } else {
                            self.pending = (pairing, origin, onPaired)
                            self.step = .confirm(pairing, cert: KitPairAddress.shortHash(client.certSHA256))
                        }
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch let error as KitPairError {
                if Task.isCancelled { return }
                self.step = .failed(error.localizedDescription, canRetry: true)
            } catch {
                if Task.isCancelled { return }
                self.step = .failed(KitPairError.unreachable(config.name).localizedDescription, canRetry: true)
            }
        }
    }
}

struct KitPairView: View {
    @StateObject private var flow: KitPairFlow
    @State private var address: String
    private let onPaired: (KitPairing) -> Void

    init(config: KitPairConfig, onPaired: @escaping (KitPairing) -> Void) {
        _flow = StateObject(wrappedValue: KitPairFlow(config: config))
        _address = State(initialValue: config.defaultAddress)
        self.onPaired = onPaired
    }

    private var config: KitPairConfig { flow.config }
    private var device: String { KitPairDevice.noun }

    var body: some View {
        Form {
            switch flow.step {
            case .find: findSection
            case .working(let what):
                Section { HStack(spacing: 12) { ProgressView(); Text(what) } }
            case let .showing(code, expires, link, cert): codeSection(code: code, expires: expires, link: link, cert: cert)
            case let .confirm(_, cert): confirmSection(cert: cert)
            case .done(let pairing):
                Section {
                    Label(KitPairWords.paired(pairing.serviceName, can: config.can), systemImage: "checkmark.circle")
                        .accessibilityAddTraits(.isHeader)
                    Text("The key is kept in this \(device)'s Keychain. It never leaves this \(device).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case let .failed(message, canRetry):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                    if canRetry {
                        Button("Try again") { flow.cancel() }
                    }
                    Button("Change the address") { flow.cancel() }
                }
            }
        }
        .navigationTitle("Pair with the Pi")
        .onAppear { flow.browse() }
        .onDisappear { flow.stop() }
    }

    @ViewBuilder private var findSection: some View {
        if !flow.found.isEmpty {
            Section {
                ForEach(flow.found) { c in
                    Button {
                        flow.pair(address: c.address, origin: .discovered, onPaired: onPaired)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(config.name) on \(c.name)")
                            Text(c.address).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("On this Wi-Fi")
            } footer: {
                Text("Anything on the Wi-Fi can appear here, so these only show a code. Approve it on \(config.name)'s own Devices page, at the address you know, and check the certificate and address match.")
            }
        }
        Section {
            TextField("Address", text: $address)
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.go)
                .onSubmit { flow.pair(address: address, onPaired: onPaired) }
            Button("Show a pairing code") { flow.pair(address: address, onPaired: onPaired) }
        } header: {
            Text("Type an address")
        } footer: {
            Text("This \(device) shows a code. Type it on \(config.name)'s Devices page (the address followed by /pair), or approve it in another app that's paired. \(device) gets a key of its own, kept in the Keychain.")
        }
        if let token = config.mainToken(), !token.isEmpty, let home = flow.configuredAddress {
            Section {
                Button("Pair this \(device) instead") { flow.pair(address: home.absoluteString, origin: .configured, selfApprove: true, onPaired: onPaired) }
            } footer: {
                Text("Uses the token already saved in this app to approve this \(device) at \(home.host ?? home.absoluteString), the address it's set up with, so there's no code to type. You can take the token out afterwards.")
            }
        }
    }

    @ViewBuilder private func codeSection(code: String, expires: Date, link: String?, cert: String?) -> some View {
        Section {
            VStack(spacing: 8) {
                Text(code)
                    .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                if expires > Date() {
                    HStack(spacing: 4) {
                        Text("Runs out in")
                        Text(timerInterval: Date()...expires, countsDown: true).monospacedDigit()
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Text("Open \(config.name)'s Devices page (its address followed by /pair) and type this code. Before you press Pair there, check it shows the same certificate as below and \"From\" says this \(device)'s address.")
            LabeledContent("Certificate", value: cert ?? "none (plain http)")
                .font(.footnote)
                .accessibilityHint("Check it matches \"This server's certificate\" on the Devices page")
            if let mine = KitPairDevice.wifiAddress {
                LabeledContent("This \(device)", value: mine)
                    .font(.footnote)
                    .accessibilityHint("Check the Devices page says From \(mine)")
            }
            if let link, let url = URL(string: link) {
                ShareLink(item: url) { Label("Send the approve link", systemImage: "square.and.arrow.up") }
                #if canImport(UIKit)
                Button { UIPasteboard.general.string = link } label: { Label("Copy link", systemImage: "doc.on.doc") }
                #endif
            }
            Button("Cancel", role: .cancel) { flow.cancel() }
        } header: {
            Text("Pairing code")
        }
    }
}

extension KitPairView {
    @ViewBuilder func confirmSection(cert: String?) -> some View {
        Section {
            Text("\(config.name) approved the code. One check before this \(device) keeps the key:")
            LabeledContent("Certificate here", value: cert ?? "none (plain http)").font(.footnote)
            if let mine = KitPairDevice.wifiAddress {
                LabeledContent("This \(device)", value: mine).font(.footnote)
            }
            Text(cert == nil
                 ? "Did the Devices page say \"From\" this \(device)'s address?"
                 : "Did the Devices page show the same certificate, and say \"From\" this \(device)'s address?")
            Button("Yes, they matched") { flow.keep() }
            Button("No, something was different", role: .destructive) { flow.reject() }
        } header: {
            Text("Check it's really \(config.name)")
        }
    }
}

/// The paired state, for the top of the app's server settings: what it's paired as, and how to undo it.
struct KitPairStatus: View {
    let config: KitPairConfig
    let pairing: KitPairing
    var onForget: () -> Void

    var body: some View {
        LabeledContent("Paired as", value: pairing.deviceName)
        LabeledContent("Server", value: pairing.address)
        if let cert = KitPairAddress.shortHash(pairing.certSHA256) {
            LabeledContent("Certificate", value: cert).font(.footnote)
        }
        Button("Unpair this \(KitPairDevice.noun)", role: .destructive) {
            let p = pairing
            if let base = URL(string: p.address) {
                let client = KitPairClient(base: base, service: config.service, name: config.name, expectedCert: p.certSHA256)
                Task { await client.unpair(key: p.key) }
            }
            KitPairingStore.remove(service: config.keychainService, accessGroup: config.accessGroup)
            onForget()
        }
    }
}
#endif
