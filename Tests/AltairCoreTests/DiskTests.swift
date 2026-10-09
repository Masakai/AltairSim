import XCTest
@testable import AltairCore

final class DiskTests: XCTestCase {
    /// 先頭にトラック・セクタ番号を入れたテスト用イメージ
    private func testImage() throws -> DiskImage {
        var bytes = [UInt8](repeating: 0, count: DiskImage.size)
        for t in 0..<DiskImage.tracks {
            for s in 0..<DiskImage.sectorsPerTrack {
                let base = (t * DiskImage.sectorsPerTrack + s) * DiskImage.bytesPerSector
                bytes[base] = UInt8(t)
                bytes[base + 1] = UInt8(s)
                bytes[base + 2] = 0xA5
            }
        }
        return try DiskImage(bytes: bytes)
    }

    private func readSector(_ d: DiskController, _ wanted: Int) -> [UInt8] {
        // セクタレジスタを読み進めて目的のセクタまで回す
        for _ in 0..<64 {
            let v = d.read(port: DiskController.sectorPort)!
            if v & 0x01 == 0 && Int(v >> 1) == wanted { break }
        }
        return (0..<DiskImage.bytesPerSector).map { _ in d.read(port: DiskController.dataPort)! }
    }

    /// セクタ真(bit0 = 0)になるまでセクタレジスタを読む。切れ目(bit0 = 1)と区間が交互に返る
    @discardableResult
    private func waitSectorTrue(_ d: DiskController) -> Int {
        for _ in 0..<8 {
            let v = d.read(port: DiskController.sectorPort)!
            if v & 0x01 == 0 { return Int(v >> 1) }
        }
        XCTFail("セクタ真にならない")
        return -1
    }

    func testSectorRegisterAlternatesGapAndSector() throws {
        let d = DiskController()
        d.mount(try testImage(), drive: 0)
        d.reset()
        d.write(port: 0x08, value: 0x00)
        d.write(port: 0x09, value: 0x04)  // ヘッドロード
        var seen: [(sector: Int, gap: Bool)] = []
        for _ in 0..<6 {
            let v = d.read(port: DiskController.sectorPort)!
            seen.append((Int(v >> 1), v & 1 == 1))
        }
        // 切れ目(bit0 = 1、次のセクタの番号)→ 区間(bit0 = 0、同じ番号)の繰り返しで、番号は 0, 1, 2 と進む
        XCTAssertEqual(seen.map(\.gap), [true, false, true, false, true, false])
        XCTAssertEqual(seen.map(\.sector), [0, 0, 1, 1, 2, 2])
    }

    func testWriteWindowEndsAtTheEndOfTheSector() throws {
        let image = try testImage()
        let d = DiskController()
        d.mount(image, drive: 0)
        d.reset()
        d.write(port: 0x08, value: 0x00)
        d.write(port: 0x09, value: 0x04)
        var s = waitSectorTrue(d)
        while s != 31 { s = waitSectorTrue(d) }          // 最後のセクタ
        d.write(port: 0x09, value: 0x80)
        let trackBytes = DiskImage.sectorsPerTrack * DiskImage.bytesPerSector
        let before0 = Array(image.bytes[0..<3])
        for i in 0..<(DiskImage.bytesPerSector + 5) { d.write(port: 0x0A, value: UInt8(0xC0 + i % 16)) }
        XCTAssertEqual(image.bytes[trackBytes - 1], UInt8(0xC0 + (DiskImage.bytesPerSector - 1) % 16), "137 バイト目までは書かれる")
        XCTAssertEqual(Array(image.bytes[0..<3]), before0, "余分に送ったバイトは、次(折り返し先)のセクタを壊さない")
        XCTAssertEqual(image.bytes[trackBytes], 1, "次のトラックにも書かれない(テスト用イメージのトラック 1 の先頭はトラック番号 1)")
    }

    func testUnmountedDriveSelectionFails() {
        let d = DiskController()
        d.reset()
        d.write(port: 0x08, value: 0x00)
        XCTAssertEqual(d.read(port: 0x08), 0xFF)
    }

    func testSelectLoadHeadAndReadSector() throws {
        let d = DiskController()
        d.mount(try testImage(), drive: 0)
        d.reset()
        d.write(port: 0x08, value: 0x00)
        XCTAssertEqual(d.read(port: 0x08)! & 0x08, 0, "ドライブ選択ビットが有効(0)")
        d.write(port: 0x09, value: 0x04)  // ヘッドロード
        XCTAssertEqual(d.read(port: 0x08)! & 0x04, 0, "ヘッドロード済み")
        let s5 = readSector(d, 5)
        XCTAssertEqual(Array(s5[0..<3]), [0, 5, 0xA5])
    }

    func testStepInSelectsTrack() throws {
        let d = DiskController()
        d.mount(try testImage(), drive: 0)
        d.reset()
        d.write(port: 0x08, value: 0x00)
        d.write(port: 0x09, value: 0x01)  // STEP IN
        d.write(port: 0x09, value: 0x01)
        d.write(port: 0x09, value: 0x04)
        XCTAssertEqual(d.read(port: 0x08)! & 0x40, 0x40, "トラック 0 ではない")
        let s = readSector(d, 2)
        XCTAssertEqual(Array(s[0..<3]), [2, 2, 0xA5])
        d.write(port: 0x09, value: 0x02)  // STEP OUT x2 → トラック 0
        d.write(port: 0x09, value: 0x02)
        d.write(port: 0x09, value: 0x02)
        XCTAssertEqual(d.read(port: 0x08)! & 0x40, 0, "トラック 0")
    }

