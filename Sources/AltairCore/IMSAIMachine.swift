import Foundation

/// インテル 8251 相当の USART(IMSAI SIO-2 の 1 チャンネル)。端末の 1 本ぶんの送受信だけを再現する。
/// 制御ポートの書き込みは、リセット直後は「モード命令」、その次からは「コマンド命令」(コマンドの bit6 = 内部リセット)。
struct USART8251 {
    var expectingMode = true
    var mode: UInt8 = 0
    var command: UInt8 = 0

    mutating func writeControl(_ v: UInt8) {
        if expectingMode {
            mode = v
            expectingMode = false
        } else {
            command = v
            if v & 0x40 != 0 { expectingMode = true }   // 内部リセット。次の書き込みはモード命令
        }
    }
}

/// IMSAI 8080 本体。8080、64KB までの RAM、CP-A フロントパネル、SIO-2(2 チャンネルのシリアル)、
/// FIF フロッピーインタフェース、ポート FFh のプログラム出力 LED とセンススイッチ(上位アドレススイッチ)を持つ。
///
/// I/O ポート(IMSAI CP/M の BIOS・ブートのソースと、CP-A のマニュアルによる):
/// - 02/03: SIO-2 チャンネル A(データ/ステータス・制御)。IMSAI CP/M の TTY
/// - 04/05: SIO-2 チャンネル B。同じく CRT
/// - 08: SIO-2 の割り込み制御(書き込みは無視)
/// - F6: ラインプリンタ(書き込みは無視)、F7: PIC-8(割り込み制御、書き込みは無視)
/// - FD: FIF フロッピー
/// - FF: 入力 = 上位アドレススイッチ(A8〜A15)、出力 = プログラム出力 LED(反転して表示)
public final class IMSAIMachine: Bus {
    public static let channelAData: UInt8 = 0x02
    public static let channelAStatus: UInt8 = 0x03
    public static let channelBData: UInt8 = 0x04
    public static let channelBStatus: UInt8 = 0x05
    public static let panelPort: UInt8 = 0xFF
    /// 2MHz 動作
    public static let clockHz = 2_000_000

    public enum MemoryKind: UInt8 { case unmapped, ram, rom }

    public private(set) var memory = [UInt8](repeating: 0, count: 65536)
    public private(set) var kinds = [MemoryKind](repeating: .unmapped, count: 65536)
    public private(set) var cpu: CPU!
    public private(set) var ramSize: Int
    public private(set) var disks: FIFController!

    /// アドレススイッチ A0-A15。A8〜A15 はポート FF の入力にもなり、A0〜A7 は DEPOSIT のデータにもなる
    public var switches: UInt16 = 0
    public private(set) var running = false

    /// プログラム出力 LED(ポート FF に最後に書いた値。LED は反転して点灯する)
    public private(set) var programmedOutput: UInt8 = 0xFF

    /// FIF が起動時に起動セクタを読み込んで実行する(電源投入・RESET のとき、ドライブ 0 にディスクがあれば)
    public var fifBootEnabled = true

    public private(set) var lastAddress: UInt16 = 0
    public private(set) var lastData: UInt8 = 0
    public private(set) var status: CycleStatus = [.memr, .wo]

    public var onSerialOutput: ((UInt8) -> Void)?
    private var serialInput: [UInt8] = []
    private var usartA = USART8251()
    private var usartB = USART8251()

    public private(set) var cycleCounter = 0
    private var txBusyUntil = 0
    public var baudRate: Int?
    private var cyclesPerCharacter: Int {
        guard let baud = baudRate, baud > 0 else { return 0 }
        let bits = baud == 110 ? 11 : 10
        return Self.clockHz * bits / baud
    }

    public init(ramSize: Int = 0x10000) {
        self.ramSize = min(ramSize, 0x10000)
        cpu = CPU(bus: self)
        for i in 0..<self.ramSize { kinds[i] = .ram }
        disks = FIFController(clockHz: Self.clockHz, now: { [unowned self] in self.cycleCounter })
        disks.readMemory = { [unowned self] a in self.peek(a) }
        disks.writeMemory = { [unowned self] a, v in self.poke(a, v) }
    }

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

    /// FIF など、CPU を介さずにメモリへ書く(パネルの LED は動かさない)
    private func poke(_ addr: UInt16, _ value: UInt8) {
        if kinds[Int(addr)] == .ram { memory[Int(addr)] = value }
    }

    /// SIO-2 のステータス(8251 と同じ並び): bit0 = 送信可、bit1 = 受信あり、bit2 = 送信完了
    private func serialStatus() -> UInt8 {
        let txReady: UInt8 = cycleCounter >= txBusyUntil ? 0x05 : 0
        return txReady | (serialInput.isEmpty ? 0 : 0x02)
    }

    public func input(_ port: UInt8) -> UInt8 {
        status = [.inp, .wo]
        switch port {
        case Self.channelAStatus, Self.channelBStatus:
            return serialStatus()
        case Self.channelAData, Self.channelBData:
            return serialInput.isEmpty ? 0 : serialInput.removeFirst()
        case Self.panelPort:
            return UInt8(switches >> 8)
        default:
            return 0xFF
        }
    }

    public func output(_ port: UInt8, _ value: UInt8) {
        status = [.out]
        switch port {
        case Self.channelAData, Self.channelBData:
            onSerialOutput?(value)
            txBusyUntil = cycleCounter + cyclesPerCharacter
        case Self.channelAStatus: usartA.writeControl(value)
        case Self.channelBStatus: usartB.writeControl(value)
        case Self.panelPort: programmedOutput = value
        case FIFController.port: disks.write(value)
        default: break
        }
    }

