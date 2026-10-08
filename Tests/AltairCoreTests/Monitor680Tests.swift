import XCTest
@testable import AltairCore

/// 680b の PROM モニタ(ACIA 版)と Altair BASIC を、6800 の CPU で動かす。
/// 実際のプログラムが動くことで、命令の実装全体を確かめる。
final class Monitor680Tests: XCTestCase {
    private let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AltairSim/Resources/altair680")

    private var bus: TestBus6800!
    private var cpu: CPU6800!

    private func boot(ramSize: Int = 0x2000) throws {
        let url = base.appendingPathComponent("monitor/MON680.S19")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("MON680.S19 がありません") }
        bus = TestBus6800()
        bus.ramLimit = ramSize
        for rec in try S19Loader.parse(try String(contentsOf: url, encoding: .utf8)) {
            bus.load(rec.bytes, at: Int(rec.address))
        }
        cpu = CPU6800(bus: bus)
        cpu.reset()
    }

    private func run(cycles: Int) {
        var used = 0
        while used < cycles { used += cpu.step() }
    }

    private var text: String {
        String(decoding: bus.output.map { $0 & 0x7F }, as: UTF8.self)
    }

    private func type(_ s: String, cycles: Int = 200_000) {
        bus.input += Array(s.utf8)
        run(cycles: cycles)
    }

    func testMonitorPrintsPromptAfterReset() throws {
        try boot()
        let vector = UInt16(bus.memory[0xFFFE]) << 8 | UInt16(bus.memory[0xFFFF])
        XCTAssertEqual(cpu.pc, vector, "リセットベクタの指す番地から始まる")
        XCTAssertGreaterThanOrEqual(cpu.pc, 0xFF00)
        run(cycles: 20_000)
        XCTAssertEqual(text, "\r\n.")
        XCTAssertEqual(cpu.illegalCount, 0)
    }

    func testMemoryExamineAndDeposit() throws {
        try boot()
        run(cycles: 20_000)
        bus.output.removeAll()
        type("M0010AB")  // M 0010 → 現在値 00 を表示、AB を書き込む
        XCTAssertEqual(bus.memory[0x0010], 0xAB)
        XCTAssertTrue(text.contains("M 0010 00 AB"), text)
        type("N12")  // 次の番地(0011)へ
        XCTAssertEqual(bus.memory[0x0011], 0x12)
        XCTAssertEqual(cpu.illegalCount, 0)
    }

    func testJumpRunsUserProgram() throws {
        try boot()
        run(cycles: 20_000)
        // 0020: LDAA #$41 / STAA $F001(ACIA データ)/ BRA *(ここで止まる)
        bus.load([0x86, 0x41, 0xB7, 0xF0, 0x01, 0x20, 0xFE], at: 0x0020)
        bus.output.removeAll()
        type("J0020")
        XCTAssertTrue(text.contains("J 0020"), text)
        XCTAssertTrue(bus.output.contains(0x41))
    }

    func testPaperTapeLoadOfBASICAndStartup() throws {
        try boot(ramSize: 0x2000)
        run(cycles: 20_000)
        let basic = base.appendingPathComponent("basic/paper-basic-v1.1-r3.2.s19")
        guard FileManager.default.fileExists(atPath: basic.path) else { throw XCTSkip("BASIC がありません") }
        let tape = try String(contentsOf: basic, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        bus.output.removeAll()
        bus.input += Array("L".utf8)
        run(cycles: 2_000)
        // テープを流し込む(ACIA は受信バッファ 1 バイトなので、読み出されるまで進めながら送る)
        for u in tape.utf8 {
            bus.input.append(u)
            var guardCount = 0
            while !bus.input.isEmpty && guardCount < 100_000 { cpu.step(); guardCount += 1 }
        }
        run(cycles: 200_000)
        XCTAssertTrue(text.hasSuffix("\r\n."), "S9 で読み込みが終わってプロンプトに戻る: \(text.suffix(40))")
        bus.output.removeAll()
        type("J0000", cycles: 400_000)
        print("--- BASIC startup ---\n\(text)\n--- illegal=\(cpu.illegalCount) pc=\(String(cpu.pc, radix: 16)) ---")
        XCTAssertEqual(cpu.illegalCount, 0)
    }

    /// BASIC を紙テープから読み込んで起動し、プログラムを走らせる(整数、浮動小数点、FOR ループ)
    func testBASICRunsPrograms() throws {
        try boot(ramSize: 0x2000)
        run(cycles: 20_000)
        let basic = base.appendingPathComponent("basic/paper-basic-v1.1-r3.2.s19")
        guard FileManager.default.fileExists(atPath: basic.path) else { throw XCTSkip("BASIC がありません") }
        let tape = try String(contentsOf: basic, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
        bus.input += Array("L".utf8)
        run(cycles: 2_000)
        for u in tape.utf8 {
            bus.input.append(u)
            var n = 0
            while !bus.input.isEmpty && n < 100_000 { cpu.step(); n += 1 }
        }
        run(cycles: 200_000)
        type("J0000", cycles: 400_000)
        type("\r", cycles: 2_000_000)    // MEMORY SIZE?(Return = 自動検出)
        type("\r", cycles: 2_000_000)    // TERMINAL WIDTH?
        type("N\r", cycles: 2_000_000)   // WANT SIN-COS-TAN-ATN?
        XCTAssertTrue(text.contains("MEMORY SIZE?"), text)
        XCTAssertTrue(text.contains("WANT SIN-COS-TAN-ATN?"), text)
        XCTAssertTrue(text.hasSuffix("OK\r\n") || text.contains("BYTES FREE"), text)

        bus.output.removeAll()
        type("PRINT 2+3\r", cycles: 2_000_000)
        XCTAssertTrue(text.contains(" 5"), text)

        bus.output.removeAll()
        type("10 FOR I=1 TO 5:PRINT I*I;:NEXT I\r", cycles: 2_000_000)
        type("RUN\r", cycles: 4_000_000)
        XCTAssertTrue(text.contains("1") && text.contains("4") && text.contains("9") && text.contains("16") && text.contains("25"), text)

        bus.output.removeAll()
        type("PRINT 100/7\r", cycles: 8_000_000)
        XCTAssertTrue(text.contains("14.2857"), text)
        XCTAssertEqual(cpu.illegalCount, 0, "未定義のオペコードに到達していない")
    }
}
