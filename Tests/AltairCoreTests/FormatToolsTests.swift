import XCTest
@testable import AltairCore

/// 未フォーマットの空ディスクを、各 OS 付属のフォーマット用ツール(CP/M の AFORMAT、FLEX の NEWDISK、CP/68 の INIT)で
/// フォーマットして使えること。ツールは本物(ライブラリに取り込んだディスクイメージの中のもの)を動かす。
final class FormatToolsTests: XCTestCase {
    private let lib = AssetLibrary.defaultRoot

    // MARK: CP/M 2.2(88-DCDD): ゼロ埋めのイメージは未フォーマット → Bad Sector。AFORMAT で使えるようになる

    func testCPMAFORMATFormatsABlankDisk() throws {
        let diskURL = lib.appendingPathComponent("disks/cpm22b23-56k.dsk")
        let romURL = lib.appendingPathComponent("roms/88dskrom.bin")
        guard FileManager.default.fileExists(atPath: diskURL.path), FileManager.default.fileExists(atPath: romURL.path) else { throw XCTSkip("CP/M のディスクまたは 88dskrom がありません") }
        let sys = try DiskImage(bytes: [UInt8](try Data(contentsOf: diskURL)))
        let blank = DiskImage.blank()
        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(sys, drive: 0)
        m.disks.mount(blank, drive: 1)
        m.disks.mount(DiskImage.blank(), drive: 2)      // 未フォーマットのままにしておく、もう 1 枚(ドライブ C)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: romURL)), at: 0xFF00)
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00; m.examine(); m.start()
        for _ in 0..<300 { m.run(cycles: 100_000) }
        func type(_ text: String, steps: Int = 400) -> String {
            let mark = out.count
            for u in (text + "\r").utf8 { m.sendSerial(u) }
            for _ in 0..<steps { m.run(cycles: 100_000) }
            let got = String(out.dropFirst(mark))
            return got
        }

        // カレントドライブを変えずに C: を読む(B: に切り替えると、ウォームブートも B から読もうとして抜けられなくなる)
        XCTAssertTrue(type("DIR C:").contains("Bdos Err On C: Bad Sector"), "未フォーマットのディスクは読めない")
        // ディレクトリの各セクタごとにエラーになり、そのたびにキー入力を待つ。何回か押すと CCP に戻る
        var recovered = false
        for _ in 0..<40 where !recovered {
            recovered = type("", steps: 40).contains("A>")
        }
        XCTAssertTrue(recovered, "キーを押し続けると CCP に戻る")

        XCTAssertTrue(type("AFORMAT B:", steps: 300).contains("Ready (Y/N)?"))
        XCTAssertTrue(type("Y", steps: 1500).contains("Format another (Y/N)?"), "AFORMAT が最後まで終わる")
        XCTAssertTrue(type("N", steps: 300).contains("Ready (Y/N)?"))
        XCTAssertTrue(type("Y", steps: 300).contains("A>"))

        _ = type("PIP B:X.COM=A:STAT.COM", steps: 600)
        let dir = type("DIR B:")
        XCTAssertTrue(dir.contains("X        COM"), dir)
        XCTAssertFalse(dir.contains("Bad Sector"), dir)
        XCTAssertTrue(type("STAT B:").contains("Bytes Remaining On B:"))
    }

    // MARK: 680b 共通

    private let lib680 = AssetLibrary.defaultRoot.appendingPathComponent("altair680")

    /// 680b にディスク OS を入れて起動し、ドライブ 1 に未フォーマットの空ディスクを挿す
    private func boot680(os: String) throws -> (Altair680Machine, DiskImage, (String, Int) -> String) {
        for f in ["monitor/SWIMON.S19", "boot/BOOT.S19", "disks/\(os)"] where !FileManager.default.fileExists(atPath: lib680.appendingPathComponent(f).path) {
            throw XCTSkip("\(f) がライブラリにありません")
        }
        let m = Altair680Machine(ramSize: 0xC000)
        m.uioInstalled = true
        try m.loadS19(String(contentsOf: lib680.appendingPathComponent("monitor/SWIMON.S19"), encoding: .utf8))
        try m.loadS19(String(contentsOf: lib680.appendingPathComponent("boot/BOOT.S19"), encoding: .utf8))
        let sys = try DiskImage(bytes: [UInt8](try Data(contentsOf: lib680.appendingPathComponent("disks/\(os)"))), geometry: .ibm3740)
        if os.hasPrefix("flex") { FLEXImage.linkBootLoader(sys) }
        let blank = try DiskImage(bytes: [UInt8](repeating: 0, count: DiskImage.Geometry.ibm3740.size), geometry: .ibm3740,
                                  formatMap: [Bool](repeating: false, count: 77 * 26))
        m.disks.mount(sys, drive: 0)
        m.disks.mount(blank, drive: 1)
        var out = [UInt8]()
        m.onSerialOutput = { out.append($0 & 0x7F) }
        m.reset(); m.setRunning(true); m.run(cycles: 200_000)
        for u in "JFC00".utf8 { m.sendSerial(u) }
        m.run(cycles: 20_000_000)
        let send: (String, Int) -> String = { text, cycles in
            let mark = out.count
            for u in text.utf8 { m.sendSerial(u) }
            m.run(cycles: cycles)
            return String(decoding: out.dropFirst(mark).map { $0 == 0x0D ? UInt8(ascii: "\n") : $0 }, as: UTF8.self)
        }
        return (m, blank, send)
    }

    // MARK: FLEX 3.0: NEWDISK が全セクタを書いてフォーマットする

    func testFLEXNEWDISKFormatsABlankDisk() throws {
        let (_, blank, send) = try boot680(os: "flex3-680.dsk")
        _ = send("10,08,26\r", 3_000_000)
        XCTAssertEqual(blank.unformattedSectorCount, 77 * 26)
        XCTAssertTrue(send("NEWDISK 1\r", 6_000_000).contains("ARE YOU SURE?"))
        XCTAssertTrue(send("Y\r", 6_000_000).contains("SCRATCH DISK IN DRIVE 1?"))
        XCTAssertTrue(send("Y\r", 6_000_000).contains("VOLUME NAME?"))
        XCTAssertTrue(send("MYDISK\r", 6_000_000).contains("VOLUME NUMBER?"))
        var log = send("1\r", 40_000_000)
        log += send("", 40_000_000)
        XCTAssertTrue(log.contains("FORMATTING COMPLETE"), log)
        XCTAssertEqual(blank.unformattedSectorCount, 0, "NEWDISK は全セクタを書く")
        let cat = send("CAT 1\r", 20_000_000)
        XCTAssertTrue(cat.contains("DISK: MYDISK"), cat)
        XCTAssertTrue(cat.contains("SECTORS LEFT = 988"), cat)
    }

    // MARK: CP/68: INIT(トラック 0 の最終セクタを除く全セクタを書く)

    func testCP68INITInitializesABlankDisk() throws {
        let (_, blank, send) = try boot680(os: "cp68-altair680.dsk")
        XCTAssertTrue(send("INIT 1\r", 6_000_000).contains("INIT. DISK IN DRIVE 1 ?"))
        _ = send("Y\r", 40_000_000)
        _ = send("", 40_000_000)
        XCTAssertLessThanOrEqual(blank.unformattedSectorCount, 1, "INIT はほぼ全セクタを書く(残りは トラック 0 の最終セクタ)")
        let dir = send("DIR 1\r", 20_000_000)
        XCTAssertTrue(dir.contains("DIRECTORY OF DRIVE 1"), dir)
        XCTAssertFalse(dir.contains("ERROR"), dir)
    }
}
