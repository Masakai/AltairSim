import XCTest
@testable import AltairCore

/// HLT の動作(Intel 8080 データシート 2-13〜2-14 ページ、Table 2-1 に基づく)
final class HaltTests: XCTestCase {
    private func machine(_ program: [UInt8]) -> AltairMachine {
        let m = AltairMachine(ramSize: 0x8000)
        m.load(program, at: 0)
        m.reset()
        return m
    }

    func testHaltShowsHLTAAndNextAddress() {
        // NOP / HLT(アドレス 1) → M2 のアドレスは HLT の次の 0002h
        let m = machine([0x00, 0x76])
        m.start()
        m.run(cycles: 100)
        XCTAssertTrue(m.cpu.halted)
        XCTAssertTrue(m.running, "RUN のまま")
        XCTAssertEqual(m.lastAddress, 0x0002)
        XCTAssertEqual(m.status, [.hlta, .memr, .wo])  // ステータスワード ⑨ = 0x8A
        XCTAssertFalse(m.status.contains(.m1))
    }

    func testRunSwitchDoesNotResumeFromHalt() {
        let m = machine([0x76, 0x3E, 0x99, 0x76])  // HLT / MVI A,99h / HLT
        m.start()
        m.run(cycles: 100)
        m.stop()
        m.start()  // STOP → RUN しても HLT 状態は解除されない
        m.run(cycles: 1000)
        XCTAssertTrue(m.cpu.halted)
        XCTAssertEqual(m.cpu.a, 0)
        XCTAssertEqual(m.cpu.pc, 0x0001)
    }

    func testSingleStepDoesNotResumeFromHalt() {
        let m = machine([0x76, 0x3E, 0x99])
        m.start()
        m.run(cycles: 100)
        m.stop()
        m.singleStep()
        XCTAssertTrue(m.cpu.halted)
        XCTAssertEqual(m.cpu.a, 0)
        XCTAssertTrue(m.status.contains(.hlta))
    }

    func testResetLeavesHaltAndRestartsAtZero() {
        let m = machine([0x76])
        m.start()
        m.run(cycles: 100)
        XCTAssertTrue(m.cpu.halted)
        m.reset()
        XCTAssertFalse(m.cpu.halted)
        XCTAssertEqual(m.cpu.pc, 0)
        XCTAssertFalse(m.status.contains(.hlta))
    }

    func testInterruptWithINTELeavesHalt() {
        // LXI SP,1000h / EI / HLT / MVI B,01h / HLT、割り込みサービスは 0038h に置く
        let m = machine([0x31, 0x00, 0x10, 0xFB, 0x76, 0x06, 0x01, 0x76])
        m.load([0x3E, 0x55, 0xFB, 0xC9], at: 0x0038)  // MVI A,55h / EI / RET
        m.start()
        m.run(cycles: 1000)
        XCTAssertTrue(m.cpu.halted)
        XCTAssertTrue(m.cpu.inte)

        XCTAssertTrue(m.requestInterrupt(opcode: 0xFF))  // RST 7
        XCTAssertFalse(m.cpu.inte, "受け付けると INTE は 0")
        m.run(cycles: 1000)
        XCTAssertEqual(m.cpu.a, 0x55, "割り込みサービスが実行された")
        XCTAssertEqual(m.cpu.b, 0x01, "HLT の次の命令から再開した")
        XCTAssertTrue(m.cpu.halted, "最後の HLT で再び停止")
        XCTAssertEqual(m.cpu.pc, 0x0008)
    }

    func testInterruptIgnoredWhenINTEIsZero() {
        // DI / HLT: RESET でしか抜けられない
        let m = machine([0xF3, 0x76, 0x3E, 0x99])
        m.start()
        m.run(cycles: 100)
        XCTAssertTrue(m.cpu.halted)
        XCTAssertFalse(m.requestInterrupt(opcode: 0xFF))
        m.run(cycles: 1000)
        XCTAssertTrue(m.cpu.halted)
        XCTAssertEqual(m.cpu.a, 0)
    }

    func testTimePassesWhileHalted() {
        let m = machine([0x76])
        m.start()
        m.run(cycles: 100)
        let before = m.cycleCounter
        let used = m.run(cycles: 10_000)
        XCTAssertEqual(used, 10_000)
        XCTAssertEqual(m.cycleCounter - before, 10_000)
    }
}
