import XCTest
@testable import AltairCore

final class CPMTests: XCTestCase {
    private let base = AssetLibrary.defaultRoot

    func testBootsCPM22FromDiskBootloader() throws {
        let diskURL = base.appendingPathComponent("disks/cpm22b23-56k.dsk")
        let romURL = base.appendingPathComponent("roms/88dskrom.bin")
        guard FileManager.default.fileExists(atPath: diskURL.path) else { throw XCTSkip("CP/M ディスクがありません") }

        // 書き込みで元ファイルを変えないよう、メモリ上のコピーを使う
        let disk = try DiskImage(bytes: [UInt8](try Data(contentsOf: diskURL)))
        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(disk, drive: 0)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: romURL)), at: 0xFF00)

        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00
        m.examine()
        m.start()
        for _ in 0..<300 { m.run(cycles: 100_000) }
        print("--- CP/M boot ---\n\(out)\n--- pc=\(String(m.cpu.pc, radix: 16)) running=\(m.running) ---")

        func type(_ text: String) {
            for u in text.utf8 { m.sendSerial(u) }
            for _ in 0..<100 { m.run(cycles: 100_000) }
        }
        type("DIR\r")
        print("--- after DIR ---\n\(out)")
        XCTAssertTrue(out.contains("A>"), out)
        XCTAssertTrue(out.contains("MBASIC"), out)

        // ディスクへの書き込み: PIP でコピーして DIR に現れる
        out = ""
        type("PIP COPY.COM=STAT.COM\r")
        type("DIR COPY.COM\r")
        print("--- after PIP ---\n\(out)")
        XCTAssertTrue(out.contains("COPY"), out)

        // 別プログラムの実行: MBASIC(Microsoft BASIC-80)
        out = ""
        type("MBASIC\r")
        type("PRINT 2+3\r")
        type("SYSTEM\r")
        print("--- after MBASIC ---\n\(out)")
        XCTAssertTrue(out.contains(" 5 "), out)
    }
}

final class CPMMultiDriveTests: XCTestCase {
    private let base = AssetLibrary.defaultRoot

    func testDrivesCAndDAreIndependent() throws {
        let diskURL = base.appendingPathComponent("disks/cpm22b23-56k.dsk")
        let romURL = base.appendingPathComponent("roms/88dskrom.bin")
        guard FileManager.default.fileExists(atPath: diskURL.path) else { throw XCTSkip("CP/M ディスクがありません") }
        let bytes = [UInt8](try Data(contentsOf: diskURL))
        let a = try DiskImage(bytes: bytes), c = try DiskImage(bytes: bytes), d = try DiskImage(bytes: bytes)

        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(a, drive: 0)
        m.disks.mount(c, drive: 2)
        m.disks.mount(d, drive: 3)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: romURL)), at: 0xFF00)

        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00
        m.examine()
        m.start()
        for _ in 0..<100 { m.run(cycles: 100_000) }

        func type(_ text: String) {
            out = ""
            for u in text.utf8 { m.sendSerial(u) }
            for _ in 0..<60 { m.run(cycles: 100_000) }
        }
        type("ERA C:ED.COM\r")
        type("DIR C:ED.COM\r")
        print("--- DIR C:ED.COM after ERA ---\n\(out)")
        XCTAssertTrue(out.contains("No file"), out)

        type("DIR A:ED.COM\r")
        print("--- DIR A:ED.COM ---\n\(out)")
        XCTAssertTrue(out.contains("ED"), out)
        XCTAssertFalse(out.contains("No file"), out)

        type("DIR D:ED.COM\r")
        print("--- DIR D:ED.COM ---\n\(out)")
        XCTAssertTrue(out.contains("ED"), out)
        XCTAssertFalse(out.contains("No file"), out)

        // C: に切り替えて PIP で D: へコピー(別ドライブ間の読み書き)
        type("PIP D:COPY2.COM=C:STAT.COM\r")
        type("DIR D:COPY2.COM\r")
        print("--- DIR D:COPY2.COM ---\n\(out)")
        XCTAssertTrue(out.contains("COPY2"), out)
        type("DIR C:COPY2.COM\r")
        XCTAssertTrue(out.contains("No file"), out)
    }
}
