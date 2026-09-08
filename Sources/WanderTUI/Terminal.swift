//
//  Terminal.swift
//  wander (terminal build)
//
//  Raw mode, window size and the ANSI vocabulary the terminal build draws with.
//  Foundation plus libc only — this is the half that has to run on Linux.
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum Term {
    // MARK: Raw mode

    private static var saved: termios?

    static func enterRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        saved = raw
        #if canImport(Darwin)
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON) | UInt(ISIG))
        #else
        raw.c_lflag &= ~(UInt32(ECHO) | UInt32(ICANON) | UInt32(ISIG))
        #endif
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        write("\u{1B}[?1049h")   // alternate screen
        write("\u{1B}[?25l")     // hide cursor
    }

    static func exitRawMode() {
        write("\u{1B}[?25h")
        write("\u{1B}[?1049l")
        guard var restore = saved else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
    }

    /// Hand the terminal back to a child process (the editor), then take it back.
    static func suspended<T>(_ body: () throws -> T) rethrows -> T {
        exitRawMode()
        defer { enterRawMode() }
        return try body()
    }

    // MARK: Size

    static var size: (rows: Int, columns: Int) {
        var window = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window) == 0,
           window.ws_row > 0, window.ws_col > 0 {
            return (Int(window.ws_row), Int(window.ws_col))
        }
        return (24, 80)
    }

    // MARK: Output

    static func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    static func clear() { write("\u{1B}[2J\u{1B}[H") }
    static func move(row: Int, column: Int) { write("\u{1B}[\(row);\(column)H") }

    // MARK: Input

    /// One keypress, with the common escape sequences folded into names.
    static func readKey() -> Key {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return .none }
        if byte == 0x1B {
            var next: UInt8 = 0
            guard read(STDIN_FILENO, &next, 1) == 1 else { return .escape }
            if next == UInt8(ascii: "[") {
                var code: UInt8 = 0
                guard read(STDIN_FILENO, &code, 1) == 1 else { return .escape }
                switch code {
                case UInt8(ascii: "A"): return .up
                case UInt8(ascii: "B"): return .down
                case UInt8(ascii: "C"): return .right
                case UInt8(ascii: "D"): return .left
                default: return .none
                }
            }
            return .escape
        }
        switch byte {
        case 13, 10: return .enter
        case 127, 8: return .backspace
        case 9: return .tab
        case 3: return .character("q")     // ^C leaves, like q
        default: return .character(Character(UnicodeScalar(byte)))
        }
    }

    enum Key: Equatable {
        case character(Character)
        case up, down, left, right
        case enter, backspace, tab, escape, none
    }
}

/// The almanac palette, in 24-bit ANSI. The page keeps the terminal's own
/// background — painting a cream ground over someone's terminal theme is rude,
/// and the ink is carried by the accent and the greys instead.
enum Ink {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let italic = "\u{1B}[3m"
    static let reverse = "\u{1B}[7m"

    static func fg(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{1B}[38;2;\(r);\(g);\(b)m" }
    static func bg(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{1B}[48;2;\(r);\(g);\(b)m" }

    static let accent = fg(204, 106, 76)      // terracotta, the dark-paper tone
    static let accentBG = bg(156, 50, 32)
    static let muted = fg(147, 135, 111)
    static let rule = fg(82, 74, 62)
    static let green = fg(130, 162, 107)

    static func smallCaps(_ s: String) -> String {
        muted + s.uppercased() + reset
    }
}
