import XCTest
@testable import AltairCore

final class IMSAITests: XCTestCase {
    private let lib = AssetLibrary.defaultRoot.appendingPathComponent("imsai")

    private func makeBooted() throws -> (IMSAIMachine, () -> String) {
        let url = lib.appendingPathComponent("disks/imsai-cpm13.dsk")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("imsai-cpm13.dsk がライブラリにありません") }
        let m = IMSAIMachine(ramSize: 0x10000)
        m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: url)), geometry: .ibm3740), drive: 0)
        var out = [UInt8]()
        m.onSerialOutput = { out.append($0 & 0x7F) }
        m.reset()
        m.start()
        return (m, { String(decoding: out.map { $0 == 0x0D ? UInt8(ascii: "\n") : $0 }, as: UTF8.self) })
    }

    func testBootsIMSAICPM() throws {
        let (m, text) = try makeBooted()
        for _ in 0..<400 { m.run(cycles: 100_000) }     // 20 秒ぶん
        print("--- IMSAI boot ---\n\(text())\n--- pc=\(String(m.cpu.pc, radix: 16)) ---")
        XCTAssertTrue(text().contains("IMSAI 16K CP/M VERS 1.31"), text())
    }

    private func type(_ m: IMSAIMachine, _ text: @escaping () -> String, _ s: String, steps: Int = 300) -> String {
        let mark = text().count
        for u in s.utf8 { m.sendSerial(u) }
        for _ in 0..<steps { m.run(cycles: 100_000) }
        return String(text().dropFirst(mark))
    }

    func testCPMCommandsAndDiskWrite() throws {
        let (m, text) = try makeBooted()
        for _ in 0..<300 { m.run(cycles: 100_000) }
        let dir = type(m, text, "DIR\r")
        print("--- DIR ---\n\(dir)")
        XCTAssertTrue(dir.contains("PIP"), dir)
        XCTAssertTrue(dir.contains("STAT"), dir)

        // ディスクへの書き込み: PIP でコピーして DIR に現れる
        _ = type(m, text, "PIP COPY.COM=STAT.COM\r", steps: 600)
        let dir2 = type(m, text, "DIR COPY.COM\r")
        print("--- after PIP ---\n\(dir2)")
        XCTAssertTrue(dir2.contains("COPY"), dir2)

        // 書いたものが、プログラム出力 LED(ポート FF)やセンススイッチと独立に動くこと、STAT が動くこと
        let stat = type(m, text, "STAT\r")
        print("--- STAT ---\n\(stat)")
        XCTAssertTrue(stat.contains("BYTES REMAINING"), stat)
    }

    // MARK: FIF のコマンド(CP/M を使わずに、BIOS と同じ手順でコマンド列を実行する)

    /// BIOS と同じ手順: コマンド列をメモリに作り、ステータスを 0 にして OUT FD、ステータスが変わるまで時間を進める
    private func fifCommand(_ m: IMSAIMachine, _ block: [UInt8], at address: UInt16 = 0x0200, pointer: UInt8 = 1) -> UInt8 {
        for (i, b) in block.enumerated() { m.load([b], at: address + UInt16(i)) }
        m.load([0], at: address + 1)
        m.output(FIFController.port, 0x10 | pointer)           // ポインタ設定
        m.output(FIFController.port, UInt8(address & 0xFF))
        m.output(FIFController.port, UInt8(address >> 8))
        m.output(FIFController.port, pointer)                  // 実行
        m.start()
        // ステータスは、コマンドが終わるまで 0 のまま(CPU を動かさず、時間だけ進める)
        for _ in 0..<2000 where m.peek(address + 1) == 0 { m.run(cycles: 50_000) }
        m.stop()
        return m.peek(address + 1)
    }

    func testFIFFormatUnformattedDiskThenWriteAndRead() throws {
        let m = IMSAIMachine(ramSize: 0x10000)
        m.fifBootEnabled = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imsai-blank-\(UUID().uuidString).dsk")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: DiskImage.formatMapURL(for: url)) }
        let blank = try DiskImage.createBlank(at: url, geometry: .ibm3740, unformatted: true)
        m.disks.mount(blank, drive: 0)
        m.reset()
        let buffer: UInt16 = 0x1000
        // 未フォーマットのセクタは読めない(ファームウェアは 10 回やり直して 93 を返す)
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 5, 3, UInt8(buffer & 0xFF), UInt8(buffer >> 8)]), 0x93)
        // トラック 5 をフォーマットすると、そのトラックのセクタが読める(内容は 0)
        XCTAssertEqual(fifCommand(m, [0x31, 0, 0, 5]), 0x01)
        XCTAssertEqual(blank.unformattedSectorCount, 77 * 26 - 26)
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 5, 3, UInt8(buffer & 0xFF), UInt8(buffer >> 8)]), 0x01)
        // 隣のトラックは未フォーマットのまま
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 6, 3, UInt8(buffer & 0xFF), UInt8(buffer >> 8)]), 0x93)
        // 書いたデータを読み戻せる
        for k in 0..<128 { m.load([UInt8(k ^ 0x5A)], at: 0x2000 + UInt16(k)) }
        XCTAssertEqual(fifCommand(m, [0x11, 0, 0, 5, 3, 0x00, 0x20]), 0x01)
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 5, 3, 0x00, 0x30]), 0x01)
        for k in 0..<128 { XCTAssertEqual(m.peek(0x3000 + UInt16(k)), UInt8(k ^ 0x5A)) }
        // イメージのバイト列の、トラック 5 のセクタ 3(セクタ番号は 1 始まり)の位置に書かれ、隣のセクタは変わらない
        let off = (5 * 26 + (3 - 1)) * 128
        XCTAssertEqual(Array(blank.bytes[off ..< off + 4]), [0x5A, 0x5B, 0x58, 0x59])
        XCTAssertEqual(Array(blank.bytes[off + 128 ..< off + 132]), [0, 0, 0, 0], "次のセクタは変わらない")
    }

    func testFIFErrorCodes() throws {
        let m = IMSAIMachine(ramSize: 0x10000)
        m.fifBootEnabled = false
        let img = DiskImage.blank(geometry: .ibm3740)
        m.disks.mount(img, drive: 0)
        m.reset()
        let buf: [UInt8] = [0x00, 0x10]
        XCTAssertEqual(fifCommand(m, [0x21, 0, 1, 5, 1] + buf), 0xC5, "トラックの上位バイトが 0 でない")
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 77, 1] + buf), 0xC5, "トラック 77 は存在しない")
        XCTAssertEqual(fifCommand(m, [0x20, 0, 0, 5, 1] + buf), 0xC2, "ドライブが選ばれていない")
        XCTAssertEqual(fifCommand(m, [0x23, 0, 0, 5, 1] + buf), 0xC3, "ドライブが複数")
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 5, 0] + buf), 0xC6, "セクタ 0")
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 5, 27] + buf), 0xC6, "セクタ 27")
        XCTAssertEqual(fifCommand(m, [0x61, 0, 0, 5, 1] + buf), 0xC4, "未対応の機能")
        XCTAssertEqual(fifCommand(m, [0x22, 0, 0, 5, 1] + buf), 0xA1, "ドライブ 1 にはディスクがない")
        // 書き込み禁止
        img.writeProtected = true
        XCTAssertEqual(fifCommand(m, [0x11, 0, 0, 5, 1] + buf), 0xA2, "ハードの書き込み禁止")
        img.writeProtected = false
        m.output(FIFController.port, 0x31)                       // ドライブ 0 をソフトの書き込み禁止にする
        XCTAssertEqual(fifCommand(m, [0x11, 0, 0, 5, 1] + buf), 0xA3, "ソフトの書き込み禁止")
        XCTAssertEqual(fifCommand(m, [0x21, 0, 0, 5, 1] + buf), 0x01, "読み出しはできる")
        m.output(FIFController.port, 0x41)                       // 解除
        XCTAssertEqual(fifCommand(m, [0x11, 0, 0, 5, 1] + buf), 0x01)
    }

    func testPanelPortsAndSIO() throws {
        let m = IMSAIMachine(ramSize: 0x10000)
        m.switches = 0xA55A
        XCTAssertEqual(m.input(0xFF), 0xA5, "ポート FF の入力は、上位アドレススイッチ(A8〜A15)")
        m.output(0xFF, 0x3C)
        XCTAssertEqual(m.programmedOutput, 0x3C)
        // SIO-2: チャンネル A(02/03)とチャンネル B(04/05)
        XCTAssertEqual(m.input(0x03) & 0x02, 0, "受信なし")
        m.sendSerial(0x41)
        XCTAssertEqual(m.input(0x03) & 0x02, 0x02, "受信あり(bit1)")
        XCTAssertEqual(m.input(0x05) & 0x02, 0x02, "チャンネル B も同じ端末")
        XCTAssertEqual(m.input(0x02), 0x41)
        XCTAssertEqual(m.input(0x03) & 0x02, 0)
        XCTAssertEqual(m.input(0x03) & 0x01, 0x01, "送信可(bit0)")
        var sent: [UInt8] = []
        m.onSerialOutput = { sent.append($0) }
        m.output(0x02, 0x48); m.output(0x04, 0x49)
        XCTAssertEqual(sent, [0x48, 0x49])
        XCTAssertEqual(m.input(0x77), 0xFF, "未実装のポートは 0xFF")
        // 8251 の制御ポート: 先頭はモード、その次はコマンド
        m.output(0x03, 0x4E); m.output(0x03, 0x37); m.output(0x03, 0x40)  // 内部リセット
        m.output(0x03, 0x4E)  // 次はまたモード
    }

    func testFrontPanelExamineDeposit() throws {
        let m = IMSAIMachine(ramSize: 0x10000)
        m.switches = 0x0100
        m.examine()
        XCTAssertEqual(m.lastAddress, 0x0100)
        m.switches = 0x0100 | 0x00AB     // データは下位 8 スイッチ(A0〜A7)
        m.deposit()
        XCTAssertEqual(m.peek(0x0100), 0xAB)
        m.switches = 0x0001
        m.depositNext()
        XCTAssertEqual(m.peek(0x0101), 0x01)
        XCTAssertEqual(m.lastAddress, 0x0101)
        m.examineNext()
        XCTAssertEqual(m.lastAddress, 0x0102)
    }

    // MARK: ディスクの初期化

    /// 取得元: deramp.com の IMDOS(ライブラリの imsai/cpm/FORMAT.COM)。IMSAI CP/M 1.31 のディスクには入っていない
    private func formatCOM() throws -> [UInt8] {
        let url = lib.appendingPathComponent("cpm/FORMAT.COM")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("imsai/cpm/FORMAT.COM がライブラリにありません") }
        return [UInt8](try Data(contentsOf: url))
    }

    /// IMDOS の FORMAT.COM(IMSAI FORMATTER-INITIALIZER 2.05)は、IMSAI CP/M 1.31 の上では OS のバージョンを確かめて中止する。
    /// つまり CP/M 1.31 には、ディスクをフォーマットする手段がない(ユーザーガイド 6.6: 新しいディスクは初期化なしで使う前提)
    func testIMDOSFormatterRefusesToRunOnCPM131() throws {
        let com = try formatCOM()
        let (m, text) = try makeBooted()
        for _ in 0..<300 { m.run(cycles: 100_000) }
        m.load(com, at: 0x0100)
        m.cpu.pc = 0x0100
        m.cpu.sp = 0x3F00
        let out = type(m, text, "", steps: 300)
        XCTAssertTrue(out.contains("INCOMPATIBLE VERSION OF SYSTEM"), out)
        XCTAssertTrue(out.contains("FORMAT ABORTED"), out)
    }

    /// 「新規の空ディスク」(フォーマット済みで、CP/M のディレクトリが空)を、ドライブ B として CP/M 1.31 で使う
    func testBlankDiskAsDriveBWorksWithCPM() throws {
        let (m, text) = try makeBooted()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imsai-empty-\(UUID().uuidString).dsk")
        defer { try? FileManager.default.removeItem(at: url) }
        let blank = try DiskImage.createBlank(at: url, geometry: .ibm3740, unformatted: false, cpmDirectory: true)
        m.disks.mount(blank, drive: 1)
        for _ in 0..<300 { m.run(cycles: 100_000) }
        _ = type(m, text, "B:\r")
        let dir = type(m, text, "DIR\r")
        XCTAssertFalse(dir.contains("ERROR"), dir)
        XCTAssertTrue(dir.contains("NOT FOUND"), "空のディレクトリは「NOT FOUND」(CP/M 1.31 のファイルなしの表示): \(dir)")
        // ファイルを書く(A: のディスクから B: へコピーする)
        // カレントは B:(空)なので、A: のプログラムは A: と付けて呼ぶ
        _ = type(m, text, "A:PIP B:STAT2.COM=A:STAT.COM\r", steps: 800)
        let dir2 = type(m, text, "DIR\r")
        XCTAssertTrue(dir2.contains("STAT2"), dir2)
        // 書いたものを読み出して、実行できる(コピー先の STAT2.COM を実行)
        let stat = type(m, text, "STAT2\r")
        XCTAssertTrue(stat.contains("BYTES REMAINING"), stat)
    }

    // MARK: ほかの IMSAI 用システムディスクの起動

    /// 設定画面の「ほかの OS で起動」に並ぶディスクが、FIF のブートで起動して DIR が動く(期待する起動メッセージつき)
    func testOtherIMSAISystemDisksBoot() throws {
        let cases: [(file: String, banner: String)] = [
            ("um-cpm13.dsk", "52K CP/M VERS 1.3"),
            ("cpm22.dsk", "54K CP/M VERS 2.2"),
            ("fig80.dsk", "54K CP/M VERS 2.2"),
            ("imdos202.dsk", "54K IMDOS VERS 2.02"),
            ("imdos205r0-1.dsk", "54K IMDOS VERS 2.05"),
            ("imdos205r1-maslin.dsk", "16K IMDOS VERS 2.05 REV 1"),
            ("imdos205r1-peters.dsk", "16K IMDOS VERS 2.05 REV 1"),
        ]
        var tested = 0
        for c in cases {
            let url = lib.appendingPathComponent("disks/\(c.file)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let m = IMSAIMachine(ramSize: 0x10000)
            m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: url)), geometry: .ibm3740), drive: 0)
            var out = [UInt8]()
            m.onSerialOutput = { out.append($0 & 0x7F) }
            m.reset(); m.start()
            for _ in 0..<300 { m.run(cycles: 100_000) }
            for u in "DIR\r".utf8 { m.sendSerial(u) }
            for _ in 0..<200 { m.run(cycles: 100_000) }
            let text = String(decoding: out.map { $0 == 0x0D ? UInt8(ascii: "\n") : $0 }, as: UTF8.self)
            XCTAssertTrue(text.contains(c.banner), "\(c.file): \(text.prefix(200))")
            XCTAssertTrue(text.contains("A:") || text.contains("A: "), "\(c.file): DIR の出力がない: \(text.suffix(200))")
            tested += 1
        }
        if tested == 0 { throw XCTSkip("IMSAI のシステムディスクがライブラリにありません") }
    }
}
