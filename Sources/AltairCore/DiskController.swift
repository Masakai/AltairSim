import Foundation

/// 8 インチフロッピーのイメージ。配布されている .dsk には末尾に余白がある場合があるので、必要サイズ以上を受け付ける。
public final class DiskImage {
    /// ディスクの寸法
    public struct Geometry: Equatable {
        public let tracks: Int
        public let sectorsPerTrack: Int
        public let bytesPerSector: Int
        public var size: Int { tracks * sectorsPerTrack * bytesPerSector }

        /// MITS 88-DCDD: 77 トラック × 32 セクタ × 137 バイト = 337,568 バイト
        public static let mitsDCDD = Geometry(tracks: 77, sectorsPerTrack: 32, bytesPerSector: 137)
        /// IBM 3740 形式(Altair 680 の FD3712): 77 トラック × 26 セクタ × 128 バイト = 256,256 バイト
        public static let ibm3740 = Geometry(tracks: 77, sectorsPerTrack: 26, bytesPerSector: 128)
    }

    // 88-DCDD 用の定数(以前の呼び出しとの互換のため残す)
    public static let tracks = Geometry.mitsDCDD.tracks
    public static let sectorsPerTrack = Geometry.mitsDCDD.sectorsPerTrack
    public static let bytesPerSector = Geometry.mitsDCDD.bytesPerSector
    public static let size = Geometry.mitsDCDD.size

    public enum LoadError: Error, CustomStringConvertible {
        case wrongSize(Int, need: Int)
        public var description: String {
            switch self {
            case .wrongSize(let n, let need):
                return "ディスクイメージのサイズが \(n) バイトです(\(need) バイト以上が必要)"
            }
        }
    }

    public let geometry: Geometry
    public private(set) var bytes: [UInt8]
    public let url: URL?
    public private(set) var dirty = false

    /// セクタごとの「フォーマット済み」の記録(トラック順、トラック内はセクタ順)。nil はすべてフォーマット済み。
    /// 新規に作った空のイメージは、全セクタが未フォーマットで始まる。ファイルは生のバイト列のままなので、記録は
    /// 別ファイル(`<イメージ>.fmt`)に置く。ファイルがなければ、すべてフォーマット済みとして扱う。
    /// 使うのは FD3712(IBM 3740 形式のセクタは、書いて初めて存在する)。88-DCDD は、ヘッダを書いていない生のセクタが
    /// BIOS のヘッダ検査で弾かれるので、この記録を使わない。
    public private(set) var formatMap: [Bool]?
    private var formatDirty = false
    /// true の間は書き込みを無視する
    public var writeProtected = false

    public init(bytes: [UInt8], url: URL? = nil, geometry: Geometry = .mitsDCDD, formatMap: [Bool]? = nil) throws {
        guard bytes.count >= geometry.size else { throw LoadError.wrongSize(bytes.count, need: geometry.size) }
        self.bytes = bytes
        self.url = url
        self.geometry = geometry
        if let formatMap, formatMap.count == geometry.tracks * geometry.sectorsPerTrack, formatMap.contains(false) {
            self.formatMap = formatMap
        }
    }

    public convenience init(contentsOf url: URL, geometry: Geometry = .mitsDCDD) throws {
        try self.init(bytes: [UInt8](try Data(contentsOf: url)), url: url, geometry: geometry,
                      formatMap: Self.loadFormatMap(for: url, count: geometry.tracks * geometry.sectorsPerTrack))
    }

    /// 記録ファイルの場所(`foo.dsk` なら `foo.dsk.fmt`)
    public static func formatMapURL(for url: URL) -> URL { url.appendingPathExtension("fmt") }

    private static func loadFormatMap(for url: URL, count: Int) -> [Bool]? {
        guard let data = try? Data(contentsOf: formatMapURL(for: url)), data.count == count else { return nil }
        return data.map { $0 != 0 }
    }

    /// 新しい空のイメージ(全バイト 0)をファイルとして作る。unformatted が true なら、記録ファイルも作って全セクタを未フォーマットにする。
    @discardableResult
    public static func createBlank(at url: URL, geometry: Geometry, unformatted: Bool, cpmDirectory: Bool = false) throws -> DiskImage {
        let initial = cpmDirectory ? emptyCPMDirectoryImage(geometry: geometry) : [UInt8](repeating: 0, count: geometry.size)
        try Data(initial).write(to: url, options: .atomic)
        let count = geometry.tracks * geometry.sectorsPerTrack
        let map: [Bool]? = unformatted ? [Bool](repeating: false, count: count) : nil
        if let map { try Data(map.map { $0 ? 1 : 0 }).write(to: formatMapURL(for: url), options: .atomic) }
        else { try? FileManager.default.removeItem(at: formatMapURL(for: url)) }
        return try DiskImage(bytes: initial, url: url, geometry: geometry, formatMap: map)
    }

