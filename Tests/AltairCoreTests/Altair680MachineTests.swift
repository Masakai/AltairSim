import XCTest
@testable import AltairCore

final class Altair680MachineTests: XCTestCase {
    private let base = AssetLibrary.defaultRoot.appendingPathComponent("altair680")

    private func machine(ram: Int = 0x2000) throws -> (Altair680Machine, () -> String) {
        let m = Altair680Machine(ramSize: ram)
        let url = base.appendingPathComponent("monitor/MON680.S19")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("MON680.S19 がありません") }
        try m.loadS19(String(contentsOf: url, encoding: .utf8))
        var out = [UInt8]()
        m.onSerialOutput = { out.append($0 & 0x7F) }
        return (m, { String(decoding: out, as: UTF8.self) })
    }

    func testFrontPanelDepositAndDisplay() throws {
        let (m, _) = try machine()
        m.addressSwitches = 0x0040
        m.dataSwitches = 0xA5
        m.deposit()
        XCTAssertEqual(m.peek(0x0040), 0xA5)
        XCTAssertEqual(m.addressLEDs, 0x0040, "HALT 中のアドレス LED はアドレススイッチ")
        XCTAssertEqual(m.dataLEDs, 0xA5, "データ LED はその番地の中身")
        m.addressSwitches = 0x0041
        XCTAssertEqual(m.dataLEDs, 0x00)
    }

    func testDepositIgnoredForROMAndWhileRunning() throws {
        let (m, _) = try machine()
        m.addressSwitches = 0xFF00
        m.dataSwitches = 0x12
        let before = m.peek(0xFF00)
        m.deposit()
        XCTAssertEqual(m.peek(0xFF00), before, "ROM には書けない")
        m.addressSwitches = 0x0010
        m.setRunning(true)
        m.deposit()
        XCTAssertEqual(m.peek(0x0010), 0, "RUN 中の DEPOSIT は無効")
    }

    func testMonitorPromptWithTerminal() throws {
        let (m, text) = try machine()
        m.noTerminal = false
        m.reset()
        m.setRunning(true)
        m.run(cycles: 30_000)
        XCTAssertEqual(text(), "\r\n.")
    }

    /// フロントパネルだけで使う構成(端末なしストラップ): スイッチで書いたプログラムが 0000 番地から走る
    func testRunsProgramEnteredFromFrontPanel() throws {
        let (m, text) = try machine()
        m.noTerminal = true
        // 0000: LDAA #$5A / STAA $0020 / BRA *
        let program: [UInt8] = [0x86, 0x5A, 0xB7, 0x00, 0x20, 0x20, 0xFE]
        for (i, byte) in program.enumerated() {
            m.addressSwitches = UInt16(i)
            m.dataSwitches = byte
            m.deposit()
        }
        m.reset()
        m.setRunning(true)
        m.run(cycles: 20_000)
        XCTAssertEqual(m.peek(0x0020), 0x5A)
        XCTAssertEqual(text(), "", "端末なしのときは何も出力しない")
        XCTAssertEqual(m.cpu.pc, 0x0005 + 0, "BRA * の自分自身で止まっている")
    }

    func testBASICFromPaperTapeThroughSerial() throws {
        let (m, text) = try machine()
        let tapeURL = base.appendingPathComponent("basic/paper-basic-v1.1-r3.2.s19")
        guard FileManager.default.fileExists(atPath: tapeURL.path) else { throw XCTSkip("BASIC がありません") }
        let tape = try String(contentsOf: tapeURL, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        m.reset()
        m.setRunning(true)
        m.run(cycles: 30_000)
        func send(_ s: String) { for u in s.utf8 { m.sendSerial(u) } }
        send("L" + tape + "J0000")
        m.run(cycles: 6_000_000)
        send("\r"); m.run(cycles: 3_000_000)
        send("\r"); m.run(cycles: 3_000_000)
        send("N\r"); m.run(cycles: 3_000_000)
        send("PRINT 6*7\r"); m.run(cycles: 3_000_000)
        XCTAssertTrue(text().contains("MEMORY SIZE?"), text())
        XCTAssertTrue(text().contains("42"), text())
        XCTAssertEqual(m.cpu.illegalCount, 0)
    }

    func testBaudRateDelaysTransmitReady() throws {
        let (m, _) = try machine()
        m.baudRate = 110  // 1 文字 = 11 ビット = 0.1 秒 = 50,000 クロック(500kHz)
        m.reset()
        m.write(0xF001, 0x41)
        XCTAssertEqual(m.peek(0xF000) & 0x02, 0, "送信中は TDRE = 0")
        m.setRunning(true)
        // 空ループで時間を進める: BRA *
        m.load([0x20, 0xFE], at: 0x0000)
        m.cpu.pc = 0x0000
        m.run(cycles: 30_000)
        XCTAssertEqual(m.peek(0xF000) & 0x02, 0, "0.06 秒後はまだ送信中")
        m.run(cycles: 30_000)
        XCTAssertEqual(m.peek(0xF000) & 0x02, 0x02, "0.1 秒後に TDRE = 1")
    }
}
