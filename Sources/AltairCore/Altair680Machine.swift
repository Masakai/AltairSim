/// Altair 680b: Motorola 6800、6850 ACIA(端末)、PROM モニタ(FF00〜FFFF)、フロントパネル。
///
/// メモリマップ(680b の System Monitor Manual、MON680.ASM による)
/// - 0000〜: RAM(標準 1KB。ここでは `ramSize` で指定。ジャンパで開始番地を変える構成は再現しない)
/// - F000: ACIA 制御/状態、F001: ACIA データ、F002: ストラップ(bit7 = 1 で「端末なし」)
/// - FF00〜FFFF: PROM モニタ(ベクタは FFF8〜FFFF)
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
    }

    // MARK: Bus

    public func read(_ addr: UInt16) -> UInt8 {
        let v = peekBus(addr, side: true)
        lastAddress = addr
        lastData = v
        return v
    }

    public func write(_ addr: UInt16, _ value: UInt8) {
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
            if Int(rec.address) >= Self.romStart {
                loadROM(rec.bytes, at: rec.address)
            } else {
                load(rec.bytes, at: rec.address)
            }
            count += rec.bytes.count
        }
        return count
    }

    public func clearMemory() {
        for i in 0..<0x10000 where kinds[i] == .ram { memory[i] = 0 }
    }
}
