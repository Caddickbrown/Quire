//
//  TodayScreen.swift
//  Quire
//
//  The home face: the date, a sentence about the day, a way to begin, today's
//  entries and what you wrote on this day in earlier years.
//

#if os(iOS)

import SwiftUI

struct TodayScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @AppStorage("wordGoalEnabled") private var goalOn = false
    @AppStorage("wordGoal") private var goal = 750

    var open: (EntryRef) -> Void
    var compose: () -> Void
    var showInbox: () -> Void
    var search: () -> Void
    var settings: () -> Void

    @State private var line = ""
    @FocusState private var lineFocused: Bool

    private var today: String { JournalStore.nowDate() }
    private var filedToday: [Entry] {
        (store.archiveEntries.first { $0.date == today }?.entries ?? []).reversed()
    }
    /// `p` asks for another prompt (the offset is bumped by the key handler).
    @AppStorage("quirePromptOffset") private var promptOffset = 0
    private var prompt: String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return PromptDeck.prompts[(day + promptOffset) % PromptDeck.prompts.count]
    }
    private var onThisDay: [(date: String, entries: [Entry])] { store.qOnThisDay() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                QMasthead(onSearch: search, onSettings: settings)
                if q.isMarathon {
                    marathonHeader
                    readouts
                } else {
                    QTitle(kicker: QDate.longDay(), title: "Today")
                    summary
                }
                begin
                capture
                if !filedToday.isEmpty { entries }
                if let past = onThisDay.first { onThisDaySection(past) }
                if q.isMarathon { marathonFooter }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(alignment: .topTrailing) {
            if q.isMarathon { QDotField(color: q.signalColor).opacity(0.55).frame(width: 170, height: 120).padding(.top, 150).padding(.trailing, 14) }
        }
    }

    // "Three entries filed, 145 of 250 words so far. Three drafts are waiting."
    private var summary: some View {
        let words = store.stats().wordsToday
        let drafts = store.inboxDrafts.count
        return (Text(entriesPhrase)
            + (goalOn ? Text(", ") + Text("\(words) of \(max(goal, 1))").foregroundColor(q.accentColor) + Text(" words so far.")
                      : Text(words > 0 ? ", \(words) words so far." : "."))
            + (drafts > 0 ? Text(" ") + Text(draftsPhrase(drafts)).foregroundColor(q.accentColor) + Text(" waiting.") : Text("")))
            .font(q.writing(18))
            .foregroundStyle(q.inkColor)
            .lineSpacing(5)
            .onTapGesture { if drafts > 0 { showInbox() } }
            .accessibilityElement(children: .combine)
    }

    private var entriesPhrase: String {
        let n = filedToday.count
        return n == 0 ? (store.indexed ? "Nothing filed yet" : "Loading your journal") : n == 1 ? "One entry filed" : "\(Self.word(n)) entries filed"
    }
    private func draftsPhrase(_ n: Int) -> String { n == 1 ? "One draft is" : "\(Self.word(n)) drafts are" }
    private static func word(_ n: Int) -> String {
        let names = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return n < names.count ? names[n] : "\(n)"
    }

    private var begin: some View {
        Button(action: compose) {
            if q.isMarathon {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("BEGIN A NEW ENTRY").font(q.display(19)).tracking(-0.2)
                        Spacer(minLength: 8)
                        Text("→").font(q.mono(20, weight: .medium))
                    }
                    Text(prompt).font(q.ui(14)).italic().opacity(0.7).multilineTextAlignment(.leading)
                }
                .foregroundStyle(q.pageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(q.inkColor)
                .clipShape(QChamfer(cut: 22))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Begin a new entry").font(q.writing(24))
                        Text("→").foregroundStyle(q.accentColor)
                    }
                    Text(prompt).font(q.writing(16, italic: true)).foregroundStyle(q.mutedColor)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(q.inkColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16)
                .overlay(alignment: .top) { QRule() }
                .overlay(alignment: .bottom) { QRule() }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Marathon

    private var marathonHeader: some View {
        let cal = Calendar.current
        let day = cal.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let days = cal.range(of: .day, in: .year, for: Date())?.count ?? 365
        let year = cal.component(.year, from: Date())
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String(format: "LOG %d.%03d", year, day)).tracking(1.4)
                    .font(q.label(11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(q.signalColor).foregroundStyle(q.onSignalColor)
                Text("DAY \(day) / \(days)").tracking(1.4).font(q.label(11)).foregroundStyle(q.mutedColor)
            }
            Text(QDate.longDay().uppercased() + " " + String(year)).tracking(1.6)
                .font(q.label(11)).foregroundStyle(q.mutedColor)
            Text("TODAY").font(q.display(60)).tracking(-1.2).foregroundStyle(q.inkColor)
                .minimumScaleFactor(0.5).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Words and goal, the streak, the inbox: figures in cells, ruled off.
    private var readouts: some View {
        let stats = store.stats()
        let words = stats.wordsToday
        let drafts = store.inboxDrafts.count
        let fill = goalOn ? min(1, Double(words) / Double(max(goal, 1))) : 0
        return HStack(alignment: .top, spacing: 0) {
            cell("Words" + (goalOn ? " / goal" : ""), spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(String(format: "%03d", words)).foregroundStyle(q.accentColor)
                    if goalOn { Text("/\(goal)").foregroundStyle(q.faintColor) }
                }
                .font(q.display(24)).lineLimit(1).minimumScaleFactor(0.5)
                if goalOn {
                    Rectangle().fill(q.line2Color).frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { g in Rectangle().fill(q.signalColor).frame(width: g.size.width * fill) }
                        }
                }
            }
            cell("Streak", leading: true) {
                Text("\(stats.currentStreak)").font(q.display(24)).lineLimit(1).minimumScaleFactor(0.5)
                Text("DAYS").font(q.label(10)).foregroundStyle(q.mutedColor)
                if stats.currentStreak > 0 && stats.currentStreak >= stats.bestStreak {
                    Text("▲ RECORD").font(q.label(9.5)).tracking(1).foregroundStyle(q.accentColor)
                }
            }
            cell("Inbox", leading: true) {
                Text(String(format: "%02d", drafts)).font(q.display(24)).lineLimit(1).minimumScaleFactor(0.5)
                Text("UNFILED").font(q.label(10)).foregroundStyle(q.mutedColor)
            }
        }
        .overlay(alignment: .top) { QRule() }
        .overlay(alignment: .bottom) { QRule() }
        .onTapGesture { if drafts > 0 { showInbox() } }
    }

    private func cell<Content: View>(_ label: String, leading: Bool = false, spacing: CGFloat = 6,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(label.uppercased()).tracking(1.2).font(q.label(9.5)).foregroundStyle(q.mutedColor)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12).padding(.leading, leading ? 12 : 0).padding(.trailing, 8)
        .overlay(alignment: .leading) { if leading { Rectangle().fill(q.lineColor).frame(width: 1) } }
        .accessibilityElement(children: .combine)
    }

    private var marathonFooter: some View {
        let stats = store.stats()
        return VStack(spacing: 8) {
            QHazard(color: q.signalColor).opacity(0.9)
            HStack {
                Text("~/JOURNAL")
                Spacer()
                Text("\(stats.entries) ENTRIES · \(stats.words >= 1000 ? String(format: "%.1fK", Double(stats.words) / 1000) : "\(stats.words)") WORDS")
            }
            .font(q.label(9.5)).tracking(1.2).foregroundStyle(q.mutedColor)
        }
        .padding(.top, 14)
        .accessibilityHidden(true)
    }

    // One line, straight to the inbox, without opening the page.
    private var capture: some View {
        HStack {
            TextField("", text: $line, prompt: Text("Write a line…").font(q.writing(18, italic: true))
                .foregroundColor(q.faintColor))
                .font(q.writing(18))
                .focused($lineFocused)
                .submitLabel(.done)
                .onSubmit(saveLine)
                .frame(minHeight: 44)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                QLink(title: "Save to inbox", emphasised: true, action: saveLine)
            }
        }
        .overlay(alignment: .bottom) { QRule() }
    }

    private func saveLine() {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.upsertDraft(previous: nil, timestamp: JournalStore.nowTS(), title: "", body: text)
        line = ""
        lineFocused = false
    }

    private var entries: some View {
        VStack(alignment: .leading, spacing: 14) {
            QLabel("Filed today", trailing: "\(filedToday.count)")
            ForEach(filedToday) { entry in
                let ref = EntryRef(entry: entry, source: .archive(date: today))
                QEntryRow(entry: entry, onOpen: { open(ref) })
            }
        }
    }

    private func onThisDaySection(_ past: (date: String, entries: [Entry])) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            QLabel("On this day")
            ForEach(past.entries.prefix(2)) { entry in
                let ref = EntryRef(entry: entry, source: .archive(date: past.date))
                Button { open(ref) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(past.date.prefix(4))).font(q.mono(12)).foregroundStyle(q.accentColor)
                            .fixedSize().rotationEffect(.degrees(-90)).frame(width: 14, height: 34)
                            .padding(.top, 4)
                        Text(entry.qTitle.isEmpty ? "Untitled" : entry.qTitle)
                            .font(q.writing(18)).foregroundStyle(q.inkColor)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#endif
