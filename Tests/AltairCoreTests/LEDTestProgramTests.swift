import XCTest
@testable import AltairCore

final class LEDTestProgramTests: XCTestCase {
    /// 一定間隔でパネル相当の値(アドレス・データ・ステータス)をサンプリングする
    private func sample(_ program: [UInt8], seconds: Double) -> [(addr: UInt16, data: UInt8, status: CycleStatus, inte: Bool)] {
        let m = AltairMachine(ramSize: 0x8000)
        m.load(program, at: 0)
        m.reset()
        m.start()
        var out: [(UInt16, UInt8, CycleStatus, Bool)] = []
        let ticks = Int(seconds * 60)
        for _ in 0..<ticks {
            m.run(cycles: AltairMachine.clockHz / 60)
            out.append((m.lastAddress, m.lastData, m.status, m.cpu.inte))
        }
        return out
    }

    func testAddressWalkingBit() {
        let s = sample(LEDTestPrograms.address, seconds: 4)
        let highBytes = Set(s.map { UInt8($0.addr >> 8) })
        for bit in 0..<8 {
            XCTAssertTrue(highBytes.contains(UInt8(1 << bit)), "A\(bit + 8) が点灯しない: \(highBytes)")
        }
    }

    func testDataPatterns() {
        let s = sample(LEDTestPrograms.data, seconds: 6)
        let values = Set(s.map { $0.data })
        for v: UInt8 in [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0xFF, 0xAA, 0x55] {
            XCTAssertTrue(values.contains(v), "データ \(String(v, radix: 16)) が現れない")
        }
    }

    func testStatusLEDs() {
        let s = sample(LEDTestPrograms.status, seconds: 6)
        XCTAssertTrue(s.contains { $0.inte }, "INTE")
        XCTAssertTrue(s.contains { $0.status.contains(.stack) }, "STACK")
        XCTAssertTrue(s.contains { $0.status.contains(.inp) }, "INP")
        XCTAssertTrue(s.contains { $0.status.contains(.out) }, "OUT")
        XCTAssertTrue(s.contains { $0.status.contains(.m1) }, "M1")
        XCTAssertTrue(s.contains { !$0.status.contains(.wo) }, "WO 消灯(書き込み)")
    }

    func testHaltLightsHLTA() {
        let m = AltairMachine(ramSize: 0x8000)
        m.load(LEDTestPrograms.halt, at: 0)
        m.reset()
        m.start()
        m.run(cycles: 100)
        XCTAssertTrue(m.cpu.halted)
        XCTAssertTrue(m.running, "HLT 後も RUN のまま")
        XCTAssertTrue(m.status.contains(.hlta))
    }
}
