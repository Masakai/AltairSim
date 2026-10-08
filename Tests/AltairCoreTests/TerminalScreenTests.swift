import XCTest
@testable import AltairCore

final class TerminalScreenTests: XCTestCase {
    private func feed(_ s: inout TerminalScreen, _ text: String) {
        for u in text.utf8 { s.put(u) }
    }

    func testPlainTextAndCRLF() {
        var s = TerminalScreen()
        feed(&s, "A>DIR\r\nFILE")
        XCTAssertTrue(s.rowString(0).hasPrefix("A>DIR "))
        XCTAssertTrue(s.rowString(1).hasPrefix("FILE "))
        XCTAssertEqual(s.cursorRow, 1)
        XCTAssertEqual(s.cursorCol, 4)
    }

    func testBackspaceSpaceBackspaceErases() {
        var s = TerminalScreen()
        feed(&s, "DIRX\u{08} \u{08}")  // CP/M の削除表示
        XCTAssertTrue(s.rowString(0).hasPrefix("DIR "))
        XCTAssertEqual(s.cursorCol, 3)
    }

    func testDELIsIgnored() {
        var s = TerminalScreen()
        feed(&s, "AB\u{7F}")
        XCTAssertTrue(s.rowString(0).hasPrefix("AB "))
        XCTAssertEqual(s.cursorCol, 2)
    }

    func testANSIClearAndHome() {
        var s = TerminalScreen()
        feed(&s, "junk\r\nmore")
        feed(&s, "\u{1B}[2J\u{1B}[1;1H")
        XCTAssertEqual(s.rowString(0), String(repeating: " ", count: 80))
        XCTAssertEqual(s.rowString(1), String(repeating: " ", count: 80))
        XCTAssertEqual(s.cursorRow, 0)
        XCTAssertEqual(s.cursorCol, 0)
    }

    func testANSICursorPositionAndEraseLine() {
        var s = TerminalScreen()
        feed(&s, "\u{1B}[5;10HHELLO\u{1B}[5;12H\u{1B}[K")  // 5 行 10 桁に HELLO、12 桁から行末を消去
        XCTAssertEqual(String(s.rowString(4).dropFirst(9).prefix(5)), "HE   ")
        XCTAssertEqual(s.cursorRow, 4)
    }

    func testANSICursorMoves() {
        var s = TerminalScreen()
        feed(&s, "\u{1B}[3;3H\u{1B}[2A\u{1B}[4C\u{1B}[1B\u{1B}[2D")
        XCTAssertEqual(s.cursorRow, 1)   // 行 index 2 → 2 つ上で 0 → 1 つ下で 1
        XCTAssertEqual(s.cursorCol, 4)
    }

    func testScrollAtBottom() {
        var s = TerminalScreen()
        for i in 0..<30 { feed(&s, "L\(i)\r\n") }
        XCTAssertTrue(s.rowString(0).hasPrefix("L7 "), s.rowString(0))
        XCTAssertTrue(s.rowString(22).hasPrefix("L29"), s.rowString(22))
        XCTAssertEqual(s.cursorRow, 23)
    }

    func testWrapAt80Columns() {
        var s = TerminalScreen()
        feed(&s, String(repeating: "X", count: 85))
        XCTAssertEqual(s.rowString(0), String(repeating: "X", count: 80))
        XCTAssertTrue(s.rowString(1).hasPrefix("XXXXX "))
    }

    func testADM3AAddressing() {
        var s = TerminalScreen()
        feed(&s, "\u{1B}=\u{25}\u{2A}Z")  // 行 5、桁 10(0 始まり)
        XCTAssertEqual(Array(s.cells[5])[10], UInt8(ascii: "Z"))
    }

    func testUnknownEscapeIsDropped() {
        var s = TerminalScreen()
        feed(&s, "A\u{1B}[31mB\u{1B}[0mC")
        XCTAssertTrue(s.rowString(0).hasPrefix("ABC "))
    }
}
