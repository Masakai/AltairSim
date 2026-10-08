/// FLEX(6800 版)のディスクイメージの補助。
///
/// FLEX の論理セクタは 256 バイトで、FD3712 の物理セクタ(128 バイト)2 つからなる。
/// 対応は DSKDRV.ASM の secTbl に従う(1 トラックに論理セクタ 13 個。間に 1 セクタ挟んで、1 周で読める並び)。
public enum FLEXImage {
    /// 論理セクタ 1〜13 → 物理セクタ(前半、後半)
    static let sectorTable: [(Int, Int)] = [
        (2, 4), (3, 5), (6, 8), (7, 9), (10, 12), (11, 13), (14, 16),
        (15, 17), (18, 20), (19, 21), (22, 24), (23, 25), (26, 1),
    ]

    /// 論理セクタ(256 バイト)を読む。トラックとセクタは FLEX の番号(セクタは 1〜13)。
    public static func logicalSector(_ image: DiskImage, track: Int, sector: Int) -> [UInt8]? {
        let g = image.geometry
        guard (0..<g.tracks).contains(track), (1...sectorTable.count).contains(sector) else { return nil }
        let (a, b) = sectorTable[sector - 1]
        func physical(_ s: Int) -> ArraySlice<UInt8> {
            let off = (track * g.sectorsPerTrack + (s - 1)) * g.bytesPerSector
            return image.bytes[off..<off + g.bytesPerSector]
        }
        return Array(physical(a)) + Array(physical(b))
    }

    /// ディレクトリ(トラック 0 の論理セクタ 5〜)から、ファイルの開始位置(トラック、セクタ)を探す。
    /// エントリは 24 バイト: 名前 8、拡張子 3、属性 1、予約 1、開始トラック、開始セクタ、終了トラック、終了セクタ、サイズ 2 バイト、…
    /// 各ディレクトリセクタの先頭 16 バイトはヘッダ。
    public static func findFile(_ image: DiskImage, name: String, ext: String) -> (track: Int, sector: Int)? {
        for sector in 5...13 {
            guard let sec = logicalSector(image, track: 0, sector: sector) else { return nil }
            var k = 16
            while k + 24 <= sec.count {
                let e = Array(sec[k..<k + 24])
                k += 24
                guard e[0] != 0, e[0] != 0xFF else { continue }
                func text(_ bytes: ArraySlice<UInt8>) -> String {
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                if text(e[0..<8]) == name && text(e[8..<11]) == ext {
                    return (Int(e[13]), Int(e[14]))
                }
            }
        }
        return nil
    }

    /// LINK.CMD と同じ処理: ブートローダ(トラック 0 の物理セクタ 1)の 5・6 バイト目に、システムファイルの開始位置を書く。
    /// すでに 0 以外が書かれていれば何もしない。書いたら true。
    @discardableResult
    public static func linkBootLoader(_ image: DiskImage, systemFile: String = "FLEX3", ext: String = "SYS") -> Bool {
        guard image.bytes.count > 6, image.bytes[5] == 0, image.bytes[6] == 0,
              let pos = findFile(image, name: systemFile, ext: ext) else { return false }
        image.write(UInt8(pos.track), at: 5)
        image.write(UInt8(pos.sector), at: 6)
        return true
    }
}
