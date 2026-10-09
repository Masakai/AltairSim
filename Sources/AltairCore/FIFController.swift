import Foundation

/// IMSAI のフロッピーインタフェース(FIF)。IFM と FIB の 2 枚組で、ボード上の 8080 が PROM のファームウェア(fifware.asm)を実行して、
/// ホスト(IMSAI 8080 本体)のメモリ上の「コマンド列」を読み、ディスクの読み書きをして、結果をメモリ上のステータスバイトに書き戻す。
///
/// ホストから見た口は、ポート 0FDH への書き込みだけ(ファームウェアの ACTN と、IMSAI CP/M の BIOS・ブートによる):
/// - 上位ニブル 0: コマンド列を実行する。下位ニブルが「ポインタ番号」で、ポインタはコマンド列のアドレス(16 本、既定は 0080、1000、2000、…)
/// - 上位ニブル 1: ポインタを設定する。下位ニブルがポインタ番号で、続けて同じポートへ、アドレスの下位バイト、上位バイトの順に書く
/// - 上位ニブル 2: ドライブをトラック 0 へ戻す(下位ニブルがドライブのビットマスク。2F は全ドライブ)
/// - 上位ニブル 3: 指定ドライブをソフトウェアの書き込み禁止にする。4: 書き込み禁止を解除する
///
/// コマンド列(メモリ上の 7 バイト): [0] コマンド(下位ニブル = ドライブのビット(1、2、4、8)、上位ニブル = 機能)、
/// [1] ステータス(実行前に 0 にしておく。終わると結果が入る)、[2] トラックの上位(0)、[3] トラック(0〜76)、[4] セクタ(1〜26)、[5][6] バッファのアドレス
/// 機能: 1 = 書き込み、2 = 読み出し、3 = トラックのフォーマット(セクタとバッファは不要)、4 = 読み出して確認だけ、5 = 削除データの書き込み
/// 結果: 01 = 成功、A1 = ドライブが準備できていない、A2 = 書き込み禁止(ハード)、A3 = 書き込み禁止(ソフト)、C1〜C6 = コマンド列の誤り、
/// 93 = セクタが見つからない(未フォーマットなど)
///
/// この実装は、ファームウェアの 8080 を動かさず、ホストから見える動作(コマンド列とステータス、データの転送、所要時間の近似)を再現する。
public final class FIFController: DiskSubsystem {
    public static let port: UInt8 = 0xFD
    public static let maxDrives = 4
    public static let sectorsPerTrack = DiskImage.Geometry.ibm3740.sectorsPerTrack
    public static let bytesPerSector = DiskImage.Geometry.ibm3740.bytesPerSector

    /// ファームウェアの既定のポインタ(DEFP)
    static let defaultPointers: [UInt16] = [0x0080] + (1..<16).map { UInt16($0) << 12 }

    private var images = [DiskImage?](repeating: nil, count: FIFController.maxDrives)
    private var headTrack = [Int](repeating: 0, count: FIFController.maxDrives)
    private var softwareProtect = [Bool](repeating: false, count: FIFController.maxDrives)
    private var pointers = FIFController.defaultPointers

    /// ポインタ設定の途中経過(次に来る 2 バイトの受け取り)
    private var settingPointer: Int?
    private var pointerLow: UInt8?

    /// ホストのメモリへの口(マシンが設定する)
    public var readMemory: ((UInt16) -> UInt8)?
    public var writeMemory: ((UInt16, UInt8) -> Void)?
    /// 現在のクロック(マシンの経過サイクル)
    private let now: () -> Int
    private let cyclesPerMicrosecond: Int

    /// 実行中のコマンド。終了時刻になると結果をステータスバイトへ書く
    private struct Pending {
        var finishAt: Int
        var statusAddress: UInt16
        var status: UInt8
    }
    private var pending: Pending?

    public private(set) var activityCounter = 0
    public private(set) var lastActiveDrive: Int?

    /// 実行したコマンドを通知する(デバッグ用): (コマンド列のアドレス, コマンド, トラック, セクタ, 結果)
    public var onCommand: ((UInt16, UInt8, Int, Int, UInt8) -> Void)?

    public init(clockHz: Int, now: @escaping () -> Int) {
        self.now = now
        self.cyclesPerMicrosecond = max(clockHz / 1_000_000, 1)
    }

    // MARK: DiskSubsystem

    public func mount(_ image: DiskImage, drive: Int) {
        guard (0..<Self.maxDrives).contains(drive) else { return }
        images[drive] = image
        headTrack[drive] = 0
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
        (0..<Self.maxDrives).contains(drive) ? (headTrack[drive], 0) : nil
    }

    public func flushAll() {
        for image in images { try? image?.flush() }
    }

    /// 電源投入直後の状態(装着したイメージは保持)
    public func reset() {
        pointers = Self.defaultPointers
        settingPointer = nil
        pointerLow = nil
        pending = nil
        softwareProtect = [Bool](repeating: false, count: Self.maxDrives)
        for i in headTrack.indices { headTrack[i] = 0 }
    }

    /// 実行中のコマンドがあるか(マシンの実行ループが、時刻の確認を省くための目印)
    public var isBusy: Bool { pending != nil }

    // MARK: ホストからの書き込み(OUT 0FDH)

