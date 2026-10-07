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
        _ = d.read(port: 0x09)  // セクタ 0
        d.write(port: 0x0A, value: 0x77)  // 書き込み許可なし → 無視される
        XCTAssertEqual(image.bytes[0], 0)
        d.write(port: 0x09, value: 0x80)  // WRITE ENABLE(index を 0 に戻す)
        d.write(port: 0x0A, value: 0x77)
        d.write(port: 0x0A, value: 0x88)
        XCTAssertEqual(Array(image.bytes[0..<2]), [0x77, 0x88])
        d.write(port: 0x09, value: 0x08)  // ヘッドアンロードで書き込み許可が解除される
        XCTAssertEqual(d.read(port: 0x08)! & 0x01, 0x01)
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
        _ = d.read(port: 0x09)
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
