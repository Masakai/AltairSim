import Foundation

/// Pertec FD3712(iCOM 360 と同じ系統のドライブ筐体と、内蔵の制御部)を、Altair 680 の 68-UIO ボードの 2 つの PIA 越しに見たときの動作。
///
/// 接続(68-UIO、FLEX 3.0 の DSKDRV.ASM と、FLEX 1.0 の BOOT.ASM による):
/// - PIA #1(F008〜F00B): ポート A = ステータス/データの入力(論理が反転している)、ポート B = コマンドの出力
/// - PIA #2(F00C〜F00F): ポート A = 未使用、ポート B = データの出力
/// - 実行のストローブ: コマンドの bit 0(実行ビット)は、データ出力側の CB2 とデータ入力側の CA2 のハンドシェイク線の OR になっている。
///   つまり、データ出力ポートへの書き込み(CB2)か、データ入力ポートの読み出し(CA2、自動ハンドシェイクのとき)が、
///   そのときのコマンドを 1 回実行させる
///
/// コマンド(ポート B の値): 00 ステータス、03 セクタ読み出し、05 セクタ書き込み、07 CRC 検証、09 シーク、0B エラー消去、
/// 0D トラック 0 へ復帰、11 トラック設定、21 ドライブ/セクタ設定、31 書き込みバッファ、41 読み出しバッファ、81 リセット
///
/// ステータス: bit0 = ビジー、bit3 = CRC エラー、bit4 = 書き込み禁止、bit5 = ドライブ未接続。ポート A にはビット反転で見える。
///
/// この実装は、ドライバから見える動作(コマンドとステータス、128 バイトのバッファ)を再現する。
/// 回転待ちはコマンドごとの所要時間(ビジーの長さ)で近似しており、ディスクの回転位置は持たない。
public final class FD3712Controller: DiskSubsystem {
    public static let maxDrives = 4
    public static let sectorsPerTrack = DiskImage.Geometry.ibm3740.sectorsPerTrack
    public static let bytesPerSector = DiskImage.Geometry.ibm3740.bytesPerSector

    // ステータス
    static let sBusy: UInt8 = 0x01
    static let sCRCError: UInt8 = 0x08
    static let sWriteProtect: UInt8 = 0x10
    static let sNotReady: UInt8 = 0x20

    // コマンド
    enum Command {
        static let status: UInt8 = 0x00
        static let read: UInt8 = 0x03
        static let write: UInt8 = 0x05
        static let readCRC: UInt8 = 0x07
        static let seek: UInt8 = 0x09
        static let clearErrors: UInt8 = 0x0B
        static let restore: UInt8 = 0x0D
        static let setTrack: UInt8 = 0x11
        static let driveSector: UInt8 = 0x21
        static let writeBuffer: UInt8 = 0x31
        static let readBuffer: UInt8 = 0x41
        static let reset: UInt8 = 0x81
    }

    public let pia1 = PIA6821()   // IC-C: A = 入力(ステータス/データ)、B = コマンド出力
    public let pia2 = PIA6821()   // IC-B: A = 未使用、B = データ出力

    private var images = [DiskImage?](repeating: nil, count: FD3712Controller.maxDrives)
    private var headTrack = [Int](repeating: 0, count: FD3712Controller.maxDrives)
    private var drive = 0
    private var sector = 1
    private var trackRegister = 0
    private var buffer = [UInt8](repeating: 0, count: FD3712Controller.bytesPerSector)
    private var bufferIndex = 0
    private var errors: UInt8 = 0
    private var busyUntil = 0

    /// 現在のクロック(マシンの経過サイクル)。ビジーの長さの計算に使う
    private let now: () -> Int
    private let cyclesPerMicrosecond: Int

    public private(set) var activityCounter = 0
    public private(set) var lastActiveDrive: Int?

    /// 実行されたコマンドを通知する(デバッグ用): (コマンド, データ, ドライブ, トラック, セクタ)
    public var onCommand: ((UInt8, UInt8, Int, Int, Int) -> Void)?

    public init(clockHz: Int, now: @escaping () -> Int) {
        self.now = now
        self.cyclesPerMicrosecond = max(clockHz / 1_000_000, 1)
        pia1.inputA = { [unowned self] in self.dataInValue() }
        pia1.onCA2Strobe = { [unowned self] in self.strobe() }
        pia2.onCB2Strobe = { [unowned self] in self.strobe() }
    }

    // MARK: 装着

    public func mount(_ image: DiskImage, drive: Int) {
        guard (0..<Self.maxDrives).contains(drive) else { return }
        images[drive] = image
    }

