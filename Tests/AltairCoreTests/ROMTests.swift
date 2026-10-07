import XCTest
@testable import AltairCore

final class ROMTests: XCTestCase {
    private let romDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AltairSim/Resources/roms")

    private func rom(_ name: String) throws -> [UInt8] {
        let url = romDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name) がありません") }
        return [UInt8](try Data(contentsOf: url))
    }

    func testROMIsWriteProtectedAndUnmappedReadsFF() {
        let m = AltairMachine(ramSize: 0x8000)
        m.loadROM([0x11, 0x22], at: 0xE000)
        m.write(0xE000, 0x99)
        m.write(0x9000, 0x99)
        XCTAssertEqual(m.read(0xE000), 0x11)
        XCTAssertEqual(m.read(0x9000), 0xFF)
        m.write(0x0010, 0x55)
        XCTAssertEqual(m.read(0x0010), 0x55)
    }

    func testBasic8KROMBootsAndAnswers() throws {
        let m = AltairMachine(ramSize: 0x8000)
        var addr: UInt16 = 0xE000
        for name in ["8kBas_e0.bin", "8kBas_e8.bin", "8kBas_f0.bin", "8kBas_f8.bin"] {
            let b = try rom(name)
            m.loadROM(b, at: addr)
            addr &+= UInt16(b.count)
        }
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xE000
        m.examine()
        m.runStop()

        func feed(_ text: String) {
            for u in text.utf8 { m.sendSerial(u) }
        }
        func pump(_ n: Int = 40) {
            for _ in 0..<n { m.run(cycles: 100_000) }
        }
        pump()
        print("--- after boot --- pc=\(String(m.cpu.pc, radix: 16)) halted=\(m.cpu.halted) running=\(m.running) sp=\(String(m.cpu.sp, radix: 16))\n\(out)")
        feed("\r"); pump()   // MEMORY SIZE?
        feed("\r"); pump()   // TERMINAL WIDTH?
        feed("N\r"); pump()   // WANT SIN-COS-TAN-ATN?
        feed("PRINT 2+3\r"); pump()
        print("--- final ---\n\(out)")
        XCTAssertTrue(out.contains("MEMORY SIZE"), out)
        XCTAssertTrue(out.contains("PRINT 2+3\r\n 5"), out)
    }
}
