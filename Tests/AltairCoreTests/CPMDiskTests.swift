import XCTest
@testable import AltairCore

/// CP/M 2.2 ディスク(Altair 8800)へファイルをまとめるツール。
/// 実物のディスクイメージ(ライブラリの CP/M 2.2b)にファイルを入れて、CP/M を起動して、DIR・実行・コピーで確かめる。
final class CPMDiskTests: XCTestCase {
    private let lib = AssetLibrary.defaultRoot
    private var cpmURL: URL { lib.appendingPathComponent("disks/cpm22b23-56k.dsk") }

    /// 実物がなくても動かせる、ヘッダつきの空のイメージ(トラック 0〜5 はチェックサムつき、以降は CP/M が書いた流儀の 0)
    private func syntheticImage() -> [UInt8] {
        let layout = CPMDisk.Layout.altair8800
        var img = [UInt8](repeating: 0, count: layout.imageSize)
        for t in 0..<layout.tracks {
            for s in 0..<layout.sectorsPerTrack {
                let o = (t * layout.sectorsPerTrack + s) * layout.sectorBytes
                img[o] = 0x80 | UInt8(t); img[o + 2] = 1
                for i in 0..<128 { img[o + 3 + i] = 0xE5 }
                img[o + 131] = 0xFF
                img[o + 132] = t < 6 ? UInt8(truncatingIfNeeded: 128 * 0xE5) : 0
            }
        }
        return img
    }

