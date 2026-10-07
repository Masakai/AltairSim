import XCTest
@testable import AltairCore

final class CPM3Tests: XCTestCase {
    private let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AltairSim/Resources")

    func testBootsCPM3() throws {
        let d1 = base.appendingPathComponent("disks/cpm3_v1.0_56K_disk1.dsk")
        let d2 = base.appendingPathComponent("disks/cpm3_v1.0_56k_disk2.dsk")
        let rom = base.appendingPathComponent("roms/88dskrom.bin")
        guard FileManager.default.fileExists(atPath: d1.path) else { throw XCTSkip("CP/M 3 ディスクがありません") }

        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: d1))), drive: 0)
        m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: d2))), drive: 1)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: rom)), at: 0xFF00)

        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00
        m.examine()
        m.start()
        for _ in 0..<400 { m.run(cycles: 100_000) }
        print("--- CP/M 3 boot ---\n\(out)\n--- pc=\(String(m.cpu.pc, radix: 16)) running=\(m.running) halted=\(m.cpu.halted) ---")

        func type(_ text: String, ticks: Int = 100) {
            for u in text.utf8 { m.sendSerial(u) }
            for _ in 0..<ticks { m.run(cycles: 100_000) }
        }
        type("DIR\r")
        print("--- after DIR ---\n\(out)")
        XCTAssertTrue(out.contains("CP/M"), out)
        XCTAssertTrue(out.contains("A>"), out)
        XCTAssertTrue(out.contains("MBASIC"), out)

        // ドライブ B(disk2)への書き込みと読み出し
        out = ""
        type("PIP B:READ2.TXT=A:README.TXT\r", ticks: 150)
        type("DIR B:READ2.TXT\r")
        print("--- after PIP ---\n\(out)")
        XCTAssertTrue(out.contains("READ2"), out)

        // MBASIC(Microsoft BASIC-80)が CP/M 3 でも動く
        out = ""
        type("MBASIC\r", ticks: 150)
        type("PRINT 2+3\r")
        type("SYSTEM\r")
        print("--- after MBASIC ---\n\(out)")
        XCTAssertTrue(out.contains(" 5 "), out)
    }
}
