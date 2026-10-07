import XCTest
@testable import AltairCore

final class CPUTests: XCTestCase {
    private func machine(_ program: [UInt8]) -> AltairMachine {
        let m = AltairMachine()
        m.load(program, at: 0)
        return m
    }

    private func runUntilHalt(_ m: AltairMachine) {
        m.cpu.reset()
        m.runStop()
        m.run(cycles: 1_000_000)
    }

    func testAddSetsFlags() {
        // MVI A,0F0h / ADI 20h / HLT → 結果 0x10、キャリー
        let m = machine([0x3E, 0xF0, 0xC6, 0x20, 0x76])
        runUntilHalt(m)
        XCTAssertEqual(m.cpu.a, 0x10)
        XCTAssertTrue(m.cpu.cf)
        XCTAssertFalse(m.cpu.zf)
    }

    func testSubBorrowAndAuxCarry() {
        // MVI A,10h / SUI 01h → 0x0F、AC=0(借りあり)
        let m = machine([0x3E, 0x10, 0xD6, 0x01, 0x76])
        runUntilHalt(m)
        XCTAssertEqual(m.cpu.a, 0x0F)
        XCTAssertFalse(m.cpu.cf)
        XCTAssertFalse(m.cpu.acf)
    }

    func testDAA() {
        // 15 + 27 = 42(BCD)
        let m = machine([0x3E, 0x15, 0xC6, 0x27, 0x27, 0x76])
        runUntilHalt(m)
        XCTAssertEqual(m.cpu.a, 0x42)
    }

    func testPushPopPSW() {
        // MVI A,80h / ADD A(Z=1,CY=1,結果0) / PUSH PSW / XRA A / POP PSW
        let m = machine([0x31, 0x00, 0x80, 0x3E, 0x80, 0x87, 0xF5, 0xAF, 0xF1, 0x76])
        runUntilHalt(m)
        XCTAssertEqual(m.cpu.a, 0x00)
        XCTAssertTrue(m.cpu.cf)
        XCTAssertTrue(m.cpu.zf)
    }

    func testCallRet() {
        // LXI SP,8000 / CALL 0008 / HLT / (0008) MVI B,55 / RET
        let m = machine([0x31, 0x00, 0x80, 0xCD, 0x08, 0x00, 0x76, 0x00, 0x06, 0x55, 0xC9])
        runUntilHalt(m)
        XCTAssertEqual(m.cpu.b, 0x55)
        XCTAssertEqual(m.cpu.pc, 0x0007)
    }

    func testDadCarry() {
        // LXI H,FFFF / LXI B,0001 / DAD B → HL=0, CY=1
        let m = machine([0x21, 0xFF, 0xFF, 0x01, 0x01, 0x00, 0x09, 0x76])
        runUntilHalt(m)
        XCTAssertEqual(m.cpu.hl, 0)
        XCTAssertTrue(m.cpu.cf)
    }

    func testHelloProgramOutputsText() {
        let m = machine(DemoPrograms.hello)
        var out: [UInt8] = []
        m.onSerialOutput = { out.append($0) }
        runUntilHalt(m)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "HELLO, ALTAIR\r\n")
        XCTAssertFalse(m.running)
    }

    func testEchoProgram() {
        let m = machine(DemoPrograms.echo)
        var out: [UInt8] = []
        m.onSerialOutput = { out.append($0) }
        m.sendSerial(0x41)
        m.sendSerial(0x42)
        m.cpu.reset()
        m.runStop()
        m.run(cycles: 2_000)
        XCTAssertEqual(out, [0x41, 0x42])
    }

    func testFrontPanelDepositExamine() {
        let m = AltairMachine()
        m.switches = 0x0100
        m.examine()
        m.switches = 0x00AA
        m.deposit()
        m.switches = 0x0055
        m.depositNext()
        m.switches = 0x0100
        m.examine()
        XCTAssertEqual(m.lastData, 0xAA)
        m.examineNext()
        XCTAssertEqual(m.lastData, 0x55)
        XCTAssertEqual(m.lastAddress, 0x0101)
    }

    func testSenseSwitchPort() {
        let m = AltairMachine()
        m.switches = 0xAB12
        XCTAssertEqual(m.input(0xFF), 0xAB)
    }

    func testHexLoader() throws {
        let rec = try HexLoader.parse(":03000000C300003A\n:00000001FF\n")
        XCTAssertEqual(rec.count, 1)
        XCTAssertEqual(rec[0].address, 0)
        XCTAssertEqual(rec[0].bytes, [0xC3, 0x00, 0x00])
    }
}

final class SerialSpeedTests: XCTestCase {
    private func outputCount(baud: Int?, cycles: Int) -> Int {
        let m = AltairMachine(ramSize: 0x8000)
        m.baudRate = baud
        m.load(DemoPrograms.hello, at: 0)
        var count = 0
        m.onSerialOutput = { _ in count += 1 }
        m.cpu.reset()
        m.start()
        m.run(cycles: cycles)
        return count
    }

    func testUnlimitedFinishesImmediately() {
        XCTAssertEqual(outputCount(baud: nil, cycles: 5_000), 15)
    }

    func testTeletype110BaudIsSlow() {
        // 110 ボーは 1 文字 11 ビット = 0.1 秒 = 200,000 クロック。15 文字で約 3,000,000 クロック。
        XCTAssertEqual(outputCount(baud: 110, cycles: 1_000_000), 5)
        XCTAssertEqual(outputCount(baud: 110, cycles: 3_100_000), 15)
    }

    func test9600BaudTakesAboutOneTenthOfThat() {
        // 9600 ボーは 1 文字 10 ビット ≒ 2,083 クロック。
        XCTAssertEqual(outputCount(baud: 9600, cycles: 10_000), 5)
        XCTAssertEqual(outputCount(baud: 9600, cycles: 50_000), 15)
    }
}
