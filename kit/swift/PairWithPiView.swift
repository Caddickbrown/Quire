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
    /// Prefilled in "Type an address", e.g. "https://192.168.4.185:8773".
    var defaultAddress: String
    /// The Keychain item, e.g. "com.caddickbrown.Pala.pairing".
    var keychainService: String
    var accessGroup: String? = nil
    /// Finishes "This iPhone can …", e.g. "read and change your notes".
    var can: String
    /// The main token the app already holds, if any: offers "Pair this iPhone instead".
    var mainToken: () -> String? = { nil }
    /// The scheme used when an address is typed without one.
    var defaultScheme: String = "https"
    /// The port used when an address is typed without one, e.g. 8915.
    var defaultPort: Int? = nil
}

@MainActor
final class KitPairFlow: ObservableObject {
    enum Step: Equatable {
        case find
        case working(String)
        case showing(code: String, expires: Date, link: String?, cert: String?)
        case done(KitPairing)
        case failed(String, canRetry: Bool)
    }

    @Published var step: Step = .find
    @Published var found: [KitPairCandidate] = []
    let config: KitPairConfig
    private var task: Task<Void, Never>?
    #if canImport(Network)
    private let browser = KitPairBrowser()
    #endif

    init(config: KitPairConfig) { self.config = config }

    func browse() {
        #if canImport(Network)
        browser.start(service: config.service) { [weak self] candidate in
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
        step = .find
    }

    /// Shows a code for Dan to approve, or, with `selfApprove`, approves it with the main token.
    func pair(address: String, cert: String? = nil, selfApprove: Bool = false, onPaired: @escaping (KitPairing) -> Void) {
        task?.cancel()
        let config = self.config
        task = Task { [weak self] in
            guard let self else { return }
            guard let base = KitPairAddress.normalise(address, defaultScheme: config.defaultScheme, defaultPort: config.defaultPort) else {
                self.step = .failed(KitPairError.badAddress.localizedDescription, canRetry: false)
                return
            }
            let client = KitPairClient(base: base, service: config.service, name: config.name, expectedCert: cert)
            let device = KitPairDevice.noun
            do {
                self.step = .working("Checking \(base.host ?? address)…")
                let info = try await client.service()
                let start = try await client.start(name: device)
                let expires = Date().addingTimeInterval(TimeInterval(start.expires_in))
                if selfApprove, let token = config.mainToken(), !token.isEmpty {
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
                        guard KitPairingStore.save(pairing, service: config.keychainService, accessGroup: config.accessGroup) else {
                            throw KitPairError.refused("Couldn't save the key in the Keychain. Try again.")
                        }
                        KitPairFallback.clear()
                        self.step = .done(pairing)
                        onPaired(pairing)
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
            Section("On this Wi-Fi") {
                ForEach(flow.found) { c in
                    Button {
                        flow.pair(address: c.address, cert: c.cert, onPaired: onPaired)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("\(config.name) on \(c.name)")
                            Text(c.address).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
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
        if let token = config.mainToken(), !token.isEmpty {
            Section {
                Button("Pair this \(device) instead") { flow.pair(address: address, selfApprove: true, onPaired: onPaired) }
            } footer: {
                Text("Uses the token already saved in this app to approve this \(device), so there's no code to type. You can take the token out afterwards.")
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
            Text("Open the Devices page on \(config.name) and type this code. Or approve it in another app that's paired. This changes by itself once it's approved.")
            if let cert {
                LabeledContent("Certificate", value: cert)
                    .font(.footnote)
                    .accessibilityHint("Check it matches the one on the Devices page")
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
