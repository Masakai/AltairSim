/// 動作確認用の組み込みプログラム(アドレス 0 から配置)
public enum DemoPrograms {
    /// 端末から受信した文字をそのまま返す
    public static let echo: [UInt8] = [
        0xDB, 0x10,         // 0000 IN  10h
        0xE6, 0x01,         // 0002 ANI 01h
        0xCA, 0x00, 0x00,   // 0004 JZ  0000
        0xDB, 0x11,         // 0007 IN  11h
        0xD3, 0x11,         // 0009 OUT 11h
        0xC3, 0x00, 0x00,   // 000B JMP 0000
    ]

    /// 文字列を出力して HLT(送信可ビットを見てから 1 文字ずつ出す)
    public static let hello: [UInt8] = {
        var p: [UInt8] = [
            0x21, 0x20, 0x00,   // 0000 LXI H,0020
            0x7E,               // 0003 MOV A,M
            0xB7,               // 0004 ORA A
            0xCA, 0x17, 0x00,   // 0005 JZ  0017
            0x47,               // 0008 MOV B,A
            0xDB, 0x10,         // 0009 IN  10h
            0xE6, 0x02,         // 000B ANI 02h(送信可?)
            0xCA, 0x09, 0x00,   // 000D JZ  0009
            0x78,               // 0010 MOV A,B
            0xD3, 0x11,         // 0011 OUT 11h
            0x23,               // 0013 INX H
            0xC3, 0x03, 0x00,   // 0014 JMP 0003
            0x76,               // 0017 HLT
        ]
        p += [UInt8](repeating: 0, count: 0x20 - p.count)
        p += Array("HELLO, ALTAIR\r\n".utf8) + [0]
        return p
    }()

}

/// フロントパネル LED の動作確認用プログラム(アドレス 0 から配置して RUN)
public enum LEDTestPrograms {
    /// アドレス LED A15-A8 を 1 ビットずつ左へ歩かせる。
    /// LDAX D を 16 個並べてバスのアドレスを DE に長く留め、パネル上で D のパターンが見えるようにする。
    public static let address: [UInt8] =
        [
            0x16, 0x01,        // 0000 MVI D,01
            0x1E, 0x00,        // 0002 MVI E,00
            0x21, 0x00, 0x00,  // 0004 LXI H,0000
            0x01, 0x10, 0x00,  // 0007 LXI B,0010
        ]
        + [UInt8](repeating: 0x1A, count: 16)  // 000A LDAX D x16
        + [
            0x09,              // 001A DAD B
            0xD2, 0x0A, 0x00,  // 001B JNC 000A(HL が桁あふれするまで繰り返す)
            0x7A,              // 001E MOV A,D
            0x07,              // 001F RLC
            0x57,              // 0020 MOV D,A
            0xC3, 0x04, 0x00,  // 0021 JMP 0004
        ]

    /// データ LED D7-D0 に 01,02,04,...,80,FF,00,AA,55 を順に表示する。
    /// MOV A,M を 16 個並べて、テーブル(0060h)の値をデータバスに長く留める。
    public static let data: [UInt8] = {
        var p = [UInt8](repeating: 0, count: 0x6C)
        let code: [UInt8] =
            [0x21, 0x60, 0x00,        // 0020 LXI H,0060
             0x01, 0x00, 0x10]        // 0023 LXI B,1000
            + [UInt8](repeating: 0x7E, count: 16)  // 0026 MOV A,M x16
            + [0x0B, 0x78, 0xB1,      // DCX B / MOV A,B / ORA C
               0xC2, 0x26, 0x00,      // JNZ 0026
               0x23,                  // INX H
               0x7D,                  // MOV A,L
               0xFE, 0x6C,            // CPI 6Ch
               0xC2, 0x23, 0x00,      // JNZ 0023
               0xC3, 0x20, 0x00]      // JMP 0020
        p.replaceSubrange(0x20..<0x20 + code.count, with: code)
        p.replaceSubrange(0x60..<0x6C, with: [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0xFF, 0x00, 0xAA, 0x55])
        return p
    }()

    /// ステータス LED を順に点灯させる: INTE → STACK → INP → OUT → WO(書き込みで消灯)。
    /// 先頭は 0000 に置いて RUN。HLTA は別途 HLT 1 命令(`halt`)で確認する。
    public static let status: [UInt8] = {
        var p: [UInt8] = [0x31, 0x00, 0x70]  // LXI SP,7000
        func phase(_ body: [UInt8]) {
            let loop = p.count + 3
            p += [0x01, 0x00, 0x10] + body  // LXI B,1000 + 本体 x16
            p += [0x0B, 0x78, 0xB1, 0xC2, UInt8(loop & 0xFF), UInt8(loop >> 8)]
        }
        p += [0xFB]  // EI
        phase([UInt8](repeating: 0x00, count: 16))
        p += [0xF3]  // DI
        phase([0xC5, 0xC1].repeating(8))  // PUSH B / POP B
        phase([0xDB, 0xFF].repeating(16))  // IN FFh
        phase([0xD3, 0xFF].repeating(16))  // OUT FFh
        phase([0x32, 0x00, 0x02].repeating(16))  // STA 0200h
        p += [0xC3, 0x03, 0x00]  // JMP 0003
        return p
    }()

    /// HLT のみ。RUN すると HLTA が点灯して停止する。
    public static let halt: [UInt8] = [0x76]
}

extension Array {
    fileprivate func repeating(_ n: Int) -> [Element] {
        Array([Array](repeating: self, count: n).joined())
    }
}
