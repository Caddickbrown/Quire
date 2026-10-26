//
//  WelcomeView.swift
//  Nook
//
//  The first-run sheet: one screen, skippable, never seen again. It answers
//  the three questions a new arrival actually has — where do my words live,
//  how does the inbox→journal flow work, and how do I bring an old journal —
//  then gets out of the way into the composer.
//

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("nook")
                    .font(.custom("Lato-Regular", size: 30))
                    .tracking(2)
                Text("A quiet place to write")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 22) {
                row(icon: "doc.plaintext",
                    title: "Plain files, yours forever",
                    text: storageLine)
                row(icon: "tray.and.arrow.down",
                    title: "Write first, file later",
                    text: "Everything you write autosaves into the Inbox as a draft. File it into the dated journal whenever you're ready.")
                row(icon: "square.and.arrow.down",
                    title: "Bringing an old journal?",
                    text: "Settings → Maintenance imports a Day One export or a folder of dated markdown files, photos and tags included.")
                row(icon: "lock",
                    title: "Private by default",
                    text: "Nothing leaves your devices. Face ID lock, Spotlight, and reminders are all opt-in, in Settings.")
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 24)

            Button {
                dismiss()
                nav.requestNewEntry()
            } label: {
                Text("Start Writing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)

            Button("Just look around") { dismiss() }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .padding(.bottom, 28)
        }
        #if os(macOS)
        .frame(width: 460, height: 560)
        #endif
    }

    private var storageLine: String {
        switch store.storageMode {
        case .iCloud: return "Your journal is markdown in iCloud Drive — synced across devices, readable in any editor, and shareable with the jnl CLI. Point it at any folder in Settings."
        case .custom: return "Your journal is plain markdown in the folder you chose — readable in any editor, shareable with the jnl CLI."
        case .local:  return "Your journal is plain markdown on this device (iCloud is off) — readable in any editor. Choose a synced folder any time in Settings."
        }
    }

    private func row(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