    /// そのセクタ(トラック、セクタ番号は 0 始まり)はフォーマット済みか
    func isFormatted(track: Int, sector: Int) -> Bool {
        guard let formatMap else { return true }
        let i = track * geometry.sectorsPerTrack + sector
        return formatMap.indices.contains(i) ? formatMap[i] : true
    }

    /// IMSAI CP/M 1.31(IBM 3740 形式、26 セクタ × 128 バイト)の、フォーマット済みの空ディスクのバイト列。
    /// CP/M のディレクトリ(トラック 2 の 26 セクタ、64 エントリ)だけを、空を表す E5 で埋め、残りは 0。
    /// マニュアルの言う「工場出荷の IBM 互換ディスク」にあたり、IMSAI CP/M 1.31 はフォーマットの機能を持たないので、
    /// ユーザーはこのような(フォーマット済みの)ディスクを使う(ユーザーガイド 6.6 SYSGEN の項)。
    public static func emptyCPMDirectoryImage(geometry: Geometry = .ibm3740) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: geometry.size)
        let directoryTrack = 2
        let start = directoryTrack * geometry.sectorsPerTrack * geometry.bytesPerSector
        for i in 0..<(geometry.sectorsPerTrack * geometry.bytesPerSector) { bytes[start + i] = 0xE5 }
        return bytes
    }

    /// セクタを書いたので、フォーマット済みにする
    func markFormatted(track: Int, sector: Int) {
        guard formatMap != nil else { return }
        let i = track * geometry.sectorsPerTrack + sector
        guard formatMap!.indices.contains(i), !formatMap![i] else { return }
        formatMap![i] = true
        formatDirty = true
        if !formatMap!.contains(false) { formatMap = nil }   // 全部そろったら記録は要らない
    }

    /// 未フォーマットのセクタの数(記録がなければ 0)
    public var unformattedSectorCount: Int { formatMap?.filter { !$0 }.count ?? 0 }

    /// 空のフォーマット済みイメージ(全バイト 0)
    public static func blank(geometry: Geometry = .mitsDCDD) -> DiskImage {
        try! DiskImage(bytes: [UInt8](repeating: 0, count: geometry.size), geometry: geometry)
    }

    func read(at offset: Int) -> UInt8? {
        offset >= 0 && offset < bytes.count ? bytes[offset] : nil
    }

    func write(_ value: UInt8, at offset: Int) {
        guard !writeProtected, offset >= 0, offset < bytes.count else { return }
        bytes[offset] = value
        dirty = true
    }

    /// 変更をファイルへ書き戻す(url があるときのみ)
    public func flush() throws {
        guard let url else { return }
        if dirty {
            try Data(bytes).write(to: url, options: .atomic)
            dirty = false
        }
        if formatDirty {
            if let formatMap {
                try Data(formatMap.map { $0 ? 1 : 0 }).write(to: Self.formatMapURL(for: url), options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: Self.formatMapURL(for: url))
            }
            formatDirty = false
        }
    }

    /// 書き戻す内容があるか(ファイルまたはフォーマットの記録)
    public var hasUnsavedChanges: Bool { dirty || formatDirty }
}

/// ディスクコントローラに共通の、装着・取り外しと表示用の情報。
/// アプリのドライブ画面は、機種(Altair 8800 の 88-DCDD、Altair 680 の FD3712)を問わずこの口から状態を読む。
public protocol DiskSubsystem: AnyObject {
    func mount(_ image: DiskImage, drive: Int)
    func unmount(drive: Int)
    func image(drive: Int) -> DiskImage?
    func headPosition(drive: Int) -> (track: Int, sector: Int)?
    var activityCounter: Int { get }
    var lastActiveDrive: Int? { get }
    func flushAll()
    func reset()
}

/// MITS 88-DCDD フロッピーディスクコントローラ(ポート 08h-0Ah)。
/// 回転待ちは時間ではなく「セクタレジスタを読むたびに 1 セクタ進む」簡易モデルで、
/// CP/M の BIOS やディスクブートローダ(88dskrom)はこれで動作する。
public final class DiskController: DiskSubsystem {
    public static let maxDrives = 16

    public static let statusPort: UInt8 = 0x08  // 読み: ステータス / 書き: ドライブ選択
    public static let sectorPort: UInt8 = 0x09  // 読み: セクタ位置 / 書き: コマンド
    public static let dataPort: UInt8 = 0x0A

    // ステータス(負論理: 0 が有効)
    private static let writeReady: UInt8 = 0x01
    private static let moveHead: UInt8 = 0x02
    private static let headLoaded: UInt8 = 0x04
    private static let driveSelect: UInt8 = 0x08
    private static let interruptEnabled: UInt8 = 0x20
    private static let trackZero: UInt8 = 0x40
    private static let readReady: UInt8 = 0x80
    private static let idleStatus: UInt8 = 0xEF

