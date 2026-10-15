//
//  YearReviewView.swift
//  Quire
//
//  Stats → Year in Review: one year's journal at a glance, plus a shareable
//  card rendered with ImageRenderer. Stats-only by default — no entry text
//  leaves the app unless the user includes the first-line highlight.
//

import SwiftUI

struct YearReviewSheet: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue

    let year: String
    @State private var review: YearReview?
    @State private var includeFirstLine = false

    var body: some View {
        NavigationStack {
            Group {
                if let review {
                    content(review)
                } else {
                    ProgressView("Reading \(year)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("\(year) in review")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if let review {
                    ShareLink(item: cardImage(review),
                              preview: SharePreview("Quire — \(year)", image: cardImage(review))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Done") { dismiss() }
            }
        }
        .task { review = await store.yearReview(for: year) }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func content(_ r: YearReview) -> some View {
        Form {
            if !r.dailyWords.isEmpty {
                Section("Day by day") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HeatStripView(year: r.year, dailyWords: r.dailyWords)
                            .padding(.vertical, 6)
                    }
                }
            }
            Section("Writing") {
                LabeledContent("Days written", value: "\(r.daysWritten)")
                LabeledContent("Entries", value: "\(r.entries)")
                LabeledContent("Words", value: "\(r.words)")
                LabeledContent("Longest streak", value: "\(r.longestStreak) day\(r.longestStreak == 1 ? "" : "s")")
                if !r.busiestDay.isEmpty {
                    LabeledContent("Busiest day",
                                   value: "\(Theme.displayDate(r.busiestDay, style: dateStyleRaw)) · \(r.busiestDayWords) words")
                }
                if r.starred > 0 {
                    LabeledContent("Starred", value: "\(r.starred)")
                }
            }
            if !r.topTags.isEmpty {
                Section("Top tags") {
                    ForEach(r.topTags, id: \.tag) { t in
                        LabeledContent(t.tag, value: "\(t.count)")
                    }
                }
            }
            if r.photoCount + r.videoCount + r.audioCount > 0 {
                Section("Media") {
                    if r.photoCount > 0 { LabeledContent("Photos", value: "\(r.photoCount)") }
                    if r.videoCount > 0 { LabeledContent("Videos", value: "\(r.videoCount)") }
                    if r.audioCount > 0 { LabeledContent("Voice memos", value: "\(r.audioCount)") }
                }
            }
            if !r.firstLine.isEmpty {
                Section {
                    Toggle("Include first line on the shared card", isOn: $includeFirstLine)
                } header: {
                    Text("Sharing")
                } footer: {
                    Text("The card carries numbers only unless you include this: “\(r.firstLine)”")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Render the shareable card. `Image` is Transferable, so ShareLink can
    /// hand it straight to the share sheet.
    @MainActor
    private func cardImage(_ r: YearReview) -> Image {
        let renderer = ImageRenderer(content: YearReviewCard(
            review: r, accent: accent,
            firstLine: includeFirstLine ? r.firstLine : ""))
        renderer.scale = 2
        #if os(macOS)
        if let cg = renderer.cgImage {
            return Image(nsImage: NSImage(cgImage: cg, size: .zero))
        }
        #else
        if let ui = renderer.uiImage {
            return Image(uiImage: ui)
        }
        #endif
        return Image(systemName: "book.closed")
    }
}

/// The shared card: a fixed-size summary in the app's own type.
struct YearReviewCard: View {
    let review: YearReview
    let accent: Color
    let firstLine: String

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.custom("Lato-Bold", size: 30))
                .foregroundStyle(accent)
            Text(label.uppercased())
                .font(.custom("Lato-Regular", size: 11))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("quire")
                    .font(.custom("Lato-Regular", size: 15))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(review.year)
                    .font(.custom("Lato-Bold", size: 30))
                    .foregroundStyle(accent)
            }
            Rectangle().fill(accent.opacity(0.35)).frame(height: 1.5)
            HStack(alignment: .top, spacing: 28) {
                stat("\(review.words)", "words")
                stat("\(review.daysWritten)", "days")
                stat("\(review.entries)", "entries")
                stat("\(review.longestStreak)", "best streak")
            }
            if !review.dailyWords.isEmpty {
                // The year, day by day — the card's most shareable pixel.
                HeatStripView(year: review.year, dailyWords: review.dailyWords,
                              cellSize: 7.4, gap: 1.6)
                    .environment(\.accent, accent)
            }
            if !review.topTags.isEmpty {
                Text(review.topTags.map(\.tag).joined(separator: "   "))
                    .font(.custom("Lato-Regular", size: 15))
                    .foregroundStyle(accent)
            }
            if !firstLine.isEmpty {
                Text("“\(firstLine)”")
                    .font(.custom("Lato-Regular", size: 16))
                    .italic()
                    .foregroundStyle(.primary)
            }
        }
        .padding(34)
        .frame(width: 560, alignment: .leading)
        .background(Color(white: 0.97))
        .environment(\.colorScheme, .light)
    }
}