    public func write(_ value: UInt8) {
        if let n = settingPointer {
            if let low = pointerLow {
                pointers[n] = UInt16(value) << 8 | UInt16(low)
                settingPointer = nil
                pointerLow = nil
            } else {
                pointerLow = value
            }
            return
        }
        let n = Int(value & 0x0F)
        switch value >> 4 {
        case 0: execute(pointer: n)
        case 1: settingPointer = n; pointerLow = nil
        case 2:
            for d in 0..<Self.maxDrives where value & (1 << UInt8(d)) != 0 { headTrack[d] = 0 }
        case 3:
            for d in 0..<Self.maxDrives where value & (1 << UInt8(d)) != 0 { softwareProtect[d] = true }
        case 4:
            for d in 0..<Self.maxDrives where value & (1 << UInt8(d)) != 0 { softwareProtect[d] = false }
        default: break
        }
    }

    // MARK: 時間の経過

    /// 実行中のコマンドが終わる時刻なら、結果をホストのメモリへ書く
    public func service() {
        guard let p = pending, now() >= p.finishAt else { return }
        pending = nil
        writeMemory?(p.statusAddress, p.status)
    }

    // MARK: コマンド列の実行

    private func milliseconds(_ ms: Double) -> Int { Int(ms * 1000) * cyclesPerMicrosecond }

    private func execute(pointer: Int) {
        let base = pointers[pointer]
        guard let readMemory, let writeMemory else { return }
        let statusAddress = base &+ 1
        func byte(_ i: UInt16) -> UInt8 { readMemory(base &+ i) }
        func finish(_ status: UInt8, after ms: Double) {
            pending = Pending(finishAt: now() + milliseconds(ms), statusAddress: statusAddress, status: status)
            onCommand?(base, byte(0), Int(byte(3)), Int(byte(4)), status)
        }

        let command = byte(0)
        // ファームウェアの ACT1 の検査の順序と、エラーコード(C1 から、AERX の前の INR C の数だけ加算)に合わせる
        guard byte(1) == 0 else { return finish(0xC1, after: 1) }           // ステータスバイトが 0 でない
        guard byte(2) == 0 else { return finish(0xC5, after: 1) }           // トラックの上位バイトが 0 でない
        let driveBits = command & 0x0F
        guard driveBits != 0 else { return finish(0xC2, after: 1) }         // ドライブが選ばれていない
        guard driveBits.nonzeroBitCount == 1 else { return finish(0xC3, after: 1) }   // 複数のドライブ
        let drive = Int(driveBits.trailingZeroBitCount)
        let track = Int(byte(3))
        guard track < 77 else { return finish(0xC5, after: 1) }
        let function = command >> 4
        guard (1...5).contains(function) else { return finish(0xC4, after: 1) }       // 未対応・不正な機能
        var sector = 0
        if function != 3 {
            sector = Int(byte(4))
            guard (1...Self.sectorsPerTrack).contains(sector) else { return finish(0xC6, after: 1) }
        }
        let buffer = UInt16(byte(5)) | UInt16(byte(6)) << 8

        guard let image = images[drive] else { return finish(0xA1, after: 1) }        // ドライブが準備できていない
        if function == 1 || function == 3 || function == 5 {
            if image.writeProtected { return finish(0xA2, after: 1) }                 // 書き込み禁止(ハード)
            if softwareProtect[drive] { return finish(0xA3, after: 1) }               // 書き込み禁止(ソフト)
        }

        // ヘッドの移動(1 トラックあたり 6ms)とヘッドロードの待ち(10ms)
        let seekMs = Double(abs(track - headTrack[drive])) * 6.0 + 10.0
        headTrack[drive] = track
        lastActiveDrive = drive
        activityCounter &+= 1

        let g = image.geometry
        func offset(_ s: Int) -> Int { (track * g.sectorsPerTrack + (s - 1)) * g.bytesPerSector }
        // 回転待ち(平均)とセクタの転送の近似
        let transferMs = 30.0

        switch function {
        case 2, 4:   // 読み出し、確認
            guard image.isFormatted(track: track, sector: sector - 1) else {
                // セクタが見つからず、ファームウェアは 10 回やり直してから 93 を返す
                return finish(0x93, after: seekMs + 1000)
            }
            if function == 2 {
                let off = offset(sector)
                for k in 0..<g.bytesPerSector { writeMemory(buffer &+ UInt16(k), image.read(at: off + k) ?? 0) }
            }
            finish(0x01, after: seekMs + transferMs)
        case 1:      // 書き込み
            let off = offset(sector)
            for k in 0..<g.bytesPerSector { image.write(readMemory(buffer &+ UInt16(k)), at: off + k) }
            image.markFormatted(track: track, sector: sector - 1)
            finish(0x01, after: seekMs + transferMs)
        case 3:      // トラックのフォーマット(データはすべて 0)
            for s in 1...g.sectorsPerTrack {
                let off = offset(s)
                for k in 0..<g.bytesPerSector { image.write(0, at: off + k) }
                image.markFormatted(track: track, sector: s - 1)
            }
            finish(0x01, after: seekMs + 170)   // 1 回転ぶん
        default:     // 5: 削除データの書き込み(内容は変えない)
            finish(0x01, after: seekMs + transferMs)
        }
        _ = writeMemory
    }
}
