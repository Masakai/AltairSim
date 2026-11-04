import Foundation

public enum CPMDiskError: Error, CustomStringConvertible {
    case badImageSize(Int, expected: Int)
    case invalidName(String)
    case diskFull(file: String, needKB: Int, freeKB: Int)
    case directoryFull(file: String)
    case fileTooLarge(String)

    public var description: String {
        switch self {
        case .badImageSize(let n, let expected): return "ディスクイメージのサイズが小さすぎます(\(n) バイト、\(expected) バイト以上が必要)"
        case .invalidName(let s): return "CP/M のファイル名にできません: \(s)(8 文字以内の名前と 3 文字以内の拡張子、英数字と一部の記号のみ)"
        case .diskFull(let f, let need, let free): return "\(f) が入りません(必要 \(need) KB、空き \(free) KB)"
        case .directoryFull(let f): return "\(f) を登録するディレクトリの空きがありません"
        case .fileTooLarge(let f): return "\(f) が大きすぎます"
        }
    }
}

/// CP/M 2.2 のディスクイメージ(Altair 8800 用 8 インチ、MITS 88-DCDD の 137 バイトセクタ)に、ファイルを書き込む・消す・一覧する。
///
/// ディスクの形式(Burcon の CP/M 2.2 の BIOS が持つ DPB とスキューのテーブルから読み取った値):
/// - 77 トラック × 32 セクタ × 137 バイト。セクタの中身はトラックで 2 通りある(BIOS の読み出しルーチンが、トラック 6 を境に分けている):
///   - トラック 0〜5: ヘッダ 3 バイト、データは 3〜130 バイトの 128 バイト、131 が 0xFF、132 がチェックサム(データ 128 バイトの和)
///   - トラック 6 以降: ヘッダ 7 バイト(1 がセクタ番号 = 物理位置 × 17 mod 32、4 がチェックサム)、データは 7〜134 バイトの 128 バイト、135 が 0xFF。チェックサムは、0・1・4 バイト目を除く
///     0〜135 バイト目の和に 1 を足したもの。BIOS は読むたびにこの検査をして、合わないと Bad Sector にする
/// - 先頭 2 トラックはシステム領域。ディレクトリはトラック 2 から、ブロックは 2KB(16 レコード)、ブロック数は 150(DSM = 149)、ディレクトリは 64 エントリ(ブロック 0 と 1)
/// - 論理セクタ(レコード)から物理セクタへは、17 刻みのスキュー(1, 9, 17, 25, 3, 11, …)
public final class CPMDisk {
    public struct Layout {
        public var tracks: Int
        public var sectorsPerTrack: Int
        public var sectorBytes: Int
        /// このトラック番号より前は「3 バイトヘッダ」の形式、以降は「7 バイトヘッダ」の形式
        public var shortHeaderTracks: Int
        public var reservedTracks: Int
        public var blockSize: Int
        public var blockCount: Int
        public var directoryEntries: Int
        /// ディレクトリ用に確保されたブロック数(DPB の AL0 = C0h で 2 ブロック)
        public var directoryBlocks: Int
        /// 論理セクタ(0 始まり)→ 物理セクタ(0 始まり)
        public var skew: [Int]

        public var imageSize: Int { tracks * sectorsPerTrack * sectorBytes }
        public var recordsPerBlock: Int { blockSize / 128 }

        public static let altair8800: Layout = {
            let oneBased = [1, 9, 17, 25, 3, 11, 19, 27, 5, 13, 21, 29, 7, 15, 23, 31,
                            2, 10, 18, 26, 4, 12, 20, 28, 6, 14, 22, 30, 8, 16, 24, 32]
            return Layout(tracks: 77, sectorsPerTrack: 32, sectorBytes: 137, shortHeaderTracks: 6, reservedTracks: 2,
                          blockSize: 2048, blockCount: 150, directoryEntries: 64, directoryBlocks: 2, skew: oneBased.map { $0 - 1 })
        }()
    }

    public struct Entry: Equatable {
        public var name: String       // "NAME.EXT"
        public var user: Int
        public var records: Int
        public var blocks: Int
        public var sizeBytes: Int { records * 128 }
    }

    public let layout: Layout
    public private(set) var image: [UInt8]

    public init(image: [UInt8], layout: Layout = .altair8800) throws {
        guard image.count >= layout.imageSize else { throw CPMDiskError.badImageSize(image.count, expected: layout.imageSize) }
        self.image = image
        self.layout = layout
    }

    public convenience init(contentsOf url: URL, layout: Layout = .altair8800) throws {
        try self.init(image: [UInt8](try Data(contentsOf: url)), layout: layout)
    }

    public func write(to url: URL) throws { try Data(image).write(to: url, options: .atomic) }

