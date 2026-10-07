import XCTest
@testable import AltairCore

final class RuboutTests: XCTestCase {
    func testBasicRuboutCodes() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AltairSim/Resources/roms")
        for code: UInt8 in [0x08, 0x7F, 0x5F] {
            let m = AltairMachine(ramSize: 0x8000)
            var addr: UInt16 = 0xE000
            for n in ["8kBas_e0.bin", "8kBas_e8.bin", "8kBas_f0.bin", "8kBas_f8.bin"] {
                let b = [UInt8](try Data(contentsOf: dir.appendingPathComponent(n)))
                m.loadROM(b, at: addr); addr &+= UInt16(b.count)
            }
            var out = ""
            m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
            m.switches = 0xE000; m.examine(); m.runStop()
            func feed(_ t: [UInt8]) { t.forEach { m.sendSerial($0) }; for _ in 0..<10 { m.run(cycles: 100_000) } }
            for _ in 0..<40 { m.run(cycles: 100_000) }
            feed([13]); feed([13]); feed(Array("N\r".utf8))
            out = ""
            feed(Array("PRINT 7".utf8) + [0x39, code] + Array("\r".utf8))
            // 0x5F(_)と 0x7F(DEL)は 1 文字削除、0x08 は BASIC が削除として扱わない
            XCTAssertEqual(out.contains(" 7 \r\n"), code != 0x08, "code \(code): \(out)")
        }
    }
}
