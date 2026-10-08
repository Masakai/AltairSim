import XCTest
@testable import AltairCore

/// 6800 の機能テストプログラム(Tools/gen6800_functional_test.py が作る機械語)を CPU 上で走らせる。
///
/// プログラムは、196 個のオペコード(WAI を除く)× 12 通りの入力(レジスタ、CC、メモリ)を実行し、
/// 実行後の状態(A、B、X、SP、CC、メモリ、スタック 28 バイト)のチェックサムを、参照モデルが作った期待値と比べる。
/// 食い違ったケースは、ケースの位置と実際の状態が記録される(先頭 32 件)。
final class CPU6800FunctionalTests: XCTestCase {
    private let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/6800")

    func testEveryOpcodeAndAddressingMode() throws {
        let s19URL = dir.appendingPathComponent("functional6800.s19")
        let jsonURL = dir.appendingPathComponent("functional6800.json")
        let listURL = dir.appendingPathComponent("functional6800.txt")
        guard FileManager.default.fileExists(atPath: s19URL.path) else { throw XCTSkip("functional6800.s19 がありません") }

        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as! [String: Any]
        func int(_ key: String) -> Int { (meta[key] as! NSNumber).intValue }
        let entry = int("entry"), halt = int("halt")
        let failCnt = int("failcnt"), caseCnt = int("casecnt"), done = int("done"), failList = int("faillist")
        let expectedCases = int("cases"), maxFails = int("max_fails")
        let listing = try String(contentsOf: listURL, encoding: .utf8).split(separator: "\n").map(String.init)

        let bus = TestBus6800()
        bus.ramLimit = 0x10000
        bus.romStart = 0x10000
        for rec in try S19Loader.parse(try String(contentsOf: s19URL, encoding: .utf8)) {
            bus.load(rec.bytes, at: Int(rec.address))
        }
        bus.memory[0xFFFA] = UInt8(truncatingIfNeeded: 0x0310 >> 8)   // SWI ベクタ → TRAMPA
        bus.memory[0xFFFB] = 0x10
        let cpu = CPU6800(bus: bus)
        cpu.pc = UInt16(entry)

        var cycles = 0
        while Int(cpu.pc) != halt && cycles < 400_000_000 { cycles += cpu.step() }
        XCTAssertEqual(Int(cpu.pc), halt, "プログラムが終了位置に着かなかった(\(cycles) クロック)")
        XCTAssertEqual(bus.memory[done], 0xA5, "終了マーカー")

        let failures = Int(bus.memory[failCnt]) << 8 | Int(bus.memory[failCnt + 1])
        let cases = Int(bus.memory[caseCnt]) << 8 | Int(bus.memory[caseCnt + 1])
        XCTAssertEqual(cases, expectedCases, "実行したケース数")

        var report: [String] = []
        for k in 0..<min(failures, maxFails) {
            let base = failList + k * 30
            let recPtr = Int(bus.memory[base]) << 8 | Int(bus.memory[base + 1])
            let index = (recPtr - 0x1000) / 18
            let actual = (0..<28).map { String(format: "%02x", bus.memory[base + 2 + $0]) }.joined()
            let line = index < listing.count ? listing[index] : "(ケース \(index))"
            report.append("\(line)\n      実際 \(actual)")
        }
        print("機能テスト: \(cases) ケース、\(failures) 件の不一致、\(cycles) クロック、未定義命令 \(cpu.illegalCount)")
        XCTAssertEqual(failures, 0, "不一致 \(failures) 件(先頭 \(report.count) 件):\n" + report.joined(separator: "\n"))
        XCTAssertEqual(cpu.illegalCount, 0, "有効な命令だけのはずが、未定義命令に到達した")
    }
}
