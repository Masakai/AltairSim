/// Altair 680b: Motorola 6800、6850 ACIA(端末)、PROM モニタ(FF00〜FFFF)、フロントパネル。
///
/// メモリマップ(680b の System Monitor Manual、MON680.ASM による)
/// - 0000〜: RAM(標準 1KB。ここでは `ramSize` で指定。ジャンパで開始番地を変える構成は再現しない)
/// - F000: ACIA 制御/状態、F001: ACIA データ、F002: ストラップ(bit7 = 1 で「端末なし」)
/// - FF00〜FFFF: PROM モニタ(ベクタは FFF8〜FFFF)
/// - 68-UIO ボード(`uioInstalled` が true のとき。PIA のレジスタ選択は、アドレスの最下位ビットが反転した配線で、
///   偶数番地 = 制御レジスタ、奇数番地 = データ/方向レジスタ。F008 が制御 A、F009 がデータ A、F00A が制御 B、F00B がデータ B): F006/F007 に 2 つ目の ACIA、F008〜F00B に PIA #1、F00C〜F00F に PIA #2。
///   PIA に FD3712 ディスクコントローラがつながる(`disks`)。FLEX や CP/68 の起動 PROM は FC00 に置く
///
/// フロントパネル(680b の Operators Manual による)
/// - HALT 中は、アドレススイッチが示す番地をアドレス LED に、その中身をデータ LED に出す
/// - DEPOSIT でデータスイッチの値をその番地に書く。EXAMINE スイッチはない
/// - RUN 中は CPU のバスの値を LED に出す(実機がこう表示するかは未確認)
public final class Altair680Machine: Bus {
    /// CPU クロック 500kHz(1 クロック = 2 マイクロ秒)。
    /// 680b Theory of Operation: 2MHz の水晶を 4 分周して 500kHz。Phase 1 は 600ns High / 1.4µs Low、
    /// Phase 2 は 1µs High / 1µs Low。データ転送は Phase 2 で行う。
    /// ボーレート用の水晶(2.4576MHz)は CPU のクロックとは別。
    public static let clockHz = 500_000
    public static let aciaControl: UInt16 = 0xF000
    public static let aciaData: UInt16 = 0xF001
    public static let straps: UInt16 = 0xF002
    public static let romStart = 0xFF00

    public enum MemoryKind: UInt8 { case unmapped, ram, rom }

    public private(set) var memory = [UInt8](repeating: 0, count: 65536)
    public private(set) var kinds = [MemoryKind](repeating: .unmapped, count: 65536)
    public private(set) var cpu: CPU6800!
    public private(set) var ramSize: Int

    // フロントパネル
    public var addressSwitches: UInt16 = 0
    public var dataSwitches: UInt8 = 0
    /// RUN(true)/ HALT(false)
    public private(set) var running = false
    /// 「端末なし」ストラップ。true だとモニタはリセット後に 0000 番地へ飛ぶ(フロントパネルだけで使う構成)
    public var noTerminal = false
    public private(set) var lastAddress: UInt16 = 0
    public private(set) var lastData: UInt8 = 0

    // シリアル(ACIA)
    public var onSerialOutput: ((UInt8) -> Void)?
    private var serialInput: [UInt8] = []
    private var aciaControlRegister: UInt8 = 0
    public private(set) var cycleCounter = 0
    private var txBusyUntil = 0

    /// 68-UIO ボード(2 つ目の ACIA と 2 つの PIA)が差さっているか
    public var uioInstalled = false
    /// 68-UIO の PIA 経由でつながる FD3712 ディスクコントローラ(ドライブ 4 台まで)
    public private(set) var disks: FD3712Controller!
    /// 送信のボーレート。nil なら制限なし
    public var baudRate: Int?
    private var cyclesPerCharacter: Int {
        guard let baud = baudRate, baud > 0 else { return 0 }
        let bits = baud == 110 ? 11 : 10
        return Self.clockHz * bits / baud
    }

    public init(ramSize: Int = 0x2000) {
        self.ramSize = min(max(ramSize, 0x0100), 0xF000)
        cpu = CPU6800(bus: self)
        for i in 0..<self.ramSize { kinds[i] = .ram }
        disks = FD3712Controller(clockHz: Self.clockHz, now: { [unowned self] in self.cycleCounter })
    }

    /// RAM の実装量を変える(ROM は維持)。内容は消さない。
    public func setRAMSize(_ size: Int) {
        ramSize = min(max(size, 0x0100), 0xF000)
        for i in 0..<0x10000 where kinds[i] != .rom {
            kinds[i] = i < ramSize ? .ram : .unmapped
        }
    }

    // MARK: Bus

    public func read(_ addr: UInt16) -> UInt8 {
        let v = peekBus(addr, side: true)
        lastAddress = addr
        lastData = v
        return v
    }

