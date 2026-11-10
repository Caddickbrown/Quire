//
//  EditorUITests.swift
//  QuireUITests
//
//  The writing page, driven in a simulator: where a tap puts the caret, where
//  typed characters land, and whether the body holds still when the keyboard
//  turns "..." into "…". Each test opens a new page with QUIRE_OPEN=write and
//  discards it (^D, or Delete in the Inbox) when done, so the journal it runs against is left as it was.
//
//  `make -C apple uitest`. The ellipsis test needs the software keyboard: in
//  the Simulator, I/O › Keyboard › Connect Hardware Keyboard must be off.
//

import XCTest
import UIKit

final class EditorUITests: XCTestCase {
    private var app: XCUIApplication!
    /// No single interaction may take longer than this: the hang guard.
    private static let hang: TimeInterval = 20
    /// An element query after a tap must answer within this.
    private static let responsive: TimeInterval = 5
    private var slowest: (what: String, took: TimeInterval) = ("", 0)

    private var titleField: XCUIElement { app.textFields["composer.title"] }
    private var body: XCUIElement { app.textViews["composer.body"] }
    private var closeButton: XCUIElement { app.buttons["composer.close"] }
    private var fileButton: XCUIElement { app.buttons["composer.file"] }

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        // Whatever the test left open is discarded, not saved as a draft.
        if let app, app.state == .runningForeground { discardPage(checked: false) }
        print("EDITOR-UI slowest interaction: \(slowest.what) \(String(format: "%.2f", slowest.took)) s")
    }

    // MARK: Tests

    func testTapBelowWordsFocusesBody() {
        launch()
        XCTAssertEqual(bodyText, "")
        XCTAssertEqual(titleText, "")

        step("tap below the placeholder") { below().tap() }
        step("type hello") { app.typeText("hello") }
        print("EDITOR-UI body after typing hello: \(bodyText.debugDescription)")
        XCTAssertEqual(bodyText, "hello", "typed after a tap below the placeholder")
        XCTAssertEqual(titleText, "", "the title must still be empty")

        for round in 1...20 {
            let titleBefore = titleText, bodyBefore = bodyText
            step("tap the title, round \(round)") { titleField.tap() }
            assertResponsive("after the title tap, round \(round)")
            step("type in the title, round \(round)") { app.typeText("t") }
            XCTAssertEqual(titleText.lowercased(), (titleBefore + "t").lowercased(), "round \(round): typed after tapping the title")
            XCTAssertEqual(bodyText, bodyBefore, "round \(round): the body must not change while typing in the title")

            step("tap below the words, round \(round)") { below().tap() }
            assertResponsive("after the tap below, round \(round)")
            step("type in the body, round \(round)") { app.typeText("b") }
            XCTAssertEqual(bodyText, bodyBefore + "b", "round \(round): typed after tapping below the words")
            XCTAssertEqual(titleText.lowercased(), (titleBefore + "t").lowercased(), "round \(round): the title must not change while typing in the body")
        }

        // Three lines, the keyboard taken elsewhere, then a tap far below them.
        step("type three lines") { app.typeText("\nsecond line\nthird line") }
        let lines = bodyText
        XCTAssertEqual(lines.components(separatedBy: "\n").count, 3)
        step("tap the title") { titleField.tap() }
        step("tap far below the words") { below(0.92).tap() }
        assertResponsive("after the tap far below")
        step("type at the end") { app.typeText("Z") }
        XCTAssertEqual(bodyText, lines + "Z", "a tap far below the words puts the caret at the end of the body")

        discardPage()
    }

    func testReturnInTitleMovesToBody() {
        launch()
        step("type a title") { app.typeText("A title") }
        XCTAssertEqual(titleText.lowercased(), "a title")
        XCTAssertEqual(bodyText, "")
        step("press Return") { app.typeText("\n") }
        assertResponsive("after Return in the title")
        step("type after Return") { app.typeText("words") }
        XCTAssertEqual(bodyText.lowercased(), "words", "typed after Return in the title")
        XCTAssertEqual(titleText.lowercased(), "a title", "the title keeps what it had")

        // And with the keyboard's own key, when it is on screen.
        let next = app.keyboards.buttons.matching(NSPredicate(format: "identifier IN {'Next:', 'Return', 'next'} OR label IN {'next', 'Next', 'return'}")).firstMatch
        step("tap the title") { titleField.tap() }
        if next.waitForExistence(timeout: 5) {
            step("tap the keyboard's Next") { next.tap() }
            assertResponsive("after the keyboard's Next")
            step("type after Next") { app.typeText("x") }
            XCTAssertEqual(bodyText.lowercased(), "wordsx", "typed after the keyboard's Next key")
            XCTAssertEqual(titleText.lowercased(), "a title")
        } else {
            print("EDITOR-UI no software Next key on screen: the Return key was only sent as a character")
        }
        discardPage()
    }

    func testEllipsisDoesNotMoveTheBody() {
        continueAfterFailure = true
        for placement in Placement.allCases { ellipsis(placement) }
    }

    func testTypingStylesMarkdownAndUndo() {
        // How many drafts are waiting before anything is written.
        launch(write: false, tab: "inbox")
        let before = draftsWaiting()
        print("EDITOR-UI drafts waiting before: \(before.map(String.init) ?? "unreadable")")

        // A page closed untouched makes no draft.
        launch(tab: "inbox")
        step("Close, untouched") { closeButton.tap() }
        waitGone(body, "the page closes")
        let untouched = draftsWaiting()
        if let before, let untouched { XCTAssertEqual(untouched, before, "an untouched page must not become a draft") }

        // Markdown goes in as typed, and Close saves it and leaves.
        launch(tab: "inbox")
        step("tap below the placeholder") { below().tap() }
        let typed = "**bold** and _it_"
        step("type markdown") { app.typeText(typed) }
        XCTAssertEqual(bodyText, typed, "the text is what was typed, markers included")
        XCTAssertEqual(titleText, "")
        step("Close") { closeButton.tap() }
        waitGone(body, "the page closes")
        assertResponsive("after Close", element: app.staticTexts.firstMatch)
        let saved = draftsWaiting()
        if let before, let saved { XCTAssertEqual(saved, before + 1, "Close keeps what was written as one draft") }

        // The draft this test made is deleted from the Inbox: press and hold,
        // then Delete. The Inbox lists it by its words, markers dropped.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'bold and it'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the new draft is listed in the Inbox")
        step("press and hold the draft") { row.press(forDuration: 1.0) }
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 15), "press and hold offers Delete")
        step("Delete") { delete.tap() }
        waitGone(row, "the draft leaves the Inbox")
        let after = draftsWaiting()
        if let before, let after { XCTAssertEqual(after, before, "the journal is left as it was") }
    }

    // MARK: The ellipsis

    private enum Placement: String, CaseIterable {
        case alone = "alone on line one"
        case tagBelow = "end of line one, @tag line below"
        case midParagraph = "mid-paragraph"
        case wrapped = "in a wrapped paragraph"
    }

    private static let long = "the quick brown fox jumps over the lazy dog and keeps on running through the long wet grass until the evening comes down"

    private func ellipsis(_ placement: Placement) {
        let name = placement.rawValue
        launch()
        step("tap below the placeholder") { below().tap() }
        guard app.keyboards.keys["more"].waitForExistence(timeout: 15) || app.keyboards.keys["."].exists else {
            XCTFail("\(name): no software keyboard on screen. Turn off I/O › Keyboard › Connect Hardware Keyboard in the Simulator.")
            discardPage(checked: false)
            return
        }

        switch placement {
        case .alone:
            break
        case .tagBelow:
            step("type two lines") { app.typeText("walking home in the rain\n@tag") }
            let b = body.frame
            step("tap the end of line one") { point(b.maxX - 4, b.minY + 12).tap() }
        case .midParagraph:
            step("type a paragraph") { app.typeText(Self.long) }
            let b = body.frame
            step("tap the middle of line one") { point(b.midX, b.minY + 12).tap() }
        case .wrapped:
            step("type a line and a long paragraph") { app.typeText("a short first line\n" + Self.long) }
        }

        let frame = body.frame
        let textBefore = bodyText
        tapPeriod(); tapPeriod()
        let twoDots = bodyText
        let first = XCUIScreen.main.screenshot()
        tapPeriod()
        // The substitution, and the editor's own repair a turn later.
        Thread.sleep(forTimeInterval: 1.0)
        let second = XCUIScreen.main.screenshot()
        let afterDots = bodyText
        let frameAfter = body.frame
        // A letter stands taller than a row of dots, so where the dots are the
        // whole first line the next key is another dot.
        let nextKey = placement == .alone ? "." : "x"
        step("type the next key") { app.typeText(nextKey) }
        Thread.sleep(forTimeInterval: 0.5)
        let third = XCUIScreen.main.screenshot()
        let final = bodyText

        let y1 = firstInkRow(first, under: frame), y2 = firstInkRow(second, under: frame), y3 = firstInkRow(third, under: frame)
        let substituted = afterDots.contains("…")
        print("EDITOR-UI ellipsis [\(name)]: before \(textBefore.debugDescription) two dots \(twoDots.debugDescription) after \(afterDots.debugDescription) next key \(final.debugDescription)")
        print("EDITOR-UI ellipsis [\(name)]: substituted=\(substituted) first ink row y: two dots \(fmt(y1)) -> after the third \(fmt(y2)) -> after the next key \(fmt(y3)); body frame \(frame) -> \(frameAfter)")
        for (shot, label) in [(first, "two dots"), (second, "after the third"), (third, "after the next key")] {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "\(name): \(label)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertTrue(substituted || afterDots.contains("..."), "\(name): the periods are in the body")
        XCTAssertTrue(substituted, "\(name): the keyboard did not turn ... into …, so E2 is not exercised")
        switch placement {
        case .alone: XCTAssertEqual(afterDots, substituted ? "…" : "...", name)
        case .tagBelow: XCTAssertTrue(afterDots.hasSuffix("\n@tag") && !afterDots.hasPrefix("…"), "\(name): the periods went in at the end of line one")
        case .midParagraph: XCTAssertFalse(afterDots.hasSuffix("…") || afterDots.hasSuffix("."), "\(name): the periods went in mid-paragraph")
        case .wrapped: XCTAssertTrue(afterDots.hasSuffix("…") || afterDots.hasSuffix("..."), "\(name): the periods went in at the end")
        }
        if let y1, let y2, let y3 {
            XCTAssertEqual(y2, y1, accuracy: 1.0, "\(name): the first line moved when ... became …")
            XCTAssertEqual(y3, y2, accuracy: 1.0, "\(name): the first line moved on the key after …")
        } else {
            XCTFail("\(name): no ink found under the body's frame (\(fmt(y1)), \(fmt(y2)), \(fmt(y3)))")
        }
        XCTAssertEqual(frameAfter.minY, frame.minY, accuracy: 1.0, "\(name): the text view itself moved")
        discardPage(checked: false)
        XCTAssertFalse(body.exists, "\(name): the page was discarded")
    }

    /// One "." on the software keyboard, from whichever plane it is showing.
    private func tapPeriod() {
        let dot = app.keyboards.keys["."]
        if !dot.exists {
            step("switch to the numbers plane") { app.keyboards.keys["more"].tap() }
            XCTAssertTrue(dot.waitForExistence(timeout: 10), "the numbers plane has a period")
        }
        step("tap the period key") { dot.tap() }
    }

    /// The y (in points) of the first row with ink in it, from the top of the
    /// body's frame down. Ink is dark and near grey: the caret, a tag and the
    /// placeholder are not (the tests run in the Linen theme, whose accent is blue).
    private func firstInkRow(_ shot: XCUIScreenshot, under frame: CGRect) -> CGFloat? {
        guard let image = shot.image.cgImage else { return nil }
        let width = image.width, height = image.height
        let scale = CGFloat(width) / app.frame.width
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let floor = min(fileButton.frame.minY - 4, frame.minY + 240)
        let top = max(0, Int((frame.minY - 2) * scale)), bottom = min(height, Int(floor * scale))
        let left = max(0, Int(frame.minX * scale)), right = min(width, Int(frame.maxX * scale))
        guard top < bottom, left < right else { return nil }
        for y in top..<bottom {
            var dark = 0
            for x in left..<right {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if max(r, g, b) < 110, max(r, g, b) - min(r, g, b) < 45 { dark += 1 }
            }
            if dark >= 2 { return CGFloat(y) / scale }
        }
        return nil
    }

    private func fmt(_ y: CGFloat?) -> String { y.map { String(format: "%.2f", $0) } ?? "none" }

    // MARK: Helpers

    private func launch(write: Bool = true, tab: String? = nil) {
        if let app, app.state == .runningForeground { discardPage(checked: false) }
        app = XCUIApplication()
        app.launchEnvironment["QUIRE_THEME"] = "linen"
        if write { app.launchEnvironment["QUIRE_OPEN"] = "write" }
        if let tab { app.launchEnvironment["QUIRE_START_TAB"] = tab }
        app.launch()
        guard write else { return }
        XCTAssertTrue(body.waitForExistence(timeout: 120), "the writing page opens")
        // A new page starts on its title.
        let deadline = Date().addingTimeInterval(30)
        while !hasFocus(titleField), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(hasFocus(titleField), "a new page starts with the keyboard in the title")
        // The simulator's first keyboard offers a tip that covers the keys.
        let tip = app.buttons["Continue"]
        if tip.exists { tip.tap() }
    }

    /// Runs one interaction and fails if it took longer than the hang guard.
    private func step(_ what: String, _ action: () -> Void) {
        let start = Date()
        action()
        let took = Date().timeIntervalSince(start)
        if took > slowest.took { slowest = (what, took) }
        XCTAssertLessThanOrEqual(took, Self.hang, "hang guard: \(what) took \(String(format: "%.1f", took)) s")
    }

    /// The app answers an element query promptly.
    private func assertResponsive(_ when: String, element: XCUIElement? = nil) {
        let start = Date()
        let exists = (element ?? body).exists
        let took = Date().timeIntervalSince(start)
        if took > slowest.took { slowest = ("query \(when)", took) }
        XCTAssertTrue(exists, "\(when): the element is there")
        XCTAssertLessThanOrEqual(took, Self.responsive, "\(when): a query took \(String(format: "%.1f", took)) s")
    }

    private var bodyText: String { body.value as? String ?? "" }
    /// An empty text field reports its placeholder as its value.
    private var titleText: String {
        let value = titleField.value as? String ?? ""
        return value == titleField.placeholderValue ? "" : value
    }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        element.exists && ((element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    /// A point in the blank part of the page: `fraction` of the way from the
    /// top of the body to the footer (or the keyboard, whichever is higher).
    private func below(_ fraction: CGFloat = 0.7) -> XCUICoordinate {
        let top = body.frame.minY
        var bottom = fileButton.frame.minY - 12
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY - 12) }
        XCTAssertGreaterThan(bottom - top, 80, "there is blank page between the body's first line and the footer")
        let y = top + (bottom - top) * fraction
        print("EDITOR-UI tap below at y \(String(format: "%.0f", y)) of \(String(format: "%.0f", app.frame.height)) (\(String(format: "%.2f", y / app.frame.height)))")
        return point(app.frame.midX, y)
    }

    private func waitGone(_ element: XCUIElement, _ what: String) {
        let start = Date()
        let gone = element.waitForNonExistence(timeout: Self.hang)
        let took = Date().timeIntervalSince(start)
        if took > slowest.took { slowest = (what, took) }
        XCTAssertTrue(gone, "hang guard: \(what)")
    }

    /// ^D and its confirmation: the page goes and nothing is kept.
    private func discardPage(checked: Bool = true) {
        guard body.exists else { return }
        if !hasFocus(body) { below().tap() }
        let discard = app.buttons["Discard"]
        let start = Date()
        // The first hardware key after typing on the software keyboard can be
        // lost while the simulator changes over to the hardware one: asked again.
        var asked = false
        for attempt in 1...3 where !asked {
            app.typeKey("d", modifierFlags: .control)
            asked = discard.waitForExistence(timeout: 5)
            if attempt > 1 || !asked { print("EDITOR-UI ^D attempt \(attempt): \(asked ? "asked" : "nothing")") }
        }
        if asked { discard.tap() }
        let gone = asked && body.waitForNonExistence(timeout: Self.hang)
        let took = Date().timeIntervalSince(start)
        if took > slowest.took { slowest = ("discard", took) }
        if checked {
            XCTAssertTrue(asked, "^D asks before discarding")
            XCTAssertTrue(gone, "the page closes once discarded")
        }
    }

    /// The Inbox's "N drafts waiting", or nil when it isn't on screen.
    private func draftsWaiting() -> Int? {
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'waiting'")).firstMatch
        guard line.waitForExistence(timeout: 60) else { return nil }
        let label = line.label
        if label.localizedCaseInsensitiveContains("nothing waiting") { return 0 }
        guard let match = label.range(of: #"(\d+) drafts? waiting"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(label[match].prefix { $0.isNumber })
    }
}