    // MARK: レコード(128 バイト)の読み書き

    private func location(record r: Int) -> (base: Int, track: Int) {
        let track = layout.reservedTracks + r / layout.sectorsPerTrack
        var physical = layout.skew[r % layout.sectorsPerTrack]
        // トラック 6 以降は、スキューの値が「セクタ番号」(ヘッダの 1 バイト目)になっている。ヘッダの番号は、物理位置 p のセクタが
        // (p × 17) mod 32(17 は mod 32 で自分自身の逆数なので、位置 = 番号 × 17 mod 32)
        if track >= layout.shortHeaderTracks { physical = (physical * 17) % layout.sectorsPerTrack }
        return ((track * layout.sectorsPerTrack + physical) * layout.sectorBytes, track)
    }

    private func dataStart(track: Int) -> Int { track < layout.shortHeaderTracks ? 3 : 7 }

    private func readRecord(_ r: Int) -> ArraySlice<UInt8> {
        let (base, track) = location(record: r)
        let o = base + dataStart(track: track)
        return image[o..<o + 128]
    }

    /// データを書いて、チェックサムを合わせる(ヘッダは元のまま)。
    private func writeRecord(_ r: Int, _ data: [UInt8]) {
        let (base, track) = location(record: r)
        let o = base + dataStart(track: track)
        for i in 0..<128 { image[o + i] = data[i] }
        if track < layout.shortHeaderTracks {
            image[base + 132] = UInt8(truncatingIfNeeded: image[o..<o + 128].reduce(0) { $0 &+ Int($1) })
        } else {
            var sum = 1
            for i in 0..<136 where i != 0 && i != 1 && i != 4 { sum += Int(image[base + i]) }
            image[base + 4] = UInt8(truncatingIfNeeded: sum)
        }
    }

    // MARK: ディレクトリ

    private var directoryRecords: Int { layout.directoryEntries / 4 }

    private func readDirectory() -> [[UInt8]] {
        var entries: [[UInt8]] = []
        for r in 0..<directoryRecords {
            let rec = readRecord(r)
            for k in 0..<4 { entries.append(Array(rec[rec.startIndex + 32 * k ..< rec.startIndex + 32 * k + 32])) }
        }
        return entries
    }

    private func writeDirectory(_ entries: [[UInt8]]) {
        for r in 0..<directoryRecords {
            var rec: [UInt8] = []
            for k in 0..<4 { rec += entries[r * 4 + k] }
            writeRecord(r, rec)
        }
    }

    private static func isUsed(_ e: [UInt8]) -> Bool { e[0] <= 15 }