    public func write(_ addr: UInt16, _ value: UInt8) {
        if uioInstalled, (0xF006...0xF00F).contains(addr) {
            switch addr {
            case 0xF008...0xF00B: disks.pia1.write(Int(addr - 0xF008) ^ 1, value)
            case 0xF00C...0xF00F: disks.pia2.write(Int(addr - 0xF00C) ^ 1, value)
            default: break                           // UIO の ACIA(端末はつながっていない)
            }
            lastAddress = addr
            lastData = value
            return
        }
        switch addr {
        case Self.aciaControl:
            aciaControlRegister = value
            if value & 0x03 == 0x03 { txBusyUntil = 0 }  // マスタリセット
        case Self.aciaData:
            onSerialOutput?(value)
            txBusyUntil = cycleCounter + cyclesPerCharacter
        default:
            if kinds[Int(addr)] == .ram { memory[Int(addr)] = value }
        }
        lastAddress = addr
        lastData = value
    }

    public func input(_ port: UInt8) -> UInt8 { 0xFF }
    public func output(_ port: UInt8, _ value: UInt8) {}

    /// side = true のときは、データレジスタの読み出しで受信バッファを消費する
    private func peekBus(_ addr: UInt16, side: Bool) -> UInt8 {
        if uioInstalled, (0xF006...0xF00F).contains(addr) {
            switch addr {
            case 0xF006: return 0x02                  // UIO の ACIA: 送信可、受信なし
            case 0xF007: return 0
            case 0xF008...0xF00B:
                // 副作用(ハンドシェイクのストローブ)があるので、パネル表示用の覗き見では PIA に触らない
                return side ? disks.pia1.read(Int(addr - 0xF008) ^ 1) : 0xFF
            case 0xF00C...0xF00F:
                return side ? disks.pia2.read(Int(addr - 0xF00C) ^ 1) : 0xFF
            default: return 0xFF
            }
        }
        switch addr {
        case Self.aciaControl:
            let tdre: UInt8 = cycleCounter >= txBusyUntil ? 0x02 : 0
            return tdre | (serialInput.isEmpty ? 0 : 0x01)
        case Self.aciaData:
            if serialInput.isEmpty { return 0 }
            return side ? serialInput.removeFirst() : serialInput[0]
        case Self.straps:
            return noTerminal ? 0x80 : 0x00
        default:
            return kinds[Int(addr)] == .unmapped ? 0xFF : memory[Int(addr)]
        }
    }

    /// 副作用なしでメモリを見る(パネル表示用)
    public func peek(_ addr: UInt16) -> UInt8 { peekBus(addr, side: false) }

    // MARK: シリアル入力

    public func sendSerial(_ byte: UInt8) { serialInput.append(byte) }
    public var pendingSerialInput: Int { serialInput.count }

    // MARK: 実行

    /// RUN 中だけ、指定クロック数ぶん実行する。実際に消費したクロック数を返す。
    @discardableResult
    public func run(cycles budget: Int) -> Int {
        var used = 0
        while running && used < budget {
            let c = cpu.step()
            used += c
            cycleCounter += c
        }
        return used
    }

    // MARK: フロントパネル

    /// アドレス LED(HALT 中はアドレススイッチ、RUN 中は CPU のバス)
    public var addressLEDs: UInt16 { running ? lastAddress : addressSwitches }
    /// データ LED(HALT 中はアドレススイッチの番地の中身、RUN 中は CPU のバス)
    public var dataLEDs: UInt8 { running ? lastData : peek(addressSwitches) }

    public func setRunning(_ run: Bool) {
        if run == running { return }
        running = run
    }

    /// RESET: CPU とシリアルを初期状態に戻し、PC をリセットベクタから読む
    public func reset() {
        disks.reset()
        cpu.reset()
        aciaControlRegister = 0
        serialInput.removeAll()
        txBusyUntil = 0
    }

    /// DEPOSIT: HALT 中にデータスイッチの値をアドレススイッチの番地へ書く(RAM のみ)
    public func deposit() {
        guard !running, kinds[Int(addressSwitches)] == .ram else { return }
        memory[Int(addressSwitches)] = dataSwitches
    }

    // MARK: ローダー

    public func load(_ bytes: [UInt8], at address: UInt16) {
        for (i, b) in bytes.enumerated() {
            let a = (Int(address) + i) & 0xFFFF
            if kinds[a] == .ram { memory[a] = b }
        }
    }

    public func loadROM(_ bytes: [UInt8], at address: UInt16) {
        for (i, b) in bytes.enumerated() {
            let a = (Int(address) + i) & 0xFFFF
            memory[a] = b
            kinds[a] = .rom
        }
    }

    /// S レコードを ROM(FF00 以上)または RAM に置く。置いたバイト数を返す。
    @discardableResult
    public func loadS19(_ text: String) throws -> Int {
        var count = 0
        for rec in try S19Loader.parse(text) {
            if Int(rec.address) >= 0xF000 {          // F000 以上は ROM(起動 PROM は FC00、モニタは FF00)
                loadROM(rec.bytes, at: rec.address)
            } else {
                load(rec.bytes, at: rec.address)
            }
            count += rec.bytes.count
        }
        return count
    }

    /// ROM をすべて外す(RAM の内容は保持)
    public func removeROMs() {
        for i in 0..<0x10000 where kinds[i] == .rom {
            kinds[i] = i < ramSize ? .ram : .unmapped
            memory[i] = 0
        }
    }

    public func clearMemory() {
        for i in 0..<0x10000 where kinds[i] == .ram { memory[i] = 0 }
    }
}
