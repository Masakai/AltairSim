import XCTest
@testable import AltairCore

/// 別のプログラムを動かした後でも、メモリを消して起動し直せば BASIC が立ち上がること。
/// (メモリを消さないと BASIC は何も出力せずに止まる。電源投入直後のメモリは 0 の前提で作られているため)
final class BootAfterOtherProgramTests: XCTestCase {
    func testBasicBootsAfterZork() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AltairSim/Resources")
        let disk = base.appendingPathComponent("disks/zork.dsk")
        guard FileManager.default.fileExists(atPath: disk.path) else { throw XCTSkip("zork.dsk がありません") }
        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: disk))), drive: 0)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: base.appendingPathComponent("roms/88dskrom.bin"))), at: 0xFF00)
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00; m.examine(); m.start()
        for _ in 0..<150 { m.run(cycles: 100_000) }
        for u in "ZORK1\r".utf8 { m.sendSerial(u) }
        for _ in 0..<400 { m.run(cycles: 100_000) }

        m.stop(); m.reset(); m.removeROMs(); m.setRAMSize(0x8000); m.clearMemory()
        var a: UInt16 = 0xE000
        for n in ["8kBas_e0.bin", "8kBas_e8.bin", "8kBas_f0.bin", "8kBas_f8.bin"] {
            let b = [UInt8](try Data(contentsOf: base.appendingPathComponent("roms/\(n)")))
            m.loadROM(b, at: a); a &+= UInt16(b.count)
        }
        out = ""
        m.switches = 0xE000; m.examine(); m.start()
        for _ in 0..<60 { m.run(cycles: 100_000) }
        XCTAssertTrue(out.contains("MEMORY SIZE?"), out)
    }
}
