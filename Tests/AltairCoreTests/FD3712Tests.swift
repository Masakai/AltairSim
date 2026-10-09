import XCTest
@testable import AltairCore

/// 680b の 68-UIO と FD3712 を、FLEX の起動 PROM(BOOT.ASM)とディスクドライバ(DSKDRV.ASM)が使う手順そのままで動かす。
/// PROM の読み出し・書き込みのレジスタ操作を Swift で書き写している。
final class FD3712Tests: XCTestCase {
    // 68-UIO のアドレス(BOOT.ASM の equate)
    private let p1ACSR: UInt16 = 0xF008, p1ADR: UInt16 = 0xF009
    private let p1BCSR: UInt16 = 0xF00A, p1BDR: UInt16 = 0xF00B
    private let p2ACSR: UInt16 = 0xF00C, p2ADR: UInt16 = 0xF00D
    private let p2BCSR: UInt16 = 0xF00E, p2BDR: UInt16 = 0xF00F
    private var cmdOut: UInt16 { p1BDR }
    private var dataIn: UInt16 { p1ADR }
    private var dataOut: UInt16 { p2BDR }

    private let cREAD: UInt8 = 0x03, cWRITE: UInt8 = 0x05, cRDCRC: UInt8 = 0x07, cSEEK: UInt8 = 0x09
    private let cCLRERR: UInt8 = 0x0B, cRESTOR: UInt8 = 0x0D, cSETTRK: UInt8 = 0x11, cDRVSEC: UInt8 = 0x21
    private let cWRTBUF: UInt8 = 0x31, cRDBUF: UInt8 = 0x41, cRESET: UInt8 = 0x81
    private let sBUSY: UInt8 = 0x01, sCRCERR: UInt8 = 0x08, sWRTPRT: UInt8 = 0x10, sNOTRDY: UInt8 = 0x20

    private func machine() -> Altair680Machine {
        let m = Altair680Machine(ramSize: 0xC000)
        m.uioInstalled = true
        // 時間を進めるための、何もしないループ
        m.load([0x20, 0xFE], at: 0x0000)
        m.cpu.pc = 0
        m.setRunning(true)
        return m
    }

    private func idle(_ m: Altair680Machine, cycles: Int) { m.run(cycles: cycles) }

    /// BOOT.ASM の initPia
    private func initPia(_ m: Altair680Machine) {
        let hsOff: UInt8 = 0x3C, hsAuto: UInt8 = 0x2C, ddrEna: UInt8 = 0x38
        m.write(p1ACSR, ddrEna); m.write(p1ADR, 0); m.write(p1ACSR, hsOff)
        m.write(p2ACSR, hsOff); m.write(p1BCSR, hsOff); m.write(p2BCSR, hsOff)
        m.write(p2ADR, 0); m.write(p1BDR, 0); m.write(p2BDR, 0)
        m.write(p2ACSR, ddrEna); m.write(p1BCSR, ddrEna); m.write(p2BCSR, ddrEna)
        m.write(p2ADR, 0xFF); m.write(p1BDR, 0xFF); m.write(p2BDR, 0xFF)
        m.write(p2ACSR, hsOff); m.write(p1BCSR, hsOff)
        m.write(p2BCSR, hsAuto)
        _ = m.read(p1ADR); _ = m.read(p1BDR); _ = m.read(p2ADR); _ = m.read(p2BDR)
        _ = doCmd(m, cRESET, 0)
    }

    /// BOOT.ASM の doCmd: コマンドとデータを出し、ビジーでない状態が 3 回続くまで待って、ステータス(論理を戻したもの)を返す
    @discardableResult
    private func doCmd(_ m: Altair680Machine, _ cmd: UInt8, _ data: UInt8) -> UInt8 {
        m.write(cmdOut, cmd)
        m.write(dataOut, data)
        var notBusy = 0
        var guardCount = 0
        while notBusy < 3 {
            idle(m, cycles: 200)
            if (m.read(dataIn) & sBUSY) != 0 { notBusy += 1 } else { notBusy = 0 }   // 入力は反転: ビット 1 = ビジーでない
            guardCount += 1
            XCTAssertLessThan(guardCount, 100_000, "ビジーが終わらない")
            if guardCount >= 100_000 { break }
        }
        return ~m.read(dataIn)
    }

    /// BOOT.ASM の readSec
    private func readSec(_ m: Altair680Machine) -> (status: UInt8, bytes: [UInt8]) {
        let status = doCmd(m, cREAD, 0)
        if status & 0x29 != 0 { return (status, []) }
        m.write(p1ACSR, 0x2C)                       // 自動ハンドシェイクをオン
        m.write(cmdOut, cRDBUF)
        var out = [UInt8]()
        for _ in 0..<128 { out.append(~m.read(dataIn)) }
        m.write(p1ACSR, 0x3C)
        m.write(cmdOut, 0)
        return (status, out)
    }

    /// DSKDRV.ASM の wrtSec
    private func wrtSec(_ m: Altair680Machine, _ bytes: [UInt8]) -> UInt8 {
        m.write(cmdOut, cWRTBUF)
        for b in bytes { m.write(dataOut, b) }
        return doCmd(m, cWRITE, 0)
    }