    // コマンド
    private static let stepIn: UInt8 = 0x01
    private static let stepOut: UInt8 = 0x02
    private static let loadHead: UInt8 = 0x04
    private static let unloadHead: UInt8 = 0x08
    private static let enableInterrupt: UInt8 = 0x10
    private static let disableInterrupt: UInt8 = 0x20
    private static let writeEnable: UInt8 = 0x80

    private struct Drive {
        var image: DiskImage?
        var status: UInt8 = DiskController.idleStatus
        var track = 0
        var sector: UInt8 = 0
        var index = 0
        /// true のとき、ヘッドはセクタとセクタの間(セクタレジスタの bit0 = 1)にいる
        var inGap = false
        /// 書き込み許可の直後にヘッドアンロードを受けた。書き込み回路は、そのセクタを書き終えるまでヘッドをロードしたままにする
        /// (マニュアル p.135「Head Unload … may be unloaded immediately after Write Enable」)
        var unloadPending = false
    }

    private var drives = [Drive](repeating: Drive(), count: DiskController.maxDrives)
    /// 選択中のドライブ(nil は未選択)
    public private(set) var selected: Int?

    /// 直近のアクセスがあったドライブ番号(UI のランプ用)
    public private(set) var lastActiveDrive: Int?
    public private(set) var activityCounter = 0

    public init() {}

    // MARK: 装着

    public func mount(_ image: DiskImage, drive: Int) {
        guard (0..<Self.maxDrives).contains(drive) else { return }
        drives[drive].image = image
    }

    public func unmount(drive: Int) {
        guard (0..<Self.maxDrives).contains(drive) else { return }
        try? drives[drive].image?.flush()
        drives[drive].image = nil
        if selected == drive { selected = nil }
    }

    public func image(drive: Int) -> DiskImage? {
        (0..<Self.maxDrives).contains(drive) ? drives[drive].image : nil
    }

    public func headPosition(drive: Int) -> (track: Int, sector: Int)? {
        guard (0..<Self.maxDrives).contains(drive) else { return nil }
        return (drives[drive].track, Int(drives[drive].sector))
    }

    /// 全ドライブの状態を電源投入直後に戻す(装着したイメージは保持)
    public func reset() {
        selected = nil
        for i in drives.indices {
            drives[i].status = Self.idleStatus
            drives[i].track = 0
            drives[i].sector = 0
            drives[i].index = 0
        }
    }

    public func flushAll() {
        for d in drives { try? d.image?.flush() }
    }

    // MARK: ポート入出力

    public func read(port: UInt8) -> UInt8? {
        switch port {
        case Self.statusPort: return statusRegister()
        case Self.sectorPort: return sectorRegister()
        case Self.dataPort: return readData()
        default: return nil
        }
    }

    @discardableResult
    public func write(port: UInt8, value: UInt8) -> Bool {
        switch port {
        case Self.statusPort: select(value)
        case Self.sectorPort: command(value)
        case Self.dataPort: writeData(value)
        default: return false
        }
        return true
    }

    // MARK: 内部動作

    private var headIsLoaded: Bool {
        guard let s = selected else { return false }
        return drives[s].status & Self.headLoaded == 0
    }

    private func statusRegister() -> UInt8 {
        guard let s = selected else { return 0xFF }
        return drives[s].status
    }

    /// セクタレジスタの読み出し。実機ではセクタごとにセクタ真(bit0 = 0)の区間があり、その間が bit0 = 1 になる。
    /// 時間を持たないこのモデルでは、読むたびに「区間の外(bit0 = 1、次のセクタの番号)」と「区間の中(bit0 = 0、セクタを進める)」を
    /// 交互に返す。BIOS の「セクタ真を待つ」ループはどちらでも動き、AFORMAT のようにセクタの切れ目に同期するプログラムも動く。
    ///
    /// セクタ位置は、ディスクの回転に付いたセクタ穴から作られる信号なので、ヘッドのロードとは関係なく、
    /// ドライブが選択されていれば読める(ヘッドのロードが要るのはデータの読み書き)。CP/M の AFORMAT は、
    /// トラックを書き終えるとヘッドをアンロードし、ロードし直さずに次のトラックのセクタ位置を待つ。
    private func sectorRegister() -> UInt8 {
        guard let s = selected else { return 0xFF }
        let count = UInt8(DiskImage.sectorsPerTrack)
        noteActivity(s)
        if !drives[s].inGap {
            drives[s].inGap = true
            return (((drives[s].sector &+ 1) % count) << 1) | 1  // 切れ目(次のセクタの番号、bit0 = 1)
        }
        drives[s].inGap = false
        drives[s].sector = (drives[s].sector &+ 1) % count
        drives[s].index = 0
        return drives[s].sector << 1  // bit0 = 0: セクタ位置にヘッドがある
    }

