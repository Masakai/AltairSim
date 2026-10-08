import XCTest
@testable import AltairCore

/// テスト用の最小のバス: 64KB、ROM の書き込み保護、$F000〜$F002 に ACIA(6850)とストラップ
final class TestBus6800: Bus {
    var memory = [UInt8](repeating: 0, count: 65536)
    var romStart = 0xFF00
    var ramLimit = 0x8000  // RAM は $0000〜(ramLimit-1)。それ以外で ROM でない所は 0xFF が読める
    var input: [UInt8] = []
    var output: [UInt8] = []
    var straps: UInt8 = 0x00  // bit7 = 1 で「端末なし」
    var acia = 0

    func read(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0xF000: return 0x02 | (input.isEmpty ? 0 : 0x01)  // TDRE は常に 1、RDRF は入力しだい
        case 0xF001: return input.isEmpty ? 0 : input.removeFirst()
        case 0xF002: return straps
        default:
            let a = Int(addr)
            if a < ramLimit || a >= romStart { return memory[a] }
            return 0xFF
        }
    }

    func write(_ addr: UInt16, _ value: UInt8) {
        switch addr {
        case 0xF000: acia = Int(value)
        case 0xF001: output.append(value)
        default:
            if Int(addr) < ramLimit { memory[Int(addr)] = value }
        }
    }

    func input(_ port: UInt8) -> UInt8 { 0xFF }
    func output(_ port: UInt8, _ value: UInt8) {}

    func load(_ bytes: [UInt8], at addr: Int) {
        for (i, b) in bytes.enumerated() { memory[addr + i] = b }
    }
}

final class CPU6800Tests: XCTestCase {
    /// CPU はバスを unowned で持つので、テストの間は生かしておく
    private var buses: [TestBus6800] = []

    /// 0100h からプログラムを置いて、指定命令数だけ実行する
    private func run(_ program: [UInt8], steps: Int, setup: ((CPU6800, TestBus6800) -> Void)? = nil) -> (CPU6800, TestBus6800) {
        let bus = TestBus6800()
        buses.append(bus)
        bus.load(program, at: 0x0100)
        let cpu = CPU6800(bus: bus)
        cpu.pc = 0x0100
        cpu.sp = 0x01FF
        setup?(cpu, bus)
        for _ in 0..<steps { cpu.step() }
        return (cpu, bus)
    }

    func testLoadAndFlags() {
        let (cpu, _) = run([0x86, 0x80], steps: 1)  // LDAA #$80
        XCTAssertEqual(cpu.a, 0x80)
        XCTAssertTrue(cpu.n)
        XCTAssertFalse(cpu.z)
        XCTAssertFalse(cpu.v)
    }

    func testAddOverflowAndHalfCarry() {
        let (cpu, _) = run([0x86, 0x7F, 0x8B, 0x01], steps: 2)  // LDAA #7F / ADDA #1
        XCTAssertEqual(cpu.a, 0x80)
        XCTAssertTrue(cpu.v)
        XCTAssertTrue(cpu.h)
        XCTAssertTrue(cpu.n)
        XCTAssertFalse(cpu.c)
    }

    func testAddCarryAndZero() {
        let (cpu, _) = run([0x86, 0xFF, 0x8B, 0x01], steps: 2)
        XCTAssertEqual(cpu.a, 0)
        XCTAssertTrue(cpu.c)
        XCTAssertTrue(cpu.z)
        XCTAssertTrue(cpu.h)
        XCTAssertFalse(cpu.v)
    }

    func testSubOverflowAndBorrow() {
        let (cpu, _) = run([0x86, 0x80, 0x80, 0x01], steps: 2)  // SUBA #1
        XCTAssertEqual(cpu.a, 0x7F)
        XCTAssertTrue(cpu.v)
        XCTAssertFalse(cpu.c)
        let (cpu2, _) = run([0x86, 0x00, 0x80, 0x01], steps: 2)
        XCTAssertEqual(cpu2.a, 0xFF)
        XCTAssertTrue(cpu2.c)
        XCTAssertTrue(cpu2.n)
    }

    func testCompareDoesNotChangeAccumulator() {
        let (cpu, _) = run([0x86, 0x05, 0x81, 0x05], steps: 2)  // CMPA #5
        XCTAssertEqual(cpu.a, 5)
        XCTAssertTrue(cpu.z)
        XCTAssertFalse(cpu.c)
    }