    private func image() throws -> DiskImage {
        var bytes = [UInt8](repeating: 0, count: DiskImage.Geometry.ibm3740.size)
        for t in 0..<77 {
            for s in 0..<26 {
                let base = (t * 26 + s) * 128
                for k in 0..<128 { bytes[base + k] = UInt8((t * 7 + s * 3 + k) & 0xFF) }
            }
        }
        return try DiskImage(bytes: bytes, geometry: .ibm3740)
    }

    func testBootSequenceReadsTrack0Sector1And2() throws {
        let m = machine()
        let img = try image()
        m.disks.mount(img, drive: 0)
        initPia(m)
        XCTAssertEqual(doCmd(m, cRESET, 0) & 0x29, 0)
        XCTAssertEqual(doCmd(m, cDRVSEC, 1) & 0x29, 0)           // ドライブ 0、セクタ 1
        XCTAssertEqual(doCmd(m, cRESTOR, 0) & 0x29, 0)
        let first = readSec(m)
        XCTAssertEqual(first.status & 0x29, 0)
        XCTAssertEqual(first.bytes, Array(img.bytes[0..<128]))
        XCTAssertEqual(doCmd(m, cDRVSEC, 2) & 0x29, 0)
        let second = readSec(m)
        XCTAssertEqual(second.bytes, Array(img.bytes[128..<256]))
    }

