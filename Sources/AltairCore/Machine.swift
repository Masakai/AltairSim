/// Altair 8800 本体。64KB RAM、8080 CPU、2SIO 相当のシリアルポート(0x10/0x11)、
/// センス' スイッチ入力(ポート 0xFF)を持つ。フロントパネルの操作もここで受ける。
/// 直近のバスサイクルの種別(パネルのステータス LED 用)。
/// WO は実機どおり負論理で、書き込みサイクル以外では点灯する。
public struct CycleStatus: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let memr = CycleStatus(rawValue: 1 << 0)
    public static let inp = CycleStatus(rawValue: 1 << 1)
    public static let m1 = CycleStatus(rawValue: 1 << 2)
    public static let out = CycleStatus(rawValue: 1 << 3)
    public static let hlta = CycleStatus(rawValue: 1 << 4)
    public static let stack = CycleStatus(rawValue: 1 << 5)
    public static let wo = CycleStatus(rawValue: 1 << 6)
}

public final class AltairMachine: Bus {
    /// 2SIO のポート A を 00h/01h に割り当てる構成(8K BASIC ROM が使用)。ステータスの意味は 10h/11h と同じ。
    public static let sio88StatusPort: UInt8 = 0x00
    public static let sio88DataPort: UInt8 = 0x01
    /// 88-2SIO(ポート 10h/11h)
    public static let sioStatusPort: UInt8 = 0x10
    public static let sioDataPort: UInt8 = 0x11
    public static let senseSwitchPort: UInt8 = 0xFF
    /// 2MHz 動作
    public static let clockHz = 2_000_000

    /// アドレスごとの実装状態。RAM は読み書き可、ROM は読み出しのみ、未実装は 0xFF が読める。
    public enum MemoryKind: UInt8 {
        case unmapped, ram, rom
    }

    public private(set) var memory = [UInt8](repeating: 0, count: 65536)
    public private(set) var kinds = [MemoryKind](repeating: .unmapped, count: 65536)
    public private(set) var cpu: CPU!
    public let disks = DiskController()
    public private(set) var ramSize: Int

    /// アドレススイッチ A0-A15
    public var switches: UInt16 = 0
    public private(set) var running = false

    /// 直近のバスアクセス(パネルの LED 表示用)
    public private(set) var lastAddress: UInt16 = 0
    public private(set) var lastData: UInt8 = 0
    public private(set) var status: CycleStatus = [.memr, .wo]

    // シリアル(端末側)
    public var onSerialOutput: ((UInt8) -> Void)?
    private var serialInput: [UInt8] = []

    /// 実行したクロック総数。シリアル送信の所要時間の計算に使う。
    public private(set) var cycleCounter = 0
    private var txBusyUntil = 0
    /// 送信のボーレート。nil なら制限なし(送信は常に即時完了)。
    /// 110 ボーはテレタイプ(Model 33 ASR)の 11 ビット/文字、それ以外は 10 ビット/文字で計算する。
    public var baudRate: Int?
    private var cyclesPerCharacter: Int {
        guard let baud = baudRate, baud > 0 else { return 0 }
        let bits = baud == 110 ? 11 : 10
        return Self.clockHz * bits / baud
    }

    /// ramSize バイトの RAM をアドレス 0 から実装する(既定は 64KB)
    public init(ramSize: Int = 0x10000) {
        self.ramSize = min(ramSize, 0x10000)
        cpu = CPU(bus: self)
        for i in 0..<self.ramSize { kinds[i] = .ram }
    }

    /// RAM の実装量を変える(ROM は維持)。内容を消して電源投入直後の状態にしたいときは clearMemory を使う。
    public func setRAMSize(_ size: Int) {
        ramSize = min(max(size, 0), 0x10000)
        for i in 0..<0x10000 where kinds[i] != .rom {
            kinds[i] = i < ramSize ? .ram : .unmapped
        }
    }

    public func clearMemory() {
        for i in 0..<0x10000 where kinds[i] == .ram { memory[i] = 0 }
    }

    // MARK: Bus

    public func read(_ addr: UInt16) -> UInt8 {
        status = [.memr, .wo]
        return access(addr)
    }

    public func fetchOpcode(_ addr: UInt16) -> UInt8 {
        status = [.memr, .m1, .wo]
        return access(addr)
    }

    public func readStack(_ addr: UInt16) -> UInt8 {
        status = [.memr, .stack, .wo]
        return access(addr)
    }

    public func write(_ addr: UInt16, _ value: UInt8) {
        status = []
        store(addr, value)
    }

    public func writeStack(_ addr: UInt16, _ value: UInt8) {
        status = [.stack]
        store(addr, value)
    }

    private func access(_ addr: UInt16) -> UInt8 {
        let v = kinds[Int(addr)] == .unmapped ? 0xFF : memory[Int(addr)]
        lastAddress = addr
        lastData = v
        return v
    }