    func testLogicalOpsKeepCarry() {
        let (cpu, _) = run([0x0D, 0x86, 0xF0, 0x84, 0x3C], steps: 3)  // SEC / LDAA #F0 / ANDA #3C
        XCTAssertEqual(cpu.a, 0x30)
        XCTAssertTrue(cpu.c, "AND は C を変えない")
        XCTAssertFalse(cpu.v)
    }

    func testDAA() {
        let (cpu, _) = run([0x86, 0x15, 0x8B, 0x27, 0x19], steps: 3)  // 15 + 27 → DAA = 42
        XCTAssertEqual(cpu.a, 0x42)
        XCTAssertFalse(cpu.c)
        let (cpu2, _) = run([0x86, 0x99, 0x8B, 0x01, 0x19], steps: 3)  // 99 + 01 → DAA = 00、キャリー
        XCTAssertEqual(cpu2.a, 0x00)
        XCTAssertTrue(cpu2.c)
    }

    func testShiftsAndRotates() {
        let (cpu, _) = run([0x86, 0x81, 0x48], steps: 2)  // ASLA: 81 → 02、C=1、V = N^C = 1
        XCTAssertEqual(cpu.a, 0x02)
        XCTAssertTrue(cpu.c)
        XCTAssertTrue(cpu.v)
        let (cpu2, _) = run([0x86, 0x81, 0x47], steps: 2)  // ASRA: 81 → C0、C=1
        XCTAssertEqual(cpu2.a, 0xC0)
        XCTAssertTrue(cpu2.c)
        let (cpu3, _) = run([0x0D, 0x86, 0x01, 0x46], steps: 3)  // SEC / RORA: 01 → 80、C=1
        XCTAssertEqual(cpu3.a, 0x80)
        XCTAssertTrue(cpu3.c)
        let (cpu4, _) = run([0x0D, 0x86, 0x80, 0x49], steps: 3)  // SEC / ROLA: 80 → 01、C=1
        XCTAssertEqual(cpu4.a, 0x01)
        XCTAssertTrue(cpu4.c)
        let (cpu5, _) = run([0x86, 0x03, 0x44], steps: 2)  // LSRA: 03 → 01、C=1、N=0
        XCTAssertEqual(cpu5.a, 0x01)
        XCTAssertTrue(cpu5.c)
        XCTAssertFalse(cpu5.n)
    }

    func testNegIncDec() {
        let (cpu, _) = run([0x86, 0x80, 0x40], steps: 2)  // NEGA: 80 → 80、V=1、C=1
        XCTAssertEqual(cpu.a, 0x80)
        XCTAssertTrue(cpu.v)
        XCTAssertTrue(cpu.c)
        let (cpu2, _) = run([0x86, 0x7F, 0x4C], steps: 2)  // INCA: 7F → 80、V=1
        XCTAssertEqual(cpu2.a, 0x80)
        XCTAssertTrue(cpu2.v)
        let (cpu3, _) = run([0x86, 0x80, 0x4A], steps: 2)  // DECA: 80 → 7F、V=1
        XCTAssertEqual(cpu3.a, 0x7F)
        XCTAssertTrue(cpu3.v)
        let (cpu4, _) = run([0x0D, 0x86, 0xFF, 0x4C], steps: 3)  // SEC / INCA: FF → 00、C は変わらない
        XCTAssertEqual(cpu4.a, 0)
        XCTAssertTrue(cpu4.z)
        XCTAssertTrue(cpu4.c)
    }

    func testComClrTst() {
        let (cpu, _) = run([0x0C, 0x86, 0x0F, 0x43], steps: 3)  // CLC / COMA: 0F → F0、C=1
        XCTAssertEqual(cpu.a, 0xF0)
        XCTAssertTrue(cpu.c)
        let (cpu2, _) = run([0x86, 0x55, 0x4F], steps: 2)  // CLRA
        XCTAssertEqual(cpu2.a, 0)
        XCTAssertTrue(cpu2.z)
        XCTAssertFalse(cpu2.n)
        let (cpu3, _) = run([0x0D, 0x86, 0x80, 0x4D], steps: 3)  // SEC / TSTA: N=1、C=0
        XCTAssertTrue(cpu3.n)
        XCTAssertFalse(cpu3.c)
    }

