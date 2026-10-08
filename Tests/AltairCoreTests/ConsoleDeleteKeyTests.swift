import XCTest
@testable import AltairCore

final class ConsoleDeleteKeyTests: XCTestCase {
    private let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AltairSim/Resources")

    private func bootCPM(_ names: [String]) throws -> (AltairMachine, () -> String, (String) -> Void) {
        let m = AltairMachine(ramSize: 0x10000)
        for (i, n) in names.enumerated() {
            let url = base.appendingPathComponent("disks/\(n)")
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(n) がありません") }
            m.disks.mount(try DiskImage(bytes: [UInt8](try Data(contentsOf: url))), drive: i)
        }
        m.disks.reset()
        m.loadROM([UInt8](try Data(contentsOf: base.appendingPathComponent("roms/88dskrom.bin"))), at: 0xFF00)
        var out = [UInt8]()
        m.onSerialOutput = { out.append($0) }
        m.switches = 0xFF00; m.examine(); m.start()
        for _ in 0..<150 { m.run(cycles: 100_000) }
        out.removeAll()
        return (m, { out.map { String(format: "%02X", $0) }.joined(separator: " ") + "  | " + String(decoding: out.map { $0 == 0x08 ? UInt8(ascii: "<") : ($0 < 0x20 ? UInt8(ascii: ".") : $0) }, as: UTF8.self) },
                { text in for u in text.utf8 { m.sendSerial(u) }; for _ in 0..<30 { m.run(cycles: 100_000) } })
    }

    /// CP/M の行編集: ^H(08h)は BS-SP-BS で画面上の文字を消し、DEL(7Fh)は削除した文字をそのまま
    /// エコーし(ハードコピー端末向けの動作)、'_'(5Fh)は普通の文字として扱われる。
    func testCPMDeleteKeyBehavior() throws {
        for (title, disks) in [("CP/M 2.2", ["cpm22b23-56k.dsk"]), ("CP/M 3", ["cpm3_v1.0_56K_disk1.dsk"])] {
            let expectations: [(UInt8, String)] = [
                (0x08, "44 49 52 58 08 20 08"),  // DIRX, BS, SP, BS
                (0x7F, "44 49 52 58 58"),        // DIRX, X(削除した文字のエコー)
                (0x5F, "44 49 52 58 5F"),        // DIRX, _
            ]
            for (code, expected) in expectations {
                let (m, out, type) = try bootCPM(disks)
                type("DIRX")
                m.sendSerial(code)
                for _ in 0..<30 { m.run(cycles: 100_000) }
                XCTAssertTrue(out().hasPrefix(expected), "\(title) code=\(String(code, radix: 16)): \(out())")
            }
        }
    }
}