    public func unmount(drive: Int) {
        guard (0..<Self.maxDrives).contains(drive) else { return }
        try? images[drive]?.flush()
        images[drive] = nil
    }

    public func image(drive: Int) -> DiskImage? {
        (0..<Self.maxDrives).contains(drive) ? images[drive] : nil
    }

    public func headPosition(drive: Int) -> (track: Int, sector: Int)? {
        (0..<Self.maxDrives).contains(drive) ? (headTrack[drive], sector) : nil
    }

    public func flushAll() {
        for image in images { try? image?.flush() }
    }

    /// 電源投入直後の状態(装着したイメージは保持)
    public func reset() {
        pia1.reset(); pia2.reset()
        drive = 0; sector = 1; trackRegister = 0
        errors = 0; busyUntil = 0; bufferIndex = 0
        for i in headTrack.indices { headTrack[i] = 0 }
    }

    // MARK: ポート A に見える値

    private var command: UInt8 { pia1.outputB }

    private func status() -> UInt8 {
        var s = errors
        if now() < busyUntil { s |= Self.sBusy }
        if images[drive] == nil { s |= Self.sNotReady }
        return s
    }

    /// ポート A(入力)に見える値。論理が反転している。
    private func dataInValue() -> UInt8 {
        if command == Command.readBuffer {
            return ~buffer[min(bufferIndex, buffer.count - 1)]
        }
        return ~status()
    }

    // MARK: ストローブ(実行)

    private func strobe() {
        let cmd = command
        let data = pia2.outputB
        switch cmd {
        case Command.readBuffer:
            bufferIndex += 1                       // 読み出しバッファ: 1 バイト進める
        case Command.writeBuffer:
            if bufferIndex < buffer.count { buffer[bufferIndex] = data }
            bufferIndex += 1                       // 書き込みバッファ: 1 バイト受け取る
        default:
            execute(cmd, data)
        }
    }

    private func busy(microseconds: Int) {
        busyUntil = max(busyUntil, now()) + microseconds * cyclesPerMicrosecond
    }

    private func noteActivity() {
        activityCounter &+= 1
        lastActiveDrive = drive
    }

    private func sectorOffset(_ image: DiskImage) -> Int? {
        let g = image.geometry
        guard (1...g.sectorsPerTrack).contains(sector), headTrack[drive] < g.tracks else { return nil }
        return (headTrack[drive] * g.sectorsPerTrack + (sector - 1)) * g.bytesPerSector
    }

    private func execute(_ cmd: UInt8, _ data: UInt8) {
        onCommand?(cmd, data, drive, headTrack[drive], sector)
        bufferIndex = 0
        switch cmd {
        case Command.reset:
            errors = 0
            busy(microseconds: 5_000)
        case Command.driveSector:
            drive = Int(data >> 6) & 3
            sector = Int(data & 0x3F)
            busy(microseconds: 50)
        case Command.setTrack:
            trackRegister = Int(data)
            busy(microseconds: 50)
        case Command.seek:
            if let image = images[drive] {
                let target = min(trackRegister, image.geometry.tracks - 1)
                busy(microseconds: 6_000 + 1_000 * abs(target - headTrack[drive]))
                headTrack[drive] = target
                noteActivity()
            }
        case Command.restore:
            if images[drive] != nil {
                busy(microseconds: 6_000 + 1_000 * headTrack[drive])
                headTrack[drive] = 0
                noteActivity()
            }
            trackRegister = 0
        case Command.read:
            if let image = images[drive] {
                if let off = sectorOffset(image) {
                    for k in 0..<buffer.count { buffer[k] = image.read(at: off + k) ?? 0 }
                } else {
                    errors |= Self.sCRCError       // 存在しないセクタ
                }
                busy(microseconds: 6_400)
                noteActivity()
            }
        case Command.write:
            if let image = images[drive] {
                if image.writeProtected {
                    errors |= Self.sWriteProtect
                } else if let off = sectorOffset(image) {
                    for k in 0..<buffer.count { image.write(buffer[k], at: off + k) }
                } else {
                    errors |= Self.sCRCError
                }
                busy(microseconds: 6_400)
                noteActivity()
            }
        case Command.readCRC:
            if let image = images[drive] {
                if sectorOffset(image) == nil { errors |= Self.sCRCError }
                busy(microseconds: 6_400)
                noteActivity()
            }
        case Command.clearErrors:
            errors = 0
        default:
            break                                  // ステータス読み出しなど
        }
    }
}