    func testMemoryUnaryAndAddressingModes() {
        // LDX #0200 / CLR 5,X / INC 5,X / INC 0200+5(拡張)/ LDAA 5,X
        let (cpu, bus) = run([0xCE, 0x02, 0x00, 0x6F, 0x05, 0x6C, 0x05, 0x7C, 0x02, 0x05, 0xA6, 0x05], steps: 5)
        XCTAssertEqual(bus.memory[0x0205], 2)
        XCTAssertEqual(cpu.a, 2)
        // ダイレクト: STAA $20 / LDAB $20
        let (cpu2, bus2) = run([0x86, 0x5A, 0x97, 0x20, 0xD6, 0x20], steps: 3)
        XCTAssertEqual(bus2.memory[0x20], 0x5A)
        XCTAssertEqual(cpu2.b, 0x5A)
    }

    func testBranchesAndLoop() {
        // LDAB #3 / (loop) DECB / BNE loop / LDAA #1
        let (cpu, _) = run([0xC6, 0x03, 0x5A, 0x26, 0xFD, 0x86, 0x01], steps: 8)
        XCTAssertEqual(cpu.b, 0)
        XCTAssertEqual(cpu.a, 1)
    }

    func testSignedBranchConditions() {
        // LDAA #FF(-1)/ CMPA #01 / Bxx +2 / LDAA #11 / LDAA #22
        let (cpu, _) = run([0x86, 0xFF, 0x81, 0x01, 0x2D, 0x02, 0x86, 0x11, 0x86, 0x22], steps: 4)
        XCTAssertEqual(cpu.a, 0x22, "-1 < 1 なので BLT が成立して LDAA #11 を飛ばす")
        let (cpu2, _) = run([0x86, 0xFF, 0x81, 0x01, 0x2E, 0x02, 0x86, 0x11, 0x86, 0x22], steps: 4)
        XCTAssertEqual(cpu2.a, 0x11, "BGT は不成立なので LDAA #11 が実行される")
        let (cpu3, _) = run([0x86, 0xFF, 0x81, 0x01, 0x23, 0x02, 0x86, 0x11, 0x86, 0x22], steps: 4)
        XCTAssertEqual(cpu3.a, 0x11, "符号なしでは FF > 01 なので BLS は不成立")
    }

    func testJSRRTSStackLayout() {
        // LDS #0100 / JSR $0120 / LDAA #7 / WAI ... 0120: RTS
        let (cpu, bus) = run([0x8E, 0x01, 0x00, 0xBD, 0x01, 0x20, 0x86, 0x07, 0x3E]
            + [UInt8](repeating: 0x01, count: 0x20 - 9) + [0x39], steps: 2)
        XCTAssertEqual(cpu.pc, 0x0120)
        XCTAssertEqual(cpu.sp, 0x00FE)
        XCTAssertEqual(bus.memory[0x0100], 0x06, "戻り番地の下位は SP が指していた番地")
        XCTAssertEqual(bus.memory[0x00FF], 0x01, "戻り番地の上位はその 1 つ下")
        cpu.step()  // RTS
        XCTAssertEqual(cpu.pc, 0x0106)
        XCTAssertEqual(cpu.sp, 0x0100)
    }

    func testBSR() {
        // 0100 LDS #0100 / 0103 BSR +2 → 0107(RTS)。戻り番地は 0105
        let (cpu, bus) = run([0x8E, 0x01, 0x00, 0x8D, 0x02, 0x01, 0x01, 0x39], steps: 2)
        XCTAssertEqual(cpu.pc, 0x0107)
        XCTAssertEqual(cpu.sp, 0x00FE)
        XCTAssertEqual(bus.memory[0x0100], 0x05)
        XCTAssertEqual(bus.memory[0x00FF], 0x01)
    }

    func testIndexRegisterOps() {
        // LDX #FFFF / INX → 0000 Z=1 / DEX → FFFF
        let (cpu, _) = run([0xCE, 0xFF, 0xFF, 0x08], steps: 2)
        XCTAssertEqual(cpu.x, 0)
        XCTAssertTrue(cpu.z)
        let (cpu2, _) = run([0xCE, 0x12, 0x34, 0x8C, 0x12, 0x34], steps: 2)  // CPX #1234
        XCTAssertTrue(cpu2.z)
        XCTAssertFalse(cpu2.v)
        // TXS / TSX: SP = X-1、X = SP+1
        let (cpu3, _) = run([0xCE, 0x03, 0x00, 0x35, 0x30], steps: 3)
        XCTAssertEqual(cpu3.sp, 0x02FF)
        XCTAssertEqual(cpu3.x, 0x0300)
        // STX / LDX 拡張
        let (cpu4, bus4) = run([0xCE, 0xAB, 0xCD, 0xFF, 0x02, 0x00, 0xCE, 0x00, 0x00, 0xFE, 0x02, 0x00], steps: 4)
        XCTAssertEqual(bus4.memory[0x0200], 0xAB)
        XCTAssertEqual(bus4.memory[0x0201], 0xCD)
        XCTAssertEqual(cpu4.x, 0xABCD)
    }