    private static func displayName(_ e: [UInt8]) -> String {
        let n = String(decoding: e[1...8].map { $0 & 0x7F }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let x = String(decoding: e[9...11].map { $0 & 0x7F }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return x.isEmpty ? n : "\(n).\(x)"
    }

    private func pointers(_ e: [UInt8]) -> [Int] { e[16..<32].map(Int.init).filter { $0 != 0 } }

    /// 使用中のブロック(ディレクトリ用の先頭ブロックを含む)
    private func usedBlocks(_ dir: [[UInt8]]) -> Set<Int> {
        var used = Set(0..<layout.directoryBlocks)
        for e in dir where Self.isUsed(e) { used.formUnion(pointers(e)) }
        return used
    }

    public var freeBlocks: Int { layout.blockCount - usedBlocks(readDirectory()).count }
    public var freeKB: Int { freeBlocks * layout.blockSize / 1024 }
    public var capacityKB: Int { (layout.blockCount - layout.directoryBlocks) * layout.blockSize / 1024 }

    /// ユーザー 0 のファイルの一覧(複数のエクステントは 1 件にまとめる)
    public func files() -> [Entry] {
        var order: [String] = []
        var map: [String: Entry] = [:]
        for e in readDirectory() where Self.isUsed(e) {
            let name = Self.displayName(e)
            let user = Int(e[0])
            let key = "\(user):\(name)"
            // RC は、そのエクステントのレコード数(最大 128)
            var item = map[key] ?? Entry(name: name, user: user, records: 0, blocks: 0)
            item.records += Int(e[15])
            item.blocks += pointers(e).count
            if map[key] == nil { order.append(key) }
            map[key] = item
        }
        return order.compactMap { map[$0] }
    }

    // MARK: 名前

    /// "name.ext" を 8+3 の 11 バイトにする。使えない文字があれば nil。
    static func fcbName(_ s: String) -> [UInt8]? {
        let upper = s.uppercased()
        let parts = upper.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        let ext = parts.count > 1 ? parts[1] : ""
        guard (1...8).contains(name.count), ext.count <= 3 else { return nil }
        let forbidden = Set(" <>.,;:=?*[]_%|()/\\")
        var out: [UInt8] = []
        for field in [(name, 8), (ext, 3)] {
            var bytes: [UInt8] = []
            for ch in field.0.unicodeScalars {
                guard ch.value > 0x20, ch.value < 0x7F, !forbidden.contains(Character(ch)) else { return nil }
                bytes.append(UInt8(ch.value))
            }
            out += bytes + [UInt8](repeating: 0x20, count: field.1 - bytes.count)
        }
        return out
    }

    // MARK: 書き込み・削除

    /// ファイルを追加する。同じ名前(ユーザー 0)があれば置き換える。
    public func add(name: String, data: [UInt8]) throws {
        guard let fcb = Self.fcbName(name) else { throw CPMDiskError.invalidName(name) }
        remove(name: name)
        var dir = readDirectory()
        let used = usedBlocks(dir)
        let records = (data.count + 127) / 128
        let blocksNeeded = (records + layout.recordsPerBlock - 1) / layout.recordsPerBlock
        let free = (0..<layout.blockCount).filter { !used.contains($0) }
        guard blocksNeeded <= free.count else {
            throw CPMDiskError.diskFull(file: name, needKB: blocksNeeded * layout.blockSize / 1024, freeKB: free.count * layout.blockSize / 1024)
        }
        let extentBlocks = 128 / layout.recordsPerBlock   // EXM = 0: 1 エクステントは 16KB(128 レコード)。2KB ブロックなら 8 ブロック
        let extents = max(1, (blocksNeeded + extentBlocks - 1) / extentBlocks)
        let slots = dir.indices.filter { !Self.isUsed(dir[$0]) }
        guard extents <= slots.count else { throw CPMDiskError.directoryFull(file: name) }
        guard extents <= 32 * 16 else { throw CPMDiskError.fileTooLarge(name) }

        let blocks = Array(free.prefix(blocksNeeded))
        // データ(最後のレコードは 0x1A で埋める)
        var padded = data
        padded += [UInt8](repeating: 0x1A, count: records * 128 - data.count)
        for (i, b) in blocks.enumerated() {
            for k in 0..<layout.recordsPerBlock {
                let index = i * layout.recordsPerBlock + k
                guard index < records else { break }
                writeRecord(b * layout.recordsPerBlock + k, Array(padded[index * 128 ..< index * 128 + 128]))
            }
        }
        // エクステント(1 つあたり最大 16 ブロック = 128 レコード)
        for x in 0..<extents {
            var e = [UInt8](repeating: 0, count: 32)
            e[0] = 0
            e.replaceSubrange(1..<12, with: fcb)
            e[12] = UInt8(x & 0x1F)
            e[14] = UInt8(x >> 5)
            let mine = Array(blocks.dropFirst(x * extentBlocks).prefix(extentBlocks))
            e[15] = UInt8(min(128, max(0, records - x * 128)))
            for (i, b) in mine.enumerated() { e[16 + i] = UInt8(b) }
            dir[slots[x]] = e
        }
        writeDirectory(dir)
    }

    @discardableResult
    public func remove(name: String) -> Bool {
        guard let fcb = Self.fcbName(name) else { return false }
        var dir = readDirectory()
        var removed = false
        for i in dir.indices where Self.isUsed(dir[i]) && dir[i][0] == 0 && Array(dir[i][1..<12].map { $0 & 0x7F }) == fcb {
            dir[i] = [UInt8](repeating: 0xE5, count: 32)
            removed = true
        }
        if removed { writeDirectory(dir) }
        return removed
    }

    /// ファイルの内容(最後のレコードの 0x1A の埋め草も含む)
    public func read(name: String) -> [UInt8]? {
        guard let fcb = Self.fcbName(name) else { return nil }
        let dir = readDirectory().filter { Self.isUsed($0) && $0[0] == 0 && Array($0[1..<12].map { $0 & 0x7F }) == fcb }
            .sorted { Int($0[12]) + Int($0[14]) * 32 < Int($1[12]) + Int($1[14]) * 32 }
        guard !dir.isEmpty else { return nil }
        var out: [UInt8] = []
        for e in dir {
            var remaining = Int(e[15])
            for b in pointers(e) {
                for k in 0..<layout.recordsPerBlock where remaining > 0 {
                    out += readRecord(b * layout.recordsPerBlock + k)
                    remaining -= 1
                }
            }
        }
        return out
    }

    /// ファイルをすべて消す(システム領域はそのまま)。データ領域は 0xE5 で埋める。
    public func eraseAllFiles() {
        let blank = [UInt8](repeating: 0xE5, count: 128)
        for r in 0..<(layout.blockCount * layout.recordsPerBlock) { writeRecord(r, blank) }
    }
}
