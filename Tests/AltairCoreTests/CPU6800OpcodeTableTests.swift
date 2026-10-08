import XCTest
@testable import AltairCore

/// 6800 の全オペコードについて、命令の長さ・クロック数・「有効か未定義か」を、
/// 独立した資料と突き合わせる。
///
/// 資料: JimInCA/motorola-6800-assembler(https://github.com/JimInCA/motorola-6800-assembler)の
/// src/table0.c と src/do0.c。ニーモニックごとの基本オペコード・基本クロック数と、
/// アドレッシングモードごとの加算(ダイレクト +1、インデックス +3、拡張 +2。GRP2 は インデックス +1、拡張 +0)から
/// 全オペコードを展開した。リポジトリにライセンス表示はないため、コードは取り込まず、
/// 展開した事実(オペコード・バイト数・クロック数)だけをここに置いている。
/// 6801 の SUBD は 6800 にない命令なので除いた。JSR のダイレクト(9D)は 6800 にないので含めない。
final class CPU6800OpcodeTableTests: XCTestCase {
    /// (オペコード, バイト数, クロック数, ニーモニック)。有効なオペコードは 197 個。
    private static let valid: [(UInt8, Int, Int, String)] = [
        (0x01, 1, 2, "nop"),
        (0x06, 1, 2, "tap"),
        (0x07, 1, 2, "tpa"),
        (0x08, 1, 4, "inx"),
        (0x09, 1, 4, "dex"),
        (0x0A, 1, 2, "clv"),
        (0x0B, 1, 2, "sev"),
        (0x0C, 1, 2, "clc"),
        (0x0D, 1, 2, "sec"),
        (0x0E, 1, 2, "cli"),
        (0x0F, 1, 2, "sei"),
        (0x10, 1, 2, "sba"),
        (0x11, 1, 2, "cba"),
        (0x16, 1, 2, "tab"),
        (0x17, 1, 2, "tba"),
        (0x19, 1, 2, "daa"),
        (0x1B, 1, 2, "aba"),
        (0x20, 2, 4, "bra"),
        (0x22, 2, 4, "bhi"),
        (0x23, 2, 4, "bls"),
        (0x24, 2, 4, "bcc"),
        (0x25, 2, 4, "bcs"),
        (0x26, 2, 4, "bne"),
        (0x27, 2, 4, "beq"),
        (0x28, 2, 4, "bvc"),
        (0x29, 2, 4, "bvs"),
        (0x2A, 2, 4, "bpl"),
        (0x2B, 2, 4, "bmi"),
        (0x2C, 2, 4, "bge"),
        (0x2D, 2, 4, "blt"),
        (0x2E, 2, 4, "bgt"),
        (0x2F, 2, 4, "ble"),
        (0x30, 1, 4, "tsx"),
        (0x31, 1, 4, "ins"),
        (0x32, 1, 4, "pula"),
        (0x33, 1, 4, "pulb"),
        (0x34, 1, 4, "des"),
        (0x35, 1, 4, "txs"),
        (0x36, 1, 4, "psha"),
        (0x37, 1, 4, "pshb"),
        (0x39, 1, 5, "rts"),
        (0x3B, 1, 10, "rti"),
        (0x3E, 1, 9, "wai"),
        (0x3F, 1, 12, "swi"),
        (0x40, 1, 2, "nega"),
        (0x43, 1, 2, "coma"),
        (0x44, 1, 2, "lsra"),
        (0x46, 1, 2, "rora"),
        (0x47, 1, 2, "asra"),
        (0x48, 1, 2, "asla"),
        (0x49, 1, 2, "rola"),
        (0x4A, 1, 2, "deca"),
        (0x4C, 1, 2, "inca"),
        (0x4D, 1, 2, "tsta"),
        (0x4F, 1, 2, "clra"),
        (0x50, 1, 2, "negb"),
        (0x53, 1, 2, "comb"),
        (0x54, 1, 2, "lsrb"),
        (0x56, 1, 2, "rorb"),
        (0x57, 1, 2, "asrb"),
        (0x58, 1, 2, "aslb"),
        (0x59, 1, 2, "rolb"),
        (0x5A, 1, 2, "decb"),
        (0x5C, 1, 2, "incb"),
        (0x5D, 1, 2, "tstb"),
        (0x5F, 1, 2, "clrb"),
        (0x60, 2, 7, "neg"),
        (0x63, 2, 7, "com"),
        (0x64, 2, 7, "lsr"),
        (0x66, 2, 7, "ror"),
        (0x67, 2, 7, "asr"),
        (0x68, 2, 7, "asl"),
        (0x69, 2, 7, "rol"),
        (0x6A, 2, 7, "dec"),
        (0x6C, 2, 7, "inc"),
        (0x6D, 2, 7, "tst"),
        (0x6E, 2, 4, "jmp"),
        (0x6F, 2, 7, "clr"),
        (0x70, 3, 6, "neg"),
        (0x73, 3, 6, "com"),
        (0x74, 3, 6, "lsr"),
        (0x76, 3, 6, "ror"),
        (0x77, 3, 6, "asr"),
        (0x78, 3, 6, "asl"),
        (0x79, 3, 6, "rol"),
        (0x7A, 3, 6, "dec"),
        (0x7C, 3, 6, "inc"),
        (0x7D, 3, 6, "tst"),
        (0x7E, 3, 3, "jmp"),
        (0x7F, 3, 6, "clr"),
        (0x80, 2, 2, "suba"),
        (0x81, 2, 2, "cmpa"),
        (0x82, 2, 2, "sbca"),
        (0x84, 2, 2, "anda"),
        (0x85, 2, 2, "bita"),
        (0x86, 2, 2, "ldaa"),
        (0x88, 2, 2, "eora"),
        (0x89, 2, 2, "adca"),
        (0x8A, 2, 2, "oraa"),
        (0x8B, 2, 2, "adda"),
        (0x8C, 3, 3, "cpx"),
        (0x8D, 2, 8, "bsr"),
        (0x8E, 3, 3, "lds"),
        (0x90, 2, 3, "suba"),
        (0x91, 2, 3, "cmpa"),
        (0x92, 2, 3, "sbca"),
        (0x94, 2, 3, "anda"),
        (0x95, 2, 3, "bita"),
        (0x96, 2, 3, "ldaa"),
        (0x97, 2, 4, "staa"),
        (0x98, 2, 3, "eora"),
        (0x99, 2, 3, "adca"),
        (0x9A, 2, 3, "oraa"),
        (0x9B, 2, 3, "adda"),
        (0x9C, 2, 4, "cpx"),
        (0x9E, 2, 4, "lds"),
        (0x9F, 2, 5, "sts"),
        (0xA0, 2, 5, "suba"),
        (0xA1, 2, 5, "cmpa"),
        (0xA2, 2, 5, "sbca"),
        (0xA4, 2, 5, "anda"),
        (0xA5, 2, 5, "bita"),
        (0xA6, 2, 5, "ldaa"),
        (0xA7, 2, 6, "staa"),
        (0xA8, 2, 5, "eora"),
        (0xA9, 2, 5, "adca"),
        (0xAA, 2, 5, "oraa"),
        (0xAB, 2, 5, "adda"),
        (0xAC, 2, 6, "cpx"),
        (0xAD, 2, 8, "jsr"),
        (0xAE, 2, 6, "lds"),
        (0xAF, 2, 7, "sts"),
        (0xB0, 3, 4, "suba"),
        (0xB1, 3, 4, "cmpa"),
        (0xB2, 3, 4, "sbca"),
        (0xB4, 3, 4, "anda"),
        (0xB5, 3, 4, "bita"),
        (0xB6, 3, 4, "ldaa"),
        (0xB7, 3, 5, "staa"),
        (0xB8, 3, 4, "eora"),
        (0xB9, 3, 4, "adca"),
        (0xBA, 3, 4, "oraa"),
        (0xBB, 3, 4, "adda"),
        (0xBC, 3, 5, "cpx"),
        (0xBD, 3, 9, "jsr"),
        (0xBE, 3, 5, "lds"),
        (0xBF, 3, 6, "sts"),
        (0xC0, 2, 2, "subb"),
        (0xC1, 2, 2, "cmpb"),
        (0xC2, 2, 2, "sbcb"),
        (0xC4, 2, 2, "andb"),
        (0xC5, 2, 2, "bitb"),
        (0xC6, 2, 2, "ldab"),
        (0xC8, 2, 2, "eorb"),
        (0xC9, 2, 2, "adcb"),
        (0xCA, 2, 2, "orab"),
        (0xCB, 2, 2, "addb"),
        (0xCE, 3, 3, "ldx"),
        (0xD0, 2, 3, "subb"),
        (0xD1, 2, 3, "cmpb"),
        (0xD2, 2, 3, "sbcb"),
        (0xD4, 2, 3, "andb"),
        (0xD5, 2, 3, "bitb"),
        (0xD6, 2, 3, "ldab"),
        (0xD7, 2, 4, "stab"),
        (0xD8, 2, 3, "eorb"),
        (0xD9, 2, 3, "adcb"),
        (0xDA, 2, 3, "orab"),
        (0xDB, 2, 3, "addb"),
        (0xDE, 2, 4, "ldx"),
        (0xDF, 2, 5, "stx"),
        (0xE0, 2, 5, "subb"),
        (0xE1, 2, 5, "cmpb"),
        (0xE2, 2, 5, "sbcb"),
        (0xE4, 2, 5, "andb"),
        (0xE5, 2, 5, "bitb"),
        (0xE6, 2, 5, "ldab"),
        (0xE7, 2, 6, "stab"),
        (0xE8, 2, 5, "eorb"),
        (0xE9, 2, 5, "adcb"),
        (0xEA, 2, 5, "orab"),
        (0xEB, 2, 5, "addb"),
        (0xEE, 2, 6, "ldx"),
        (0xEF, 2, 7, "stx"),
        (0xF0, 3, 4, "subb"),
        (0xF1, 3, 4, "cmpb"),
        (0xF2, 3, 4, "sbcb"),
        (0xF4, 3, 4, "andb"),
        (0xF5, 3, 4, "bitb"),
        (0xF6, 3, 4, "ldab"),
        (0xF7, 3, 5, "stab"),
        (0xF8, 3, 4, "eorb"),
        (0xF9, 3, 4, "adcb"),
        (0xFA, 3, 4, "orab"),
        (0xFB, 3, 4, "addb"),
        (0xFE, 3, 5, "ldx"),
        (0xFF, 3, 6, "stx"),
    ]