    func testPushPullAndTransfers() {
        let (cpu, _) = run([0x86, 0x42, 0x36, 0x4F, 0x32], steps: 4)  // PSHA / CLRA / PULA
        XCTAssertEqual(cpu.a, 0x42)
        let (cpu2, _) = run([0x86, 0x80, 0x16], steps: 2)  // TAB: N=1
        XCTAssertEqual(cpu2.b, 0x80)
        XCTAssertTrue(cpu2.n)
        let (cpu3, _) = run([0x86, 0x05, 0xC6, 0x03, 0x10], steps: 3)  // SBA: 5-3
        XCTAssertEqual(cpu3.a, 2)
        let (cpu4, _) = run([0x86, 0x05, 0xC6, 0x03, 0x1B], steps: 3)  // ABA
        XCTAssertEqual(cpu4.a, 8)
    }

    func testTAPandTPA() {
        let (cpu, _) = run([0x86, 0xFF, 0x06, 0x07], steps: 3)  // TAP → 全フラグ立つ / TPA
        XCTAssertTrue(cpu.h && cpu.i && cpu.n && cpu.z && cpu.v && cpu.c)
        XCTAssertEqual(cpu.a, 0xFF)
        let (cpu2, _) = run([0x86, 0x00, 0x06, 0x07], steps: 3)
        XCTAssertEqual(cpu2.a, 0xC0, "上位 2 ビットは常に 1")
    }

    func testSWIandRTI() {
        let (cpu, bus) = run([0x86, 0x11, 0xC6, 0x22, 0xCE, 0x33, 0x44, 0x3F], steps: 4) { cpu, bus in
            bus.memory[0xFFFA] = 0x03  // SWI ベクタ → 0300
            bus.memory[0xFFFB] = 0x00
            bus.romStart = 0xFF00
            bus.load([0x3B], at: 0x0300)  // RTI
        }
        XCTAssertEqual(cpu.pc, 0x0300)
        XCTAssertEqual(cpu.sp, 0x01FF - 7)
        XCTAssertTrue(cpu.i)
        // 積まれた順: PC 下位、PC 上位、X 下位、X 上位、A、B、CC
        XCTAssertEqual(bus.memory[0x01FF], 0x08)  // PC = 0108(SWI の次)の下位
        XCTAssertEqual(bus.memory[0x01FE], 0x01)
        XCTAssertEqual(bus.memory[0x01FD], 0x44)
        XCTAssertEqual(bus.memory[0x01FC], 0x33)
        XCTAssertEqual(bus.memory[0x01FB], 0x11)
        XCTAssertEqual(bus.memory[0x01FA], 0x22)
        cpu.step()  // RTI
        XCTAssertEqual(cpu.pc, 0x0108)
        XCTAssertEqual(cpu.sp, 0x01FF)
        XCTAssertEqual(cpu.a, 0x11)
        XCTAssertEqual(cpu.b, 0x22)
        XCTAssertEqual(cpu.x, 0x3344)
    }

    func testWAIandIRQ() {
        let bus = TestBus6800()
        bus.load([0x0E, 0x3E, 0x86, 0x77], at: 0x0100)  // CLI / WAI / LDAA #77
        bus.memory[0xFFF8] = 0x02; bus.memory[0xFFF9] = 0x00  // IRQ → 0200
        bus.load([0x86, 0x99, 0x3B], at: 0x0200)  // LDAA #99 / RTI
        let cpu = CPU6800(bus: bus)
        cpu.pc = 0x0100; cpu.sp = 0x01FF
        cpu.step(); cpu.step()  // CLI, WAI
        XCTAssertTrue(cpu.waiting)
        XCTAssertEqual(cpu.step(), 4, "WAI 中は待機")
        cpu.irq = true
        cpu.step()  // 割り込みを受け付ける(WAI で積み済みなので、積まずにベクタへ)
        XCTAssertFalse(cpu.waiting)
        XCTAssertEqual(cpu.pc, 0x0200)
        XCTAssertEqual(cpu.sp, 0x01FF - 7)
        cpu.irq = false
        cpu.step(); cpu.step()  // LDAA #99 / RTI
        XCTAssertEqual(cpu.pc, 0x0102, "RTI で WAI の次へ戻る")
        cpu.step()
        XCTAssertEqual(cpu.a, 0x77)
    }