    // MARK: シリアル入力

    public func sendSerial(_ byte: UInt8) { serialInput.append(byte) }

    // MARK: 実行

    /// 指定クロック数ぶん実行する。実際に消費したクロック数を返す。
    @discardableResult
    public func run(cycles budget: Int) -> Int {
        var used = 0
        while running && used < budget {
            if cpu.halted {
                let idle = budget - used
                used += idle
                cycleCounter += idle
                disks.service()
                showHalt()
                break
            }
            let c = cpu.step()
            used += c
            cycleCounter += c
            if disks.isBusy { disks.service() }
            if cpu.halted { showHalt() }
        }
        return used
    }

    private func showHalt() {
        status = [.hlta, .memr, .wo]
        lastAddress = cpu.pc
    }

    @discardableResult
    public func requestInterrupt(opcode: UInt8) -> Bool { cpu.interrupt(opcode: opcode) }

    // MARK: フロントパネル操作

    public func runStop() { if running { stop() } else { start() } }

    public func stop() {
        guard running else { return }
        running = false
        showCurrent()
    }

    public func start() {
        guard !running else { return }
        running = true
    }

    /// EXT CLR: 外部デバイスのクリア(シリアルの受信バッファ、SIO-2 の状態)
    public func extClear() {
        serialInput.removeAll()
        usartA = USART8251()
        usartB = USART8251()
    }

    public func singleStep() {
        guard !running else { return }
        if cpu.halted { showHalt(); return }
        cycleCounter += cpu.step()
        if disks.isBusy { disks.service() }
        if cpu.halted {
            showHalt()
        } else {
            lastAddress = cpu.pc
            lastData = peek(cpu.pc)
        }
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

    /// DEPOSIT: 現在の番地にデータスイッチ(A0〜A7)の値を書く
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

    /// RESET: PC を 0 に戻す(メモリは保持)。FIF の起動が有効で、ドライブ 0 にディスクがあれば、FIF が起動セクタを読んで実行する
    public func reset() {
        running = false
        cpu.reset()
        disks.reset()
        usartA = USART8251()
        usartB = USART8251()
        if fifBootEnabled, disks.image(drive: 0) != nil { installFIFBoot() }
        showCurrent()
    }

    /// FIF のブート。ファームウェアは、電源投入・RESET のとき、ドライブ 0 が準備できていれば、
    /// 起動用のコードをメモリの 0 番地(JMP)と 0080 番地(コマンド列とポーリングのループ)へ書き込んでから、CPU に 0 番地を実行させる
    /// (fifware.asm の先頭と SYSCM・START)。起動セクタ(トラック 0 のセクタ 1)を 0 番地へ読み込み、読めたら 0 番地へ飛ぶ。
    private func installFIFBoot() {
        let stub: [UInt8] = [
            0x21, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,          // 0080: コマンド列(読み出し、ドライブ 0、トラック 0、セクタ 1、バッファ 0000)
            0x97,                                              // 0087: SUB A
            0x32, 0x81, 0x00,                                  //       STA 0081(ステータスを 0 に)
            0xD3, 0xFD,                                        //       OUT FD(ポインタ 0 を実行)
            0x3A, 0x81, 0x00,                                  // 008D: LDA 0081
            0xB7,                                              //       ORA A
            0xCA, 0x8D, 0x00,                                  //       JZ 008D(ステータスが変わるまで待つ)
            0xFE, 0x01,                                        //       CPI 1
            0xCA, 0x00, 0x00,                                  //       JZ 0000(成功なら、読み込んだ起動セクタへ)
            0x2F,                                              //       CMA
            0xD3, 0xFF,                                        //       OUT FF(エラーコードをプログラム出力 LED へ)
            0xC3, 0x87, 0x00,                                  //       JMP 0087(やり直し)
        ]
        let jump: [UInt8] = [0xC3, 0x87, 0x00]
        for (i, b) in jump.enumerated() { poke(UInt16(i), b) }
        for (i, b) in stub.enumerated() { poke(UInt16(0x80 + i), b) }
    }

    private func showCurrent() {
        if cpu.halted {
            status = [.hlta, .memr, .wo]
        } else if !running {
            status = [.memr, .wo]
        }
        lastAddress = cpu.pc
        lastData = peek(cpu.pc)
    }

    // MARK: ローダー

    public func peek(_ addr: UInt16) -> UInt8 {
        kinds[Int(addr)] == .unmapped ? 0xFF : memory[Int(addr)]
    }

    public func load(_ bytes: [UInt8], at address: UInt16) {
        for (i, b) in bytes.enumerated() {
            let a = (Int(address) + i) & 0xFFFF
            if kinds[a] == .ram { memory[a] = b }
        }
        showCurrent()
    }

    public func loadROM(_ bytes: [UInt8], at address: UInt16) {
        for (i, b) in bytes.enumerated() {
            let a = (Int(address) + i) & 0xFFFF
            memory[a] = b
            kinds[a] = .rom
        }
        showCurrent()
    }

    public func removeROMs() {
        for i in 0..<0x10000 where kinds[i] == .rom {
            kinds[i] = i < ramSize ? .ram : .unmapped
            memory[i] = 0
        }
    }
}
