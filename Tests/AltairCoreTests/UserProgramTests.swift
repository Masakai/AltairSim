import XCTest
@testable import AltairCore

/// ユーザー追加のプログラム(.hex / .s19)を、アプリと同じ読み込み経路(HexLoader / loadS19 → 実行)で動かす。
final class UserProgramTests: XCTestCase {
    private func ihex(_ addr: Int, _ data: [UInt8]) -> String {
        var out: [String] = []
        for i in stride(from: 0, to: data.count, by: 16) {
            let chunk = Array(data[i..<min(i + 16, data.count)])
            let rec = [UInt8(chunk.count), UInt8((addr + i) >> 8), UInt8((addr + i) & 255), 0] + chunk
            out.append(":" + rec.map { String(format: "%02X", $0) }.joined() + String(format: "%02X", (0 &- rec.reduce(0, &+)) & 255))
        }
        return (out + [":00000001FF"]).joined(separator: "\n")
    }

    private func srec(_ addr: Int, _ data: [UInt8]) -> String {
        var out = ["S00600004844521B"]
        for i in stride(from: 0, to: data.count, by: 16) {
            let chunk = Array(data[i..<min(i + 16, data.count)])
            let rec = [UInt8(chunk.count + 3), UInt8((addr + i) >> 8), UInt8((addr + i) & 255)] + chunk
            out.append("S1" + rec.map { String(format: "%02X", $0) }.joined() + String(format: "%02X", ~rec.reduce(0, &+) & 255))
        }
        return (out + ["S9030100FB"]).joined(separator: "\n")
    }

    func test8800HexProgramRuns() throws {
        let code: [UInt8] = [0x21, 0x0F, 0x00, 0x7E, 0xB7, 0xCA, 0x0E, 0x00, 0xD3, 0x11, 0x23, 0xC3, 0x03, 0x00, 0x76]
            + Array("USER HEX PROGRAM OK\r\n".utf8) + [0]
        let m = AltairMachine(ramSize: 0x10000)
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        for r in try HexLoader.parse(ihex(0, code)) { m.load(r.bytes, at: r.address) }
        m.switches = 0; m.examine(); m.start()
        for _ in 0..<20 { m.run(cycles: 10_000) }
        XCTAssertTrue(out.contains("USER HEX PROGRAM OK"), out)
    }

    func test680S19ProgramRunsInRAMAfterMonitor() throws {
        var prog: [UInt8] = [0xCE, 0x01, 0x20, 0xA6, 0x00, 0x27, 0x06, 0xB7, 0xF0, 0x01, 0x08, 0x20, 0xF6, 0x20, 0xFE]
        prog += [UInt8](repeating: 0, count: 0x20 - prog.count) + Array("USER S19 PROGRAM OK\r\n".utf8) + [0]
        let monitor = AssetLibrary.shared.url("altair680/monitor/MON680.S19")
        guard FileManager.default.fileExists(atPath: monitor.path) else { throw XCTSkip("MON680.S19 がライブラリにありません") }
        let m = Altair680Machine(ramSize: 0x2000)
        try m.loadS19(String(contentsOf: monitor, encoding: .utf8))
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.reset(); m.setRunning(true)
        m.run(cycles: 200_000)
        _ = try m.loadS19(srec(0x0100, prog))
        for u in "J0100".utf8 { m.sendSerial(u) }
        m.run(cycles: 2_000_000)
        XCTAssertTrue(out.contains("USER S19 PROGRAM OK"), out)
    }

    func test680S19AsROMStartsFromResetVector() throws {
        // FF00 から: LDS #01FF ; LDX #FF20 ; ループで ACIA へ出力 ; BRA 自分。RESET ベクタ(FFFE/FFFF)を FF00 に
        var rom: [UInt8] = [0x8E, 0x01, 0xFF, 0xCE, 0xFF, 0x20, 0xA6, 0x00, 0x27, 0x06, 0xB7, 0xF0, 0x01, 0x08, 0x20, 0xF6, 0x20, 0xFE]
        rom += [UInt8](repeating: 0, count: 0x20 - rom.count) + Array("ROM OK\r\n".utf8) + [0]
        let m = Altair680Machine(ramSize: 0x2000)
        m.removeROMs()
        _ = try m.loadS19(srec(0xFF00, rom))
        _ = try m.loadS19(srec(0xFFFE, [0xFF, 0x00]))
        var out = ""
        m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
        m.reset(); m.setRunning(true)
        m.run(cycles: 500_000)
        XCTAssertTrue(out.contains("ROM OK"), out)
    }
}