    func testIRQMaskedAndNMI() {
        let bus = TestBus6800()
        bus.memory[0xFFF8] = 0x02; bus.memory[0xFFF9] = 0x00
        bus.memory[0xFFFC] = 0x03; bus.memory[0xFFFD] = 0x00
        bus.load([0x01, 0x01, 0x01], at: 0x0100)
        let cpu = CPU6800(bus: bus)
        cpu.pc = 0x0100; cpu.sp = 0x01FF
        cpu.irq = true  // I = 1 のままなので受け付けない
        cpu.step()
        XCTAssertEqual(cpu.pc, 0x0101)
        cpu.nmiPending = true  // NMI はマスクされない
        cpu.step()
        XCTAssertEqual(cpu.pc, 0x0300)
        XCTAssertFalse(cpu.nmiPending)
    }

    func testCycleCounts() {
        let table: [(String, [UInt8], Int)] = [
            ("NOP", [0x01], 2), ("LDAA imm", [0x86, 0], 2), ("LDAA dir", [0x96, 0x20], 3),
            ("LDAA idx", [0xA6, 0], 5), ("LDAA ext", [0xB6, 0x02, 0], 4),
            ("STAA dir", [0x97, 0x20], 4), ("STAA idx", [0xA7, 0], 6), ("STAA ext", [0xB7, 0x02, 0], 5),
            ("LDX imm", [0xCE, 0, 0], 3), ("LDX dir", [0xDE, 0x20], 4), ("LDX idx", [0xEE, 0], 6),
            ("LDX ext", [0xFE, 0x02, 0], 5), ("STX dir", [0xDF, 0x20], 5), ("STX idx", [0xEF, 0], 7),
            ("STX ext", [0xFF, 0x02, 0], 6), ("LDS imm", [0x8E, 0, 0], 3), ("CPX imm", [0x8C, 0, 0], 3),
            ("INX", [0x08], 4), ("TSX", [0x30], 4), ("PSHA", [0x36], 4), ("PULA", [0x32], 4),
            ("INCA", [0x4C], 2), ("INC idx", [0x6C, 0], 7), ("INC ext", [0x7C, 0x02, 0], 6),
            ("CLR idx", [0x6F, 0], 7), ("CLR ext", [0x7F, 0x02, 0], 6), ("TST idx", [0x6D, 0], 7),
            ("JMP idx", [0x6E, 0], 4), ("JMP ext", [0x7E, 0x01, 0x10], 3),
            ("BRA", [0x20, 0], 4), ("BEQ not taken", [0x27, 0], 4),
            ("BSR", [0x8D, 0], 8), ("JSR idx", [0xAD, 0], 8), ("JSR ext", [0xBD, 0x01, 0x10], 9),
            ("RTS", [0x39], 5), ("ABA", [0x1B], 2), ("DAA", [0x19], 2),
        ]
        for (name, bytes, expected) in table {
            let (cpu, _) = run(bytes, steps: 0) { cpu, bus in cpu.sp = 0x01F0 }
            XCTAssertEqual(cpu.step(), expected, name)
        }
        let (cpu, _) = run([0x3B], steps: 0)
        XCTAssertEqual(cpu.step(), 10, "RTI")
        let (cpu2, _) = run([0x3F], steps: 0)
        XCTAssertEqual(cpu2.step(), 12, "SWI")
        let (cpu3, _) = run([0x3E], steps: 0)
        XCTAssertEqual(cpu3.step(), 9, "WAI")
    }

    func testIllegalOpcodesAreCountedAsNOP() {
        let (cpu, _) = run([0x00, 0x02, 0x03, 0x04], steps: 4)
        XCTAssertEqual(cpu.illegalCount, 4)
        XCTAssertEqual(cpu.pc, 0x0104)
        XCTAssertEqual(cpu.lastIllegal, 0x04)
    }
}