    private func store(_ addr: UInt16, _ value: UInt8) {
        if kinds[Int(addr)] == .ram { memory[Int(addr)] = value }
        lastAddress = addr
        lastData = kinds[Int(addr)] == .unmapped ? 0xFF : memory[Int(addr)]
    }

    public func input(_ port: UInt8) -> UInt8 {
        status = [.inp, .wo]
        switch port {
        case Self.sioStatusPort, Self.sio88StatusPort:
            // bit0 = RDRF(受信あり)、bit1 = TDRE(送信可)。送信は常に即時完了。
            let tdre: UInt8 = cycleCounter >= txBusyUntil ? 0x02 : 0
            return tdre | (serialInput.isEmpty ? 0 : 0x01)
        case Self.sioDataPort, Self.sio88DataPort:
            return serialInput.isEmpty ? 0 : serialInput.removeFirst()
        case Self.senseSwitchPort:
            return UInt8(switches >> 8)
        default:
            return disks.read(port: port) ?? 0
        }
    }

    public func output(_ port: UInt8, _ value: UInt8) {
        status = [.out]
        if disks.write(port: port, value: value) { return }
        if port == Self.sioDataPort || port == Self.sio88DataPort {
            onSerialOutput?(value)
            txBusyUntil = cycleCounter + cyclesPerCharacter
        }
    }

    // MARK: シリアル入力

    public func sendSerial(_ byte: UInt8) {
        serialInput.append(byte)
    }

    // MARK: 実行

    /// 指定クロック数ぶん実行する。HLT で停止状態になったら running を落として戻る。
    /// 実際に消費したクロック数を返す(1 命令ぶん超過することがある)。
    @discardableResult
    public func run(cycles budget: Int) -> Int {
        var used = 0
        while running && used < budget {
            let c = cpu.step()
            used += c
            cycleCounter += c
            if cpu.halted {
                // HLT 後は実機と同じく RUN のまま(HLTA が点灯し、WAIT は消灯)。クロックは消費しない。
                status = [.hlta, .memr, .wo]
                break
            }
        }
        return used
    }

    // MARK: フロントパネル操作

    public func runStop() {
        if running { stop() } else { start() }
    }

    public func stop() {
        guard running else { return }
        running = false
        status = [.memr, .wo]
        showCurrent()
    }

    public func start() {
        guard !running else { return }
        cpu.halted = false
        running = true
    }

    /// EXT CLR: 外部デバイス(シリアル受信バッファ)をクリア
    public func extClear() {
        serialInput.removeAll()
    }

    public func singleStep() {
        guard !running else { return }
        cpu.halted = false
        cycleCounter += cpu.step()
        if cpu.halted {
            cpu.halted = false
            status = [.hlta, .memr, .wo]
        }
        lastAddress = cpu.pc
        lastData = peek(cpu.pc)
    }

    public func examine() {
        guard !running else { return }
        cpu.pc = switches
        showCurrent()
    }

    public func examineNext() {
        guard !running else { return }
        cpu.pc &+= 1
        showCurrent()
    }

    public func deposit() {
        guard !running else { return }
        store(cpu.pc, UInt8(switches & 0xFF))
        showCurrent()
    }

    public func depositNext() {
        guard !running else { return }
        cpu.pc &+= 1
        store(cpu.pc, UInt8(switches & 0xFF))
        showCurrent()
    }

    /// RESET: PC を 0 に戻す(メモリは保持)
    public func reset() {
        running = false
        cpu.reset()
        showCurrent()
    }

    private func showCurrent() {
        if !running { status = [.memr, .wo] }
        lastAddress = cpu.pc
        lastData = peek(cpu.pc)
    }

    // MARK: ローダー

    /// 副作用なしでメモリを読む(パネル表示用)
    public func peek(_ addr: UInt16) -> UInt8 {
        kinds[Int(addr)] == .unmapped ? 0xFF : memory[Int(addr)]
    }

    /// RAM 上にプログラムを置く(RAM でないアドレスは無視)
    public func load(_ bytes: [UInt8], at address: UInt16) {
        for (i, b) in bytes.enumerated() {
            let a = (Int(address) + i) & 0xFFFF
            if kinds[a] == .ram { memory[a] = b }
        }
        showCurrent()
    }

    /// ROM としてバイト列を実装する(書き込み不可)
    public func loadROM(_ bytes: [UInt8], at address: UInt16) {
        for (i, b) in bytes.enumerated() {
            let a = (Int(address) + i) & 0xFFFF
            memory[a] = b
            kinds[a] = .rom
        }
        showCurrent()
    }

    /// ROM をすべて外す(RAM の内容は保持)
    public func removeROMs() {
        for i in 0..<0x10000 where kinds[i] == .rom {
            kinds[i] = i < ramSize ? .ram : .unmapped
            memory[i] = 0
        }
    }
}
