import XCTest
@testable import AltairCore

/// 680b に FD3712 と 68-UIO を付けて、本物の起動 PROM(BOOT.S19)と FLEX 3.0 / CP/68 のディスクイメージを動かす。
final class DiskOS680Tests: XCTestCase {
    private let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AltairSim/Resources/altair680")

    private func boot(image name: String, speed: Int = 500_000) throws -> (Altair680Machine, DiskImage, () -> String) {
        let files = ["monitor/SWIMON.S19", "boot/BOOT.S19", "disks/\(name)"]
        for f in files where !FileManager.default.fileExists(atPath: base.appendingPathComponent(f).path) {
            throw XCTSkip("\(f) がありません")
        }
        let m = Altair680Machine(ramSize: 0xC000)
        m.uioInstalled = true
        try m.loadS19(String(contentsOf: base.appendingPathComponent("monitor/SWIMON.S19"), encoding: .utf8))
        try m.loadS19(String(contentsOf: base.appendingPathComponent("boot/BOOT.S19"), encoding: .utf8))
        // 書き込みで元ファイルを変えないよう、メモリ上のコピーを使う
        let image = try DiskImage(bytes: [UInt8](try Data(contentsOf: base.appendingPathComponent("disks/\(name)"))), geometry: .ibm3740)
        m.disks.mount(image, drive: 0)
        var out = [UInt8]()
        m.onSerialOutput = { out.append($0 & 0x7F) }
        m.reset()
        m.setRunning(true)
        m.run(cycles: 200_000)
        for u in "JFC00".utf8 { m.sendSerial(u) }
        return (m, image, { String(decoding: out.map { $0 == 0x0D ? UInt8(ascii: "\n") : $0 }, as: UTF8.self) })
    }

    func testBootsFLEX3() throws {
        let (m, image, text) = try boot(image: "flex3-680.dsk")
        // LINK.CMD と同じ処理: ブートローダ(トラック 0 セクタ 1)の 5・6 バイト目に、FLEX3.SYS の開始位置(トラック 17、セクタ 12)を書く
        XCTAssertEqual(FLEXImage.findFile(image, name: "FLEX3", ext: "SYS").map { [$0.track, $0.sector] }, [17, 12])
        XCTAssertTrue(FLEXImage.linkBootLoader(image))
        XCTAssertEqual([image.bytes[5], image.bytes[6]], [17, 12])
        XCTAssertFalse(FLEXImage.linkBootLoader(image), "2 回目は何もしない")
        var log: [String] = []
        m.disks.onCommand = { c, d, dr, tr, sc in log.append(String(format: "cmd %02X data %02X (drive %d track %d sector %d)", c, d, dr, tr, sc)) }
        defer { XCTAssertGreaterThan(log.count, 100, "FLEX の読み込みでコマンドが十分発行された") }
        m.run(cycles: 20_000_000)                      // 40 秒分(500kHz)
        XCTAssertTrue(text().contains("6800 FLEX V3.0"), text())
        XCTAssertTrue(text().contains("DATE (MM,DD,YY)?"), text())
        for u in "10,08,26\r".utf8 { m.sendSerial(u) }
        m.run(cycles: 3_000_000)
        for u in "CAT\r".utf8 { m.sendSerial(u) }
        m.run(cycles: 20_000_000)
        print("--- FLEX 3.0 boot ---\n\(text())\n--- pc=\(String(m.cpu.pc, radix: 16)) illegal=\(m.cpu.illegalCount) commands=\(log.count) ---")
    }

    func testBootsCP68() throws {
        let (m, _, text) = try boot(image: "cp68-altair680.dsk")
        m.run(cycles: 40_000_000)
        XCTAssertTrue(text().contains("CP/68"), text())
        for cmd in ["DIR\r", "A:\r", "DIR\r", "STAT\r"] {
            for u in cmd.utf8 { m.sendSerial(u) }
            m.run(cycles: 15_000_000)
        }
        XCTAssertTrue(text().contains("DIRECTORY OF DRIVE 0"), text())
        XCTAssertTrue(text().contains("CP68    .SYS"), text())
        print("--- CP/68 boot ---\n\(text())\n--- pc=\(String(m.cpu.pc, radix: 16)) illegal=\(m.cpu.illegalCount) ---")
    }
}