    func testWriteRequiresWriteEnableAndPersistsInImage() throws {
        let image = try testImage()
        let d = DiskController()
        d.mount(image, drive: 1)
        d.reset()
        d.write(port: 0x08, value: 0x01)
        d.write(port: 0x09, value: 0x04)
        XCTAssertEqual(waitSectorTrue(d), 0)  // セクタ 0
        d.write(port: 0x0A, value: 0x77)  // 書き込み許可なし → 無視される
        XCTAssertEqual(image.bytes[0], 0)
        d.write(port: 0x09, value: 0x80)  // WRITE ENABLE(index を 0 に戻す)
        d.write(port: 0x0A, value: 0x77)
        d.write(port: 0x0A, value: 0x88)
        XCTAssertEqual(Array(image.bytes[0..<2]), [0x77, 0x88])
        d.write(port: 0x09, value: 0x08)  // 書き込み許可中のヘッドアンロードは、書き込みが終わるまで保留される(マニュアル p.135)
        XCTAssertEqual(d.read(port: 0x08)! & 0x01, 0x00, "保留中は、まだ書き込み可")
        XCTAssertEqual(d.read(port: 0x08)! & 0x04, 0x00, "保留中は、ヘッドはロードされたまま")
        d.write(port: 0x09, value: 0x01)  // 次のコマンド(ステップ)で、保留していたアンロードが確定する
        XCTAssertEqual(d.read(port: 0x08)! & 0x01, 0x01, "アンロードが確定すると書き込み許可が解除される")
        // ステップのあと、ヘッドステータス(HS)は true(bit2 = 0)になる(マニュアル p.134)。AFORMAT はこれに依存する
        XCTAssertEqual(d.read(port: 0x08)! & 0x04, 0x00, "ステップのあとはヘッドがロードされた状態")
    }

    func testStepAfterUnloadLeavesTheHeadLoadedForTheNextWrite() throws {
        let image = try testImage()
        let d = DiskController()
        d.mount(image, drive: 0)
        d.reset()
        d.write(port: 0x08, value: 0x00)
        d.write(port: 0x09, value: 0x04)
        d.write(port: 0x09, value: 0x08)  // アンロード
        XCTAssertEqual(d.read(port: 0x08)! & 0x04, 0x04)
        d.write(port: 0x09, value: 0x01)  // ステップイン(AFORMAT の次のトラックへの移動)
        XCTAssertEqual(d.read(port: 0x08)! & 0x04, 0x00, "ステップでヘッドが(再び)ロードされる")
        XCTAssertEqual(d.read(port: 0x08)! & 0x80, 0x00, "読み出し可(NRDA)も有効")
        let sector = waitSectorTrue(d)
        d.write(port: 0x09, value: 0x80)
        d.write(port: 0x0A, value: 0xAB)
        let off = (1 * DiskImage.sectorsPerTrack + sector) * DiskImage.bytesPerSector
        XCTAssertEqual(image.bytes[off], 0xAB, "ステップ後のトラック 1 に、ヘッドをロードし直さずに書ける")
    }

    func testUnloadAfterWriteEnableCompletesWhenTheSectorIsWritten() throws {
        let image = try testImage()
        let d = DiskController()
        d.mount(image, drive: 0)
        d.reset()
        d.write(port: 0x08, value: 0x00)
        d.write(port: 0x09, value: 0x04)
        waitSectorTrue(d)
        d.write(port: 0x09, value: 0x80)  // WRITE ENABLE
        d.write(port: 0x09, value: 0x08)  // すぐにアンロード(AFORMAT と同じ使い方)
        for i in 0..<DiskImage.bytesPerSector { d.write(port: 0x0A, value: UInt8(i & 0xFF)) }  // ヘッドは書き込み中ロードされたまま
        XCTAssertEqual(image.bytes[DiskImage.bytesPerSector - 1], UInt8((DiskImage.bytesPerSector - 1) & 0xFF), "アンロード後も、セクタの最後まで書ける")
        XCTAssertEqual(d.read(port: 0x08)! & 0x04, 0x04, "書き終えるとアンロードが確定する")
    }

    func testFlushWritesFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("altair-test-\(UUID().uuidString).dsk")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([UInt8](repeating: 0, count: DiskImage.size)).write(to: url)
        let image = try DiskImage(contentsOf: url)
        let d = DiskController()
        d.mount(image, drive: 0)
        d.reset()
        d.write(port: 0x08, value: 0x00)
        d.write(port: 0x09, value: 0x04)
        waitSectorTrue(d)
        d.write(port: 0x09, value: 0x80)
        d.write(port: 0x0A, value: 0xEE)
        d.write(port: 0x08, value: 0x80)  // 選択解除で書き戻し
        XCTAssertEqual(try Data(contentsOf: url)[0], 0xEE)
    }

    func testWrongSizeImageRejected() {
        XCTAssertThrowsError(try DiskImage(bytes: [0, 1, 2]))
    }

    func testMachineRoutesDiskPorts() throws {
        let m = AltairMachine()
        m.disks.mount(try testImage(), drive: 0)
        m.disks.reset()
        m.output(0x08, 0x00)
        XCTAssertEqual(m.input(0x08) & 0x08, 0)
    }
}