    func testAddReadListRemove() throws {
        let disk = try CPMDisk(image: syntheticImage())
        XCTAssertEqual(disk.files().count, 0)
        XCTAssertEqual(disk.capacityKB, 296)
        let small = (0..<300).map { UInt8($0 & 0xFF) }
        try disk.add(name: "small.dat", data: small)
        // 40KB のファイル(エクステントをまたぐ。1 エクステントは 16KB)
        let big = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 8)) }
        try disk.add(name: "BIG.BIN", data: big)
        let files = disk.files()
        XCTAssertEqual(files.map(\.name), ["SMALL.DAT", "BIG.BIN"])
        XCTAssertEqual(files[0].sizeBytes, 384)
        XCTAssertEqual(files[1].records, 313)
        let readSmall = try XCTUnwrap(disk.read(name: "SMALL.DAT"))
        XCTAssertEqual(Array(readSmall.prefix(300)), small)
        XCTAssertEqual(Array(readSmall.suffix(84)), [UInt8](repeating: 0x1A, count: 84))
        XCTAssertEqual(Array(try XCTUnwrap(disk.read(name: "big.bin")).prefix(40_000)), big)
        // 置き換えでブロックが増えない
        let before = disk.freeBlocks
        try disk.add(name: "SMALL.DAT", data: small)
        XCTAssertEqual(disk.freeBlocks, before)
        XCTAssertTrue(disk.remove(name: "SMALL.DAT"))
        XCTAssertEqual(disk.freeBlocks, before + 1)
        XCTAssertNil(disk.read(name: "SMALL.DAT"))
    }

    func testRejectsBadNamesAndFullDisk() throws {
        let disk = try CPMDisk(image: syntheticImage())
        XCTAssertThrowsError(try disk.add(name: "TOOLONGNAME.COM", data: [1]))
        XCTAssertThrowsError(try disk.add(name: "A.TEXT", data: [1]))
        XCTAssertThrowsError(try disk.add(name: "A*B.COM", data: [1]))
        XCTAssertThrowsError(try disk.add(name: "日本語.COM", data: [1]))
        XCTAssertThrowsError(try disk.add(name: "HUGE.BIN", data: [UInt8](repeating: 1, count: 300 * 1024)))
        // 満杯のエラーのあとも、ディスクは変わらない
        XCTAssertEqual(disk.files().count, 0)
        try disk.add(name: "FIT.BIN", data: [UInt8](repeating: 1, count: 290 * 1024))
        XCTAssertEqual(disk.freeKB, 6)
    }

    func testTooSmallImageIsRejected() {
        XCTAssertThrowsError(try CPMDisk(image: [UInt8](repeating: 0, count: 1000)))
    }

    func testListsFilesOfRealCPMDisk() throws {
        guard FileManager.default.fileExists(atPath: cpmURL.path) else { throw XCTSkip("CP/M 2.2b がありません") }
        let disk = try CPMDisk(contentsOf: cpmURL)
        let names = disk.files().map(\.name)
        for n in ["PIP.COM", "STAT.COM", "ASM.COM", "ED.COM"] { XCTAssertTrue(names.contains(n), "\(n) が見つかる: \(names)") }
        let pip = try XCTUnwrap(disk.read(name: "PIP.COM"))
        XCTAssertGreaterThan(pip.count, 4000)
    }

    // MARK: 実物の CP/M で確かめる

    /// ドライブ A = CP/M 2.2b(作業用コピー)、ドライブ B = つくったディスク で起動し、`type` で入力できる環境を返す
    fileprivate func boot(driveB: [UInt8]) throws -> (type: (String, Int) -> String, driveB: DiskImage) {
        let romURL = lib.appendingPathComponent("roms/88dskrom.bin")
        guard FileManager.default.fileExists(atPath: cpmURL.path), FileManager.default.fileExists(atPath: romURL.path) else {
            throw XCTSkip("CP/M のディスクまたは 88dskrom がありません")
        }
        let a = try DiskImage(bytes: [UInt8](try Data(contentsOf: cpmURL)))
        let b = try DiskImage(bytes: driveB)
        let m = AltairMachine(ramSize: 0x10000)
        m.disks.mount(a, drive: 0)
        m.disks.mount(b, drive: 1)
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: romURL)), at: 0xFF00)
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.switches = 0xFF00; m.examine(); m.start()
        for _ in 0..<300 { m.run(cycles: 100_000) }
        let type: (String, Int) -> String = { text, steps in
            let mark = out.count
            for u in (text + "\r").utf8 { m.sendSerial(u) }
            for _ in 0..<steps { m.run(cycles: 100_000) }
            return String(out.dropFirst(mark))
        }
        return (type, b)
    }

    func testBuiltDiskWorksUnderRealCPM() throws {
        guard FileManager.default.fileExists(atPath: cpmURL.path) else { throw XCTSkip("CP/M 2.2b がありません") }
        let disk = try CPMDisk(contentsOf: cpmURL)
        disk.eraseAllFiles()
        // BDOS の文字列表示で「BUILT DISK OK」を出す COM ファイル
        let msg = Array("BUILT DISK OK$".utf8)
        let hello: [UInt8] = [0x11, 0x09, 0x01, 0x0E, 0x09, 0xCD, 0x05, 0x00, 0xC9] + msg
        try disk.add(name: "HELLO.COM", data: hello)
        // 3 エクステントにまたがる、中身に規則のあるファイル
        let big = (0..<40_000).map { UInt8(truncatingIfNeeded: ($0 / 128) &* 31 &+ $0) }
        try disk.add(name: "BIG.DAT", data: big)

        let (type, driveB) = try boot(driveB: disk.image)
        let dir = type("DIR B:", 300)
        XCTAssertTrue(dir.contains("HELLO    COM"), dir)
        XCTAssertTrue(dir.contains("BIG      DAT"), dir)
        XCTAssertFalse(dir.contains("Bad Sector"), dir)
        XCTAssertTrue(type("B:HELLO", 300).contains("BUILT DISK OK"))
        // 同じディスク(B:)の中へコピーして、そのバイト列がもとと一致するか(CP/M が読んで、BIOS が書いたもの)
        let pip = type("PIP B:COPY.DAT=B:BIG.DAT[O]", 1500)
        XCTAssertFalse(pip.contains("ERROR") || pip.contains("Bad Sector"), pip)
        let copied = try CPMDisk(image: driveB.bytes)
        let got = try XCTUnwrap(copied.read(name: "COPY.DAT"), "B: に COPY.DAT ができる")
        XCTAssertEqual(Array(got.prefix(40_000)), big)
        // BIOS が書いたあとも、つくったファイルは残っている
        XCTAssertEqual(Array(try XCTUnwrap(copied.read(name: "BIG.DAT")).prefix(40_000)), big)
    }
}