    private var buses: [TestBus6800] = []

    func testExpectedTableHas197ValidOpcodes() {
        XCTAssertEqual(Self.valid.count, 197, "MC6800 の有効なオペコードは 197 個")
        XCTAssertEqual(Set(Self.valid.map { $0.0 }).count, 197)
    }

    func testEveryOpcodeLengthCyclesAndValidity() {
        let validOps = Dictionary(uniqueKeysWithValues: Self.valid.map { ($0.0, ($0.1, $0.2, $0.3)) })
        // 実行して PC が進まない(ジャンプ・復帰・割り込み・待機)命令は、バイト数の確認から外す
        let controlFlow: Set<String> = ["jmp", "jsr", "bsr", "rts", "rti", "swi", "wai"]
        var problems: [String] = []

        for op in 0...255 {
            let bus = TestBus6800()
            buses.append(bus)
            bus.load([UInt8(op), 0x00, 0x00], at: 0x0100)
            let cpu = CPU6800(bus: bus)
            cpu.pc = 0x0100
            cpu.sp = 0x01F0
            cpu.x = 0x0200
            cpu.i = false
            let cycles = cpu.step()

            if let (length, expectedCycles, name) = validOps[UInt8(op)] {
                if cpu.illegalCount != 0 { problems.append(String(format: "%02X %@: 有効なのに未定義扱い", op, name)) }
                if cycles != expectedCycles {
                    problems.append(String(format: "%02X %@: クロック %d(期待 %d)", op, name, cycles, expectedCycles))
                }
                if !controlFlow.contains(name), Int(cpu.pc) != 0x0100 + length {
                    problems.append(String(format: "%02X %@: PC が %d バイト進んだ(期待 %d)", op, name, Int(cpu.pc) - 0x0100, length))
                }
            } else {
                if cpu.illegalCount != 1 { problems.append(String(format: "%02X: 未定義なのに有効扱い", op)) }
            }
        }
        XCTAssertTrue(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }
}
