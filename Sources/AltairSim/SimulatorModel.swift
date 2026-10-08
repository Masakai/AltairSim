import AltairCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SimulatorModel: ObservableObject {
    @Published var addressLED: UInt16 = 0
    @Published var dataLED: UInt8 = 0
    @Published var running = false
    @Published var powered = true
    @Published var status: CycleStatus = [.memr, .wo]
    @Published var inte = false
    @Published var switches: UInt16 = 0 {
        didSet { machine.switches = switches }
    }
    @Published var terminalText = ""
    @Published var uppercaseInput = true

    /// 削除キー(Mac の delete)が端末へ送るコード。プログラムごとに期待するコードが違う。
    enum DeleteKey: String, CaseIterable, Identifiable {
        case backspace = "BS(^H)"
        case rubout = "DEL(7F)"
        case underscore = "_(Altair BASIC)"
        var id: String { rawValue }
        var code: UInt8 {
            switch self {
            case .backspace: return 0x08
            case .rubout: return 0x7F
            case .underscore: return 0x5F
            }
        }
    }
    @Published var deleteKey: DeleteKey = .backspace
    @Published var statusMessage = ""
    /// 端末のキーボード飾りで光らせているキー(ラベル)
    /// ディスクドライブ A・B の表示用状態
    struct DriveInfo: Equatable {
        var loaded = false
        var name = ""
        var track = 0
        var busy = false
    }
    static let visibleDrives = 4
    @Published var drives = [DriveInfo](repeating: DriveInfo(), count: SimulatorModel.visibleDrives)
    private var driveBusyUntil = [TimeInterval](repeating: 0, count: SimulatorModel.visibleDrives)
    private var lastDiskActivity = 0

    @Published var litKeys: Set<String> = []
    private var litGeneration: [String: Int] = [:]

    /// 実機の構成に合わせて RAM は 32KB。E000h 以降は ROM 用に空ける。
    let machine = AltairMachine(ramSize: 0x8000)
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var cycleDebt = 0.0

    enum CPUSpeed: String, CaseIterable, Identifiable {
        case realTime = "2MHz(実機)"
        case fast = "最速"
        var id: String { rawValue }
    }

    /// シリアル送信速度。nil は制限なし。
    struct Baud: Hashable, Identifiable {
        let rate: Int?
        let label: String
        var id: String { label }
        static let all = [
            Baud(rate: nil, label: "制限なし"),
            Baud(rate: 9600, label: "9600 ボー"),
            Baud(rate: 1200, label: "1200 ボー"),
            Baud(rate: 300, label: "300 ボー"),
            Baud(rate: 110, label: "110 ボー(テレタイプ)"),
        ]
    }

    @Published var cpuSpeed: CPUSpeed = .realTime
    @Published var baud: Baud = Baud.all[0] {
        didSet { machine.baudRate = baud.rate }
    }
    private static let ticksPerSecond = 60

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushDisks() }
        }
        // 起動直後に電源だけ入って何も動かない状態だと故障に見えるので、CP/M 2.2 を自動で起動する
        DispatchQueue.main.async { [weak self] in self?.bootCPM() }
        machine.onSerialOutput = { [weak self] byte in
            self?.appendTerminal(byte)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(Self.ticksPerSecond), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // 一時停止や画面スリープ後に大量の命令を一気に実行しないよう、経過時間は 0.1 秒で頭打ちにする
        let elapsed = min(now - lastTick, 0.1)
        lastTick = now
        if powered && machine.running {
            switch cpuSpeed {
            case .realTime:
                cycleDebt += elapsed * Double(AltairMachine.clockHz)
                let used = machine.run(cycles: Int(cycleDebt))
                cycleDebt = machine.cpu.halted ? 0 : cycleDebt - Double(used)
            case .fast:
                while machine.running && ProcessInfo.processInfo.systemUptime - now < 0.008 {
                    machine.run(cycles: 20_000)
                }
                cycleDebt = 0
            }
        } else {
            cycleDebt = 0
        }
        refresh()
    }

    private func refreshDrives() {
        let now = ProcessInfo.processInfo.systemUptime
        let counter = machine.disks.activityCounter
        if counter != lastDiskActivity {
            lastDiskActivity = counter
            if let d = machine.disks.lastActiveDrive, d < driveBusyUntil.count {
                driveBusyUntil[d] = now + 0.12
            }
        }
        var info = [DriveInfo]()
        for i in 0..<Self.visibleDrives {
            var d = DriveInfo()
            if let image = machine.disks.image(drive: i) {
                d.loaded = true
                d.name = image.url?.lastPathComponent ?? "DISK"
                d.track = machine.disks.headPosition(drive: i)?.track ?? 0
                d.busy = now < driveBusyUntil[i]
            }
            info.append(d)
        }
        if info != drives { drives = info }
    }

    private func refresh() {
        refreshDrives()
        running = machine.running
        status = machine.status
        inte = machine.cpu.inte
        addressLED = machine.running ? machine.lastAddress : machine.cpu.pc
        dataLED = machine.lastData
    }

    // MARK: パネル操作

    func toggleSwitch(_ bit: Int) { switches ^= (1 << UInt16(bit)) }
    func clearSwitches() { switches = 0 }
    func setPower(_ on: Bool) {
        if on && !powered { machine.reset() }  // 電源投入時は PC = 0、HLT 状態も解除
        powered = on
        if !on { machine.stop() }
        refresh()
    }
    func stopRun(run: Bool) {
        guard powered else { return }
        if run { machine.start() } else { machine.stop() }
        refresh()
    }
    func singleStep() { guard powered else { return }; machine.singleStep(); refresh() }
    func examine() { guard powered else { return }; machine.examine(); refresh() }
    func examineNext() { guard powered else { return }; machine.examineNext(); refresh() }
    func deposit() { guard powered else { return }; machine.deposit(); refresh() }
    func depositNext() { guard powered else { return }; machine.depositNext(); refresh() }
    func reset() { guard powered else { return }; machine.reset(); refresh() }
    func extClear() { guard powered else { return }; machine.extClear() }

    // MARK: 端末

    private func appendTerminal(_ raw: UInt8) {
        switch raw & 0x7F {
        case 0x0A: terminalText.append("\n")
        case 0x08, 0x7F: if !terminalText.isEmpty { terminalText.removeLast() }
        case 0x20...0x7E: terminalText.append(Character(UnicodeScalar(raw & 0x7F)))
        default: break  // CR などの制御文字は無視(LF で改行)
        }
        if terminalText.count > 20_000 { terminalText.removeFirst(5_000) }
    }

    func typeKey(_ characters: String) {
        for scalar in characters.unicodeScalars where scalar.isASCII {
            var v = UInt8(scalar.value)
            if uppercaseInput, v >= 0x61, v <= 0x7A { v -= 0x20 }
            machine.sendSerial(v)
        }
    }

    /// 飾りキーを短く光らせる。連打されたときは最後の押下から一定時間後に消す。
    func flashKeys(_ labels: [String]) {
        for label in labels {
            let generation = (litGeneration[label] ?? 0) + 1
            litGeneration[label] = generation
            litKeys.insert(label)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, self.litGeneration[label] == generation else { return }
                self.litKeys.remove(label)
            }
        }
    }

    func typeReturn() { machine.sendSerial(0x0D) }
    /// 削除キー。既定は BS(^H)で、CP/M は「BS-SP-BS」で画面上の文字を消す。
    /// DEL(7Fh)だと CP/M は削除した文字をそのままエコーする。Altair BASIC は 5Fh か 7Fh だけを削除として扱い、
    /// 08h は削除にならない(ROM で確認済み)ので、BASIC を起動したときは自動で '_' に切り替える。
    func typeBackspace() { machine.sendSerial(deleteKey.code) }

    /// 前方削除(fn + delete)は、ADM-3A の RUB OUT キーにあたる 7Fh を送る。
    func typeRubout() { machine.sendSerial(0x7F) }
    func clearTerminal() { terminalText = "" }

    // MARK: プログラム読み込み

    func loadDemo(_ name: String, _ bytes: [UInt8], autorun: Bool = false) {
        machine.stop()
        machine.removeROMs()
        machine.load(bytes, at: 0)
        machine.reset()
        powered = true
        if autorun { machine.start() }
        refresh()
        statusMessage = autorun
            ? "\(name) を 0000 に読み込んで実行中(RUN/STOP で停止)"
            : "\(name) をアドレス 0000 に読み込みました(RUN で実行)"
    }

    /// Altair BASIC 8K ROM(E000-FFFF)を取り付け、アドレススイッチ E000 → EXAMINE → RUN の操作を行う。
    func bootBasicROM() {
        let names = ["8kBas_e0.bin", "8kBas_e8.bin", "8kBas_f0.bin", "8kBas_f8.bin"]
        guard let dir = Bundle.module.resourceURL?.appendingPathComponent("roms") else { return }
        do {
            machine.stop()
            machine.reset()  // 前回の HLT 状態などを解除(RESET)
            machine.removeROMs()
            machine.setRAMSize(0x8000)
            deleteKey = .underscore  // Altair BASIC は 08h を削除として扱わない
            var address: UInt16 = 0xE000
            for name in names {
                let bytes = [UInt8](try Data(contentsOf: dir.appendingPathComponent(name)))
                machine.loadROM(bytes, at: address)
                address &+= UInt16(bytes.count)
            }
            clearTerminal()
            powered = true
            switches = 0xE000
            machine.examine()
            machine.start()
            refresh()
            statusMessage = "8K BASIC ROM を E000h に取り付けて起動しました(MEMORY SIZE は Return、WANT SIN-COS-TAN-ATN? は N)"
        } catch {
            statusMessage = "ROM の読み込みに失敗: \(error)"
        }
    }

    // MARK: ディスクと CP/M

    /// アプリ同梱のイメージを書き込み可能な作業用コピーとして Application Support に置く
    private func workingCopy(of name: String) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AltairSim/disks", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let dest = support.appendingPathComponent(name)
        if !fm.fileExists(atPath: dest.path) {
            guard let src = Bundle.module.resourceURL?.appendingPathComponent("disks/\(name)"),
                  fm.fileExists(atPath: src.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try fm.copyItem(at: src, to: dest)
        }
        return dest
    }

    /// 88-DCDD ブートローダ ROM(FF00h)でドライブ A から CP/M 2.2 を起動する。
    func bootCPM() {
        bootFromDisks([("cpm22b23-56k.dsk", 0)], label: "CP/M 2.2")
    }

    /// CP/M 3(ドライブ A = システムディスク、B = ユーティリティディスク)を起動する。
    func bootCPM3() {
        bootFromDisks([("cpm3_v1.0_56K_disk1.dsk", 0), ("cpm3_v1.0_56k_disk2.dsk", 1)], label: "CP/M 3")
    }

    /// Zork(Burcon 56K CP/M 2.2 のブータブルディスク)をドライブ A から起動する。
    func bootZork() {
        bootFromDisks([("zork.dsk", 0)], label: "Zork ディスク")
    }

    /// 8080 命令テスト(.COM)を、BDOS 互換のシムを載せたこのマシン上で実行し、結果を端末に出す。
    func runCPUTest(_ file: String, title: String, fast: Bool) {
        do {
            guard let dir = Bundle.module.resourceURL?.appendingPathComponent("cpu_tests") else { return }
            let com = [UInt8](try Data(contentsOf: dir.appendingPathComponent(file)))
            machine.stop()
            CPMConsoleShim.load(com: com, into: machine)
            clearTerminal()
            powered = true
            cpuSpeed = fast ? .fast : .realTime
            machine.start()
            refresh()
            statusMessage = "\(title) を実行中(終了すると HLT で止まり HLTA が点灯します。CPU: \(fast ? "最速" : "2MHz"))"
        } catch {
            statusMessage = "\(title) の読み込みに失敗: \(error)"
        }
    }

    private func bootFromDisks(_ files: [(name: String, drive: Int)], label: String) {
        do {
            guard let dir = Bundle.module.resourceURL?.appendingPathComponent("roms") else { return }
            let dbl = [UInt8](try Data(contentsOf: dir.appendingPathComponent("88dskrom.bin")))
            var paths: [String] = []

            machine.stop()
            machine.reset()  // 前回の HLT 状態などを解除(RESET)
            machine.removeROMs()
            machine.setRAMSize(0x10000)
            machine.clearMemory()
            deleteKey = .backspace  // CP/M は ^H で画面上の文字を消す
            for d in 0..<Self.visibleDrives { machine.disks.unmount(drive: d) }
            for f in files {
                let url = try workingCopy(of: f.name)
                machine.disks.mount(try DiskImage(contentsOf: url), drive: f.drive)
                paths.append(url.path)
            }
            machine.disks.reset()
            machine.loadROM(dbl, at: 0xFF00)
            clearTerminal()
            powered = true
            switches = 0xFF00
            machine.examine()
            machine.start()
            refresh()
            statusMessage = "\(label) をドライブ A から起動します(ディスクの変更は \(paths.first ?? "") などの作業用コピーに保存されます)"
        } catch {
            statusMessage = "\(label) の起動に失敗: ディスクイメージが見つかりません(\(error))"
        }
    }

    func mountDisk(drive: Int) {
        let panel = NSOpenPanel()
        panel.message = "ドライブ \(Character(UnicodeScalar(UInt8(65 + drive)))) に装着するディスクイメージ(.dsk、337,568 バイト)を選択"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let disk = try DiskImage(contentsOf: url)
            machine.disks.unmount(drive: drive)
            machine.disks.mount(disk, drive: drive)
            refreshDrives()
            statusMessage = "ドライブ \(Character(UnicodeScalar(UInt8(65 + drive)))): \(url.lastPathComponent) を装着しました(書き込みはファイルに直接反映されます)"
        } catch {
            statusMessage = "ディスクの装着に失敗: \(error)"
        }
    }

    func ejectDisk(drive: Int) {
        machine.disks.unmount(drive: drive)
        refreshDrives()
        statusMessage = "ドライブ \(Character(UnicodeScalar(UInt8(65 + drive)))) のディスクを取り外しました"
    }

    func flushDisks() { machine.disks.flushAll() }

    func loadFile() {
        let panel = NSOpenPanel()
        panel.message = "Intel HEX(.hex)またはバイナリ(.bin)を選択"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "hex" {
                let text = String(decoding: data, as: UTF8.self)
                var total = 0
                for rec in try HexLoader.parse(text) {
                    machine.load(rec.bytes, at: rec.address)
                    total += rec.bytes.count
                }
                statusMessage = "\(url.lastPathComponent): \(total) バイトを読み込みました"
            } else {
                machine.load([UInt8](data), at: 0)
                statusMessage = "\(url.lastPathComponent): \(data.count) バイトをアドレス 0000 に読み込みました"
            }
            machine.reset()
            refresh()
        } catch {
            statusMessage = "読み込み失敗: \(error)"
        }
    }
}
