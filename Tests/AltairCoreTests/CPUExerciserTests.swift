import XCTest
@testable import AltairCore

/// CP/M 用の 8080 テストプログラム(.COM)を、BDOS 呼び出し(0005h)だけを模擬して実行する。
/// 取得元は AssetLibrary.catalog を参照(ライブラリに取り込んだファイルを使う)。
final class CPUExerciserTests: XCTestCase {
    private let dir = AssetLibrary.defaultRoot.appendingPathComponent("cpu_tests")

    private struct Result {
        var output: String
        var cycles: Int
        var finished: Bool
    }

    private func runCOM(_ name: String, maxCycles: Int, echo: Bool = false) throws -> Result {
        let url = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name) がありません") }
        let program = [UInt8](try Data(contentsOf: url))

        let m = AltairMachine(ramSize: 0x10000)
        m.load(program, at: 0x0100)
        m.load([0xC9], at: 0x0005)  // BDOS 入口は RET
        m.cpu.pc = 0x0100
        m.cpu.sp = 0xFFF0

        var out = ""
        var cycles = 0
        var finished = false
        while cycles < maxCycles {
            if m.cpu.pc == 0x0000 { finished = true; break }  // ウォームブート = 終了
            if m.cpu.pc == 0x0005 {
                switch m.cpu.c {
                case 2:
                    out.append(Character(UnicodeScalar(m.cpu.e)))
                    if echo { FileHandle.standardError.write(Data([m.cpu.e])) }
                case 9:
                    var a = m.cpu.de
                    while m.peek(a) != UInt8(ascii: "$") {
                        out.append(Character(UnicodeScalar(m.peek(a))))
                        if echo { FileHandle.standardError.write(Data([m.peek(a)])) }
                        a &+= 1
                    }
                default: break
                }
            }
            cycles += m.cpu.step()
        }
        return Result(output: out, cycles: cycles, finished: finished)
    }

    func test8080PRE() throws {
        let r = try runCOM("8080PRE.COM", maxCycles: 50_000_000)
        print("--- 8080PRE (\(r.cycles) cycles) ---\n\(r.output)")
        XCTAssertTrue(r.finished)
        XCTAssertTrue(r.output.contains("8080 Preliminary tests complete"), r.output)
    }

    func testTST8080() throws {
        let r = try runCOM("TST8080.COM", maxCycles: 100_000_000)
        print("--- TST8080 (\(r.cycles) cycles) ---\n\(r.output)")
        XCTAssertTrue(r.finished)
        XCTAssertTrue(r.output.contains("CPU IS OPERATIONAL"), r.output)
    }

    /// 全命令・フラグを CRC で照合する本命のテスト。数分かかるので RUN_8080EXM=1 のときだけ実行する。
    /// 例: RUN_8080EXM=1 swift test -c release --filter CPUExerciserTests/test8080EXM
    func test8080EXM() throws {
        guard ProcessInfo.processInfo.environment["RUN_8080EXM"] == "1" else {
            throw XCTSkip("RUN_8080EXM=1 のときだけ実行します")
        }
        let r = try runCOM("8080EXM.COM", maxCycles: 100_000_000_000, echo: true)
        print("--- 8080EXM (\(r.cycles) cycles) ---")
        XCTAssertTrue(r.finished)
        XCTAssertFalse(r.output.contains("ERROR"), r.output)
        XCTAssertTrue(r.output.contains("PASS"), r.output)
    }

    func testCPUTEST() throws {
        let r = try runCOM("CPUTEST.COM", maxCycles: 3_000_000_000)
        print("--- CPUTEST (\(r.cycles) cycles, finished=\(r.finished)) ---\n\(r.output)")
        XCTAssertTrue(r.finished)
        XCTAssertTrue(r.output.contains("CPU TESTS OK"), r.output)
    }

    /// アプリの「8080 テスト」と同じ経路(エミュレートした BDOS シム + 2SIO 出力)で実行しても同じ結果になること
    func testShimRunsTestsThroughEmulatedBDOS() throws {
        for (file, expected) in [("8080PRE.COM", "8080 Preliminary tests complete"), ("TST8080.COM", "CPU IS OPERATIONAL")] {
            let url = dir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(file) がありません") }
            let m = AltairMachine(ramSize: 0x10000)
            var out = ""
            m.onSerialOutput = { out.append(Character(UnicodeScalar($0 & 0x7F))) }
            CPMConsoleShim.load(com: [UInt8](try Data(contentsOf: url)), into: m)
            m.start()
            for _ in 0..<50 { m.run(cycles: 100_000) }
            XCTAssertTrue(out.contains(expected), "\(file): \(out)")
            XCTAssertTrue(m.cpu.halted, "\(file) は HLT で終わるはず")
            XCTAssertTrue(m.running, "HLT 後も RUN のまま")
            XCTAssertTrue(m.status.contains(.hlta))
        }
    }
}
