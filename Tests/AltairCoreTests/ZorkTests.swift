import XCTest
@testable import AltairCore

final class ZorkTests: XCTestCase {
    private let base = AssetLibrary.defaultRoot

    func testBootsZorkDisk() throws {
        let disk = base.appendingPathComponent("disks/zork.dsk")
        let rom = base.appendingPathComponent("roms/88dskrom.bin")
        guard FileManager.default.fileExists(atPath: disk.path) else { throw XCTSkip("zork.dsk がありません") }

        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: disk))), drive: 0)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: rom)), at: 0xFF00)

        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00
        m.examine()
        m.start()
        for _ in 0..<400 { m.run(cycles: 100_000) }
        print("--- Zork boot ---\n\(out)\n--- pc=\(String(m.cpu.pc, radix: 16)) running=\(m.running) halted=\(m.cpu.halted) ---")

        func type(_ text: String, ticks: Int = 100) {
            for u in text.utf8 { m.sendSerial(u) }
            for _ in 0..<ticks { m.run(cycles: 100_000) }
        }
        type("DIR\r")
        print("--- after DIR ---\n\(out)")
        XCTAssertTrue(out.contains("ZORK1"), out)

        out = ""
        type("ZORK1\r", ticks: 400)
        print("--- ZORK1 start ---\n\(out)")
        XCTAssertTrue(out.contains("ZORK"), out)
        XCTAssertTrue(out.contains("West of House"), out)

        out = ""
        type("OPEN MAILBOX\r", ticks: 100)
        type("READ LEAFLET\r", ticks: 100)
        type("N\r", ticks: 100)
        print("--- Zork play ---\n\(out)")
        XCTAssertTrue(out.contains("leaflet"), out)
    }

    private func boot() throws -> (AltairMachine, () -> String, (String, Int) -> Void, () -> Void) {
        let disk = base.appendingPathComponent("disks/zork.dsk")
        let rom = base.appendingPathComponent("roms/88dskrom.bin")
        guard FileManager.default.fileExists(atPath: disk.path) else { throw XCTSkip("zork.dsk がありません") }
        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: disk))), drive: 0)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: rom)), at: 0xFF00)
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00
        m.examine()
        m.start()
        for _ in 0..<400 { m.run(cycles: 100_000) }
        return (m, { out }, { text, ticks in
            for u in text.utf8 { m.sendSerial(u) }
            for _ in 0..<ticks { m.run(cycles: 100_000) }
        }, { out = "" })
    }

    func testZork2Starts() throws {
        let (_, out, type, clear) = try boot()
        clear()
        type("ZORK2\r", 400)
        print("--- ZORK2 ---\n\(out())")
        XCTAssertTrue(out().contains("ZORK II"), out())
    }

    func testZork3Starts() throws {
        let (_, out, type, clear) = try boot()
        clear()
        type("ZORK3\r", 400)
        print("--- ZORK3 ---\n\(out())")
    }
}