    func testSeekAndReadOtherTrackAndSector() throws {
        let m = machine()
        let img = try image()
        m.disks.mount(img, drive: 0)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 0x00 | 13)
        _ = doCmd(m, cSETTRK, 40)
        _ = doCmd(m, cSEEK, 0)
        let r = readSec(m)
        let off = (40 * 26 + 12) * 128
        XCTAssertEqual(r.bytes, Array(img.bytes[off..<off + 128]))
        XCTAssertEqual(m.disks.headPosition(drive: 0)?.track, 40)
    }

    func testWriteThenReadBackAndImageContents() throws {
        let m = machine()
        let img = try image()
        m.disks.mount(img, drive: 0)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 5)
        _ = doCmd(m, cSETTRK, 10)
        _ = doCmd(m, cSEEK, 0)
        let data = (0..<128).map { UInt8(($0 * 5 + 1) & 0xFF) }
        XCTAssertEqual(wrtSec(m, data) & 0x29, 0)
        let off = (10 * 26 + 4) * 128
        XCTAssertEqual(Array(img.bytes[off..<off + 128]), data)
        XCTAssertEqual(doCmd(m, cRDCRC, 0) & 0x29, 0)
        XCTAssertEqual(readSec(m).bytes, data)
    }

    func testSecondDriveIsIndependent() throws {
        let m = machine()
        let a = try image(), b = try image()
        m.disks.mount(a, drive: 0)
        m.disks.mount(b, drive: 1)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 0x40 | 3)                          // ドライブ 1、セクタ 3
        let data = [UInt8](repeating: 0xEE, count: 128)
        _ = wrtSec(m, data)
        let off = 2 * 128
        XCTAssertEqual(Array(b.bytes[off..<off + 128]), data)
        XCTAssertNotEqual(Array(a.bytes[off..<off + 128]), data, "ドライブ 0 は変わらない")
    }

    func testNotReadyWhenNoDisk() throws {
        let m = machine()
        initPia(m)
        let st = doCmd(m, cRESTOR, 0)
        XCTAssertNotEqual(st & sNOTRDY, 0, "ディスクがないと未接続のビットが立つ(PROM は起動をやり直す)")
        let m2 = machine()
        m2.disks.mount(try image(), drive: 0)
        initPia(m2)
        _ = doCmd(m2, cDRVSEC, 0x80 | 1)                         // 空のドライブ 2
        XCTAssertNotEqual(doCmd(m2, cRESTOR, 0) & sNOTRDY, 0)
    }

    func testWriteProtectAndInvalidSectorErrors() throws {
        let m = machine()
        let img = try image()
        img.writeProtected = true
        m.disks.mount(img, drive: 0)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 1)
        let st = wrtSec(m, [UInt8](repeating: 1, count: 128))
        XCTAssertNotEqual(st & sWRTPRT, 0)
        XCTAssertEqual(Array(img.bytes[0..<128]), (0..<128).map { UInt8($0 & 0xFF) }, "書き込み禁止のイメージは変わらない")
        XCTAssertEqual(doCmd(m, cCLRERR, 0) & 0x29, 0, "エラー消去")

        _ = doCmd(m, cDRVSEC, 30)                                // 存在しないセクタ
        XCTAssertNotEqual(doCmd(m, cREAD, 0) & sCRCERR, 0)
    }

    // MARK: 未フォーマットのディスク

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fd3712-\(UUID().uuidString)-\(name)")
    }

    func testUnformattedSectorsFailToReadUntilWritten() throws {
        let url = tempURL("blank.dsk")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: DiskImage.formatMapURL(for: url)) }
        let img = try DiskImage.createBlank(at: url, geometry: .ibm3740, unformatted: true)
        XCTAssertEqual(img.unformattedSectorCount, 77 * 26)
        let m = machine()
        m.disks.mount(img, drive: 0)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 5)
        _ = doCmd(m, cSETTRK, 10)
        _ = doCmd(m, cSEEK, 0)
        XCTAssertNotEqual(doCmd(m, cREAD, 0) & sCRCERR, 0, "未フォーマットのセクタは読めない(ID が見つからない)")
        XCTAssertNotEqual(doCmd(m, cRDCRC, 0) & sCRCERR, 0)
        _ = doCmd(m, cCLRERR, 0)
        let data = (0..<128).map { UInt8(($0 * 3 + 7) & 0xFF) }
        XCTAssertEqual(wrtSec(m, data) & 0x29, 0, "書き込みは通る(これがフォーマット)")
        XCTAssertEqual(readSec(m).bytes, data, "書いたセクタは読める")
        XCTAssertEqual(img.unformattedSectorCount, 77 * 26 - 1)
        _ = doCmd(m, cDRVSEC, 6)                                  // 隣のセクタは未フォーマットのまま
        XCTAssertNotEqual(doCmd(m, cREAD, 0) & sCRCERR, 0)
    }

    func testFormatMapPersistsAndExistingImagesAreFullyFormatted() throws {
        let url = tempURL("persist.dsk")
        let map = DiskImage.formatMapURL(for: url)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: map) }
        let img = try DiskImage.createBlank(at: url, geometry: .ibm3740, unformatted: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.path))
        let m = machine()
        m.disks.mount(img, drive: 0)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 1)
        XCTAssertEqual(wrtSec(m, [UInt8](repeating: 9, count: 128)) & 0x29, 0)
        XCTAssertTrue(img.hasUnsavedChanges)
        try img.flush()
        XCTAssertFalse(img.hasUnsavedChanges)
        let reopened = try DiskImage(contentsOf: url, geometry: .ibm3740)
        XCTAssertEqual(reopened.unformattedSectorCount, 77 * 26 - 1, "開き直してもフォーマットの記録が残る")
        XCTAssertEqual(reopened.bytes[0], 9)

        // 全セクタを書くと記録は不要になり、ファイルも消える
        for t in 0..<77 { for sec in 0..<26 { reopened.write(0, at: 0); reopened.markFormatted(track: t, sector: sec) } }
        try reopened.flush()
        XCTAssertEqual(reopened.unformattedSectorCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: map.path), "すべてフォーマット済みなら記録ファイルは消える")

        // 記録ファイルのない既存のイメージは、すべてフォーマット済みとして扱う
        let plain = tempURL("plain.dsk")
        defer { try? FileManager.default.removeItem(at: plain) }
        try Data(count: DiskImage.Geometry.ibm3740.size).write(to: plain)
        XCTAssertEqual(try DiskImage(contentsOf: plain, geometry: .ibm3740).unformattedSectorCount, 0)
    }

    func testFormattedBlankImageReadsAsZeros() throws {
        let url = tempURL("fmt.dsk")
        defer { try? FileManager.default.removeItem(at: url) }
        let img = try DiskImage.createBlank(at: url, geometry: .ibm3740, unformatted: false)
        XCTAssertEqual(img.unformattedSectorCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DiskImage.formatMapURL(for: url).path))
        let m = machine()
        m.disks.mount(img, drive: 0)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 1)
        XCTAssertEqual(readSec(m).bytes, [UInt8](repeating: 0, count: 128))
    }

    func testBusyTakesRealTime() throws {
        let m = machine()
        m.disks.mount(try image(), drive: 0)
        initPia(m)
        _ = doCmd(m, cDRVSEC, 1)
        m.write(cmdOut, cRESTOR)
        m.write(dataOut, 0)
        XCTAssertEqual(m.read(dataIn) & sBUSY, 0, "実行直後はビジー(入力は反転なのでビット 0 = ビジー)")
        idle(m, cycles: 100_000)                                 // 0.2 秒(500kHz)
        XCTAssertNotEqual(m.read(dataIn) & sBUSY, 0, "十分待つとビジーが終わる")
    }

    func testPIAPulseOnlyInAutoHandshakeMode() {
        let pia = PIA6821()
        var strobes = 0
        pia.onCB2Strobe = { strobes += 1 }
        pia.write(3, 0x3C)               // CB2 を手動で固定
        pia.write(2, 0x55)
        XCTAssertEqual(strobes, 0)
        pia.write(3, 0x2C)               // CB2 のパルス出力
        pia.write(2, 0x66)
        XCTAssertEqual(strobes, 1)
        pia.write(3, 0x28)               // DDR を選ぶ(bit 2 = 0)
        pia.write(2, 0xFF)               // DDR への書き込みでは出ない
        XCTAssertEqual(strobes, 1)
    }

    func testUIOIsInvisibleWhenNotInstalled() {
        let m = Altair680Machine(ramSize: 0x2000)
        XCTAssertEqual(m.peek(0xF008), 0xFF)
        m.write(0xF008, 0x55)            // 何も起きない
        XCTAssertEqual(m.peek(0xF008), 0xFF)
    }
}
