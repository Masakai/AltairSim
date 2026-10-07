import Foundation

/// 8 インチフロッピーのイメージ(77 トラック × 32 セクタ × 137 バイト = 337,568 バイト)。
/// 配布されている .dsk には末尾に余白がある場合がある(CP/M 2.2 は 337,664 バイト)ので、それ以上のサイズを受け付ける。
public final class DiskImage {
    public static let tracks = 77
    public static let sectorsPerTrack = 32
    public static let bytesPerSector = 137
    public static let size = tracks * sectorsPerTrack * bytesPerSector

    public enum LoadError: Error, CustomStringConvertible {
        case wrongSize(Int)
        public var description: String {
            switch self {
            case .wrongSize(let n):
                return "ディスクイメージのサイズが \(n) バイトです(\(DiskImage.size) バイト以上が必要)"
            }
        }
    }

    public private(set) var bytes: [UInt8]
    public let url: URL?
    public private(set) var dirty = false
    /// true の間は書き込みを無視する
    public var writeProtected = false

    public init(bytes: [UInt8], url: URL? = nil) throws {
        guard bytes.count >= Self.size else { throw LoadError.wrongSize(bytes.count) }
        self.bytes = bytes
        self.url = url
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](try Data(contentsOf: url)), url: url)
    }

    /// 空のフォーマット済みイメージ(全バイト 0xE5 ではなく 0。CP/M 側で初期化して使う)
    public static func blank() -> DiskImage {
        try! DiskImage(bytes: [UInt8](repeating: 0, count: size))
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
        guard dirty, let url else { return }
        try Data(bytes).write(to: url, options: .atomic)
        dirty = false
    }
}

/// MITS 88-DCDD フロッピーディスクコントローラ(ポート 08h-0Ah)。
/// 回転待ちは時間ではなく「セクタレジスタを読むたびに 1 セクタ進む」簡易モデルで、
/// CP/M の BIOS やディスクブートローダ(88dskrom)はこれで動作する。
public final class DiskController {
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

    private func sectorRegister() -> UInt8 {
        guard let s = selected, headIsLoaded else { return 0xFF }
        drives[s].sector = (drives[s].sector &+ 1) % UInt8(DiskImage.sectorsPerTrack)
        drives[s].index = 0
        noteActivity(s)
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
        image.write(value, at: offset(drives[s]))
        drives[s].index += 1
        noteActivity(s)
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
        switch value {
        case Self.stepIn:
            if drives[s].track < DiskImage.tracks - 1 {
                drives[s].track += 1
                drives[s].sector = 0xFF
                drives[s].index = 0
            }
            drives[s].status |= Self.trackZero
        case Self.stepOut:
            if drives[s].track > 0 {
                drives[s].track -= 1
                drives[s].sector = 0xFF
                drives[s].index = 0
            } else {
                drives[s].status &= ~Self.trackZero
            }
        case Self.loadHead:
            drives[s].status &= ~(Self.headLoaded | Self.readReady)
            drives[s].sector = 0xFF  // 次のセクタ読み出しで 0 になる
        case Self.unloadHead:
            drives[s].status |= Self.headLoaded | Self.readReady | Self.writeReady
            try? drives[s].image?.flush()
        case Self.enableInterrupt:
            drives[s].status |= Self.interruptEnabled
        case Self.disableInterrupt:
            drives[s].status &= ~Self.interruptEnabled
        case Self.writeEnable:
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