    private func offset(_ d: Drive) -> Int {
        (d.track * DiskImage.sectorsPerTrack + Int(d.sector)) * DiskImage.bytesPerSector + d.index
    }

    private func readData() -> UInt8 {
        guard let s = selected, headIsLoaded, let image = drives[s].image else { return 0xFF }
        let v = image.read(at: offset(drives[s])) ?? 0
        drives[s].index += 1
        noteActivity(s)
        return v
    }

    private func writeData(_ value: UInt8) {
        guard let s = selected, headIsLoaded, let image = drives[s].image else { return }
        guard drives[s].status & Self.writeReady == 0 else { return }  // 書き込み未許可
        // 書き込み区間はセクタの終わりで閉じる。それ以降に送られたバイトは、ディスクには書かれない
        // (CP/M の AFORMAT は 137 バイトのあとにも数バイト送るので、これがないと次のセクタのヘッダを壊す)
        guard drives[s].index < DiskImage.bytesPerSector else { return }
        image.write(value, at: offset(drives[s]))
        drives[s].index += 1
        noteActivity(s)
        if drives[s].index >= DiskImage.bytesPerSector { completeUnloadIfPending(s) }
    }

    /// ステップのあと、ヘッドステータス(HS)は true になる(マニュアル p.134「HS — True 40 ms after head loaded or step command」)。
    /// CP/M の AFORMAT は、トラックを書き終えるとヘッドをアンロードし、ステップインしたあと、ヘッドをロードし直さずに
    /// 次のトラックへ書き込む。そのため、ステップはヘッドをロードした状態にする。
    private func stepLoadsHead(_ s: Int) {
        drives[s].status &= ~(Self.headLoaded | Self.readReady)
    }

    /// ヘッドを実際に外す(ステータスのヘッドロード・読み出し可・書き込み可のビットを戻す)
    private func completeUnload(_ s: Int) {
        drives[s].unloadPending = false
        drives[s].status |= Self.headLoaded | Self.readReady | Self.writeReady
        try? drives[s].image?.flush()
    }

    private func completeUnloadIfPending(_ s: Int) {
        if drives[s].unloadPending { completeUnload(s) }
    }

    private func select(_ value: UInt8) {
        if value & 0x80 != 0 {
            if let s = selected {
                drives[s].status |= Self.driveSelect | Self.moveHead
                try? drives[s].image?.flush()
                selected = nil
            }
        } else {
            let n = Int(value & 0x0F)
            if drives[n].image == nil {
                drives[n].status |= Self.driveSelect | Self.moveHead
                selected = nil
            } else {
                drives[n].status &= ~(Self.driveSelect | Self.moveHead)
                selected = n
            }
        }
    }

    private func command(_ value: UInt8) {
        guard let s = selected else { return }
        if value != Self.unloadHead && value != Self.writeEnable { completeUnloadIfPending(s) }
        switch value {
        case Self.stepIn:
            if drives[s].track < DiskImage.tracks - 1 {
                drives[s].track += 1
                drives[s].sector = 0xFF
                drives[s].index = 0
                drives[s].inGap = false
            }
            drives[s].status |= Self.trackZero
            stepLoadsHead(s)
        case Self.stepOut:
            if drives[s].track > 0 {
                drives[s].track -= 1
                drives[s].sector = 0xFF
                drives[s].index = 0
                drives[s].inGap = false
            } else {
                drives[s].status &= ~Self.trackZero
            }
            stepLoadsHead(s)
        case Self.loadHead:
            drives[s].status &= ~(Self.headLoaded | Self.readReady)
            drives[s].sector = 0xFF  // 次のセクタ読み出しで 0 になる
            drives[s].inGap = false
        case Self.unloadHead:
            if drives[s].status & Self.writeReady == 0 {
                // 書き込み許可中のアンロードは、書き込みが終わってから効く(writeData / 次のコマンドで確定)
                drives[s].unloadPending = true
            } else {
                completeUnload(s)
            }
        case Self.enableInterrupt:
            drives[s].status |= Self.interruptEnabled
        case Self.disableInterrupt:
            drives[s].status &= ~Self.interruptEnabled
        case Self.writeEnable:
            completeUnloadIfPending(s)   // 前のセクタの保留中のアンロードは、ここで確定する
            drives[s].index = 0
            drives[s].status &= ~Self.writeReady
        default:
            break
        }
    }

    private func noteActivity(_ drive: Int) {
        lastActiveDrive = drive
        activityCounter &+= 1
    }
}
