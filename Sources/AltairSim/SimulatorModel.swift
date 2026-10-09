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
    @Published var screen = TerminalScreen()
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
    /// ライブラリ(利用者が取り込んだ ROM・ディスクイメージ)の変更通知用。取り込み・削除のたびに増やす
    @Published var libraryRevision = 0
    @Published var userItems: [UserItem] = []
    var library: AssetLibrary { AssetLibrary.shared }
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
    private var lastDiskActivityTime: TimeInterval = 0

    @Published var litKeys: Set<String> = []
    private var litGeneration: [String: Int] = [:]

    /// 実機の構成に合わせて RAM は 32KB。E000h 以降は ROM 用に空ける。
    let machine = AltairMachine(ramSize: 0x8000)
    /// 動かす機種。端末は共用で、パネルとディスクは機種ごとに変わる。
    enum Computer: String, CaseIterable, Identifiable {
        case altair8800 = "Altair 8800"
        case altair680b = "Altair 680b"
        var id: String { rawValue }
    }
    @Published var computer: Computer = .altair8800

    // Altair 680b(Motorola 6800)
    let machine680 = Altair680Machine(ramSize: 0x2000)
    @Published var sw680Address: UInt16 = 0 { didSet { machine680.addressSwitches = sw680Address } }
    @Published var sw680Data: UInt8 = 0 { didSet { machine680.dataSwitches = sw680Data } }
    @Published var led680Address: UInt16 = 0
    @Published var led680Data: UInt8 = 0
    @Published var run680 = false
    /// 「端末なし」ストラップ。true だとモニタはリセット後に 0000 番地へ飛ぶ(フロントパネルだけで使う構成)
    @Published var noTerminal680 = false { didSet { machine680.noTerminal = noTerminal680 } }

    private var timer: Timer?
    /// App Nap(アプリが前面を外れたときの省電力)を避けるための活動の宣言。エミュレーションは時間で進むので、
    /// タイマーの間隔を伸ばされると、実機より大幅に遅くなる(フォーマットなど長い処理が終わらなくなる)
    private var activity: NSObjectProtocol?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var cycleDebt = 0.0

    enum CPUSpeed: String, CaseIterable, Identifiable {
        case realTime = "実機の速度"
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
        didSet { machine.baudRate = baud.rate; machine680.baudRate = baud.rate }
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
        machine680.onSerialOutput = { [weak self] byte in
            self?.appendTerminal(byte)
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Altair のエミュレーション")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(Self.ticksPerSecond), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        // 一時停止や画面スリープ後に大量の命令を一気に実行しないよう、経過時間は 0.1 秒で頭打ちにする
        let elapsed = min(now - lastTick, 0.1)
        lastTick = now
        if computer == .altair680b {
            tick680(elapsed: elapsed, now: now)
            return
        }
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
        refreshThrottled(now: now)
    }

    /// 動かしている機種のディスクコントローラ(8800 は 88-DCDD、680b は 68-UIO 経由の FD3712)
    var activeDisks: DiskSubsystem {
        computer == .altair680b ? machine680.disks : machine.disks
    }

    private func refreshDrives() {
        let now = ProcessInfo.processInfo.systemUptime
        let disks = activeDisks
        let counter = disks.activityCounter
        if counter != lastDiskActivity {
            lastDiskActivity = counter
            lastDiskActivityTime = now
            if let d = disks.lastActiveDrive, d < driveBusyUntil.count {
                driveBusyUntil[d] = now + 0.12
            }
        } else if now - lastDiskActivityTime > 1.5,
                  (0..<Self.visibleDrives).contains(where: { disks.image(drive: $0)?.hasUnsavedChanges == true }) {
            // ディスクの動きが止まって 1.5 秒たったら、書き換わったイメージをファイルへ書き戻す
            // (アプリが突然終了しても、保存したファイルが残るように)
            disks.flushAll()
        }
        var info = [DriveInfo]()
        for i in 0..<Self.visibleDrives {
            var d = DriveInfo()
            if let image = disks.image(drive: i) {
                d.loaded = true
                d.name = image.url?.lastPathComponent ?? "DISK"
                d.track = disks.headPosition(drive: i)?.track ?? 0
                d.busy = now < driveBusyUntil[i]
            }
            info.append(d)
        }
        if info != drives { drives = info }
    }

    /// 画面(LED、ドライブの表示)の更新を、エミュレーションより低い頻度に間引く。
    /// 更新のたびに SwiftUI がパネル全体を描き直すので、毎ティック(60 回/秒)行うと、描画でメインスレッドが埋まって
    /// エミュレーションが実機の速さに追いつかなくなる(ディスクのフォーマットのような長い処理が進まなくなる)
    private var lastRefreshTime: TimeInterval = 0
    private func refreshThrottled(now: TimeInterval) {
        guard now - lastRefreshTime >= 1.0 / 15.0 else { return }
        lastRefreshTime = now
        refresh()
    }

    private func refresh() {
        refreshDrives()
        if computer == .altair680b {
            run680 = machine680.running
            led680Address = machine680.addressLEDs
            led680Data = machine680.dataLEDs
            return
        }
        running = machine.running
        status = machine.status
        inte = machine.cpu.inte
        addressLED = machine.running ? machine.lastAddress : machine.cpu.pc
        dataLED = machine.lastData
    }

    // MARK: 16 進入力

    /// スイッチの現在値(16 進 4 桁)。
    var switchesHex: String { String(format: "%04X", switches) }

    /// 16 進文字列(例: "FF00"、"0x3E")をスイッチに反映する。解釈できないときは false。
    @discardableResult
    func setSwitches(hex: String) -> Bool {
        let t = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "")
        guard !t.isEmpty, t.count <= 4, let v = UInt16(t, radix: 16) else {
            statusMessage = "スイッチ値は 16 進 1〜4 桁で入力してください(例: FF00)"
            return false
        }
        switches = v
        return true
    }

    /// 「番地: バイト列」を、パネルの EXAMINE → DEPOSIT → DEPOSIT NEXT … と同じ手順で書き込む。
    /// 例: `0000: 3E 01 76`。RUN 中は STOP してから書き込み、書き込み後は番地を先頭に戻す。
    func depositHex(_ text: String) {
        guard powered else { statusMessage = "電源が OFF です"; return }
        let parts = text.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let address = UInt16(parts[0].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            statusMessage = "書式は「番地: バイト列」です(例: 0000: 3E 01 76)"
            return
        }
        let tokens = parts[1].split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        let bytes = tokens.compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        guard !bytes.isEmpty, bytes.count == tokens.count else {
            statusMessage = "バイト列は 16 進 2 桁を空白かカンマで区切ってください(例: 3E 01 76)"
            return
        }
        let wasRunning = machine.running
        machine.stop()
        switches = address
        machine.examine()
        for (i, b) in bytes.enumerated() {
            switches = UInt16(b)
            if i == 0 { machine.deposit() } else { machine.depositNext() }
        }
        switches = address
        machine.examine()
        refresh()
        let unwritable = bytes.indices.filter { machine.kinds[(Int(address) + $0) & 0xFFFF] != .ram }
        statusMessage = String(format: "%04X から %d バイトを書き込みました", address, bytes.count)
            + (unwritable.isEmpty ? "" : "(RAM でない番地 \(unwritable.count) バイトは書き込まれません)")
            + (wasRunning ? "。実行を止めました(RUN で再開)" : "")
    }

    // MARK: ライブラリ(利用者が取り込む ROM・ディスクイメージ)

    /// 機能に必要なファイルがそろっているか確認する。足りなければ案内を出して設定画面を開く。
    private func requireLibrary(_ feature: LibraryFeature) -> Bool {
        guard library.isAvailable(feature) else {
            statusMessage = library.missingMessage(feature)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return false
        }
        return true
    }

    /// 設定画面から呼ぶ。ファイルやフォルダを取り込み、結果を状態欄にも出す。
    @discardableResult
    func importLibraryItems(_ urls: [URL]) -> LibraryImportReport {
        let report = library.importItems(urls)
        libraryRevision += 1
        statusMessage = "ライブラリ: " + report.summary
        return report
    }

    func removeLibraryAsset(_ asset: LibraryAsset) {
        do { try library.remove(asset) } catch { statusMessage = "削除に失敗: \(error)" }
        libraryRevision += 1
    }

    // MARK: ユーザー追加(別のディスクイメージ、ROM、プログラム)

    var userLibrary: UserLibrary { UserLibrary(library: library) }

    func reloadUserItems() { userItems = userLibrary.items() }

    func addUserItem(source: URL, name: String, kind: UserItem.Kind, address: UInt16, start: UInt16?, asROM: Bool, ramKB: Int) throws {
        let item = try userLibrary.add(source: source, name: name, kind: kind, address: address, start: start, asROM: asROM, ramKB: ramKB)
        reloadUserItems()
        statusMessage = "「\(item.name)」を追加しました(\(kind.title))"
    }

    func updateUserItem(_ item: UserItem) throws {
        try userLibrary.update(item)
        reloadUserItems()
        statusMessage = "「\(item.name)」を更新しました"
    }

    func removeUserItem(_ item: UserItem) {
        do {
            try userLibrary.remove(item)
            discardUserWorkingCopy(item)
            statusMessage = "「\(item.name)」を削除しました"
        } catch {
            statusMessage = "削除に失敗: \(error)"
        }
        reloadUserItems()
    }

    /// ディスクの作業用コピー(書き込みが入るファイル)
    private func userWorkingCopyURL(_ item: UserItem) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AltairSim/disks", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("user-\(item.id.uuidString)-\(item.originalName)")
    }

    private func userWorkingCopy(_ item: UserItem) throws -> URL {
        let dest = try userWorkingCopyURL(item)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: userLibrary.fileURL(item), to: dest)
        }
        return dest
    }

    func hasUserWorkingCopy(_ item: UserItem) -> Bool {
        guard let url = try? userWorkingCopyURL(item) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 作業用コピーを捨てる。次の起動では、追加したときのイメージから始まる。
    func discardUserWorkingCopy(_ item: UserItem) {
        if let url = try? userWorkingCopyURL(item), FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            libraryRevision += 1
        }
    }

    func launchUser(_ item: UserItem) {
        do {
            switch item.kind {
            case .disk8800:
                guard requireLibrary(LibraryFeature(name: item.name, paths: ["roms/88dskrom.bin"])) else { return }
                try bootFromDiskURLs([(try userWorkingCopy(item), 0)], label: item.name)
            case .disk680:
                boot680DiskImage(try userWorkingCopy(item), title: item.name, linkFLEX: true)
            case .program8800:
                try launchProgram8800(item)
            case .program680:
                try launchProgram680(item)
            }
        } catch {
            statusMessage = "\(item.name) の起動に失敗: \(error)"
        }
        libraryRevision += 1
    }

    /// 動かしている機種のドライブへ、ユーザー追加のディスクを装着する(起動はしない)
    func mountUser(_ item: UserItem, drive: Int) {
        guard item.kind.isDisk else { return }
        let need: Computer = item.kind == .disk680 ? .altair680b : .altair8800
        guard computer == need else {
            statusMessage = "「\(item.name)」は \(need.rawValue) 用です。機種を切り替えてから装着してください"
            return
        }
        do {
            let disk = try DiskImage(contentsOf: try userWorkingCopy(item), geometry: need == .altair680b ? .ibm3740 : .mitsDCDD)
            activeDisks.unmount(drive: drive)
            activeDisks.mount(disk, drive: drive)
            refreshDrives()
            statusMessage = "ドライブ \(Character(UnicodeScalar(UInt8(65 + drive)))): 「\(item.name)」を装着しました(書き込みは作業用コピーに入ります)"
        } catch {
            statusMessage = "装着に失敗: \(error)"
        }
    }

    private func launchProgram8800(_ item: UserItem) throws {
        let data = try Data(contentsOf: userLibrary.fileURL(item))
        let records: [(address: UInt16, bytes: [UInt8])]
        if item.originalName.lowercased().hasSuffix(".hex") {
            records = try HexLoader.parse(String(decoding: data, as: UTF8.self))
        } else {
            records = [(item.address, [UInt8](data))]
        }
        guard let first = records.first else { throw UserLibraryError.unreadable("\(item.originalName)(データがありません)") }
        switchComputerQuietly(.altair8800)
        machine.stop()
        machine.reset()
        machine.removeROMs()
        machine.setRAMSize(min(max(item.ramKB, 1), 64) * 1024)
        machine.clearMemory()
        for r in records {
            if item.asROM { machine.loadROM(r.bytes, at: r.address) } else { machine.load(r.bytes, at: r.address) }
        }
        deleteKey = .backspace
        clearTerminal()
        powered = true
        let start = item.start ?? first.address
        switches = start
        machine.examine()
        machine.start()
        refresh()
        statusMessage = "「\(item.name)」を\(item.asROM ? "ROM として" : "")読み込み、\(String(format: "%04X", start)) から実行します"
    }

    private func launchProgram680(_ item: UserItem) throws {
        let text = String(decoding: try Data(contentsOf: userLibrary.fileURL(item)), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let ram = min(max(item.ramKB, 1), 48) * 1024
        if item.asROM {
            switchComputerQuietly(.altair680b)
            machine680.setRunning(false)
            machine680.removeROMs()
            machine680.setRAMSize(ram)
            machine680.uioInstalled = false
            machine680.clearMemory()
            _ = try machine680.loadS19(text)
            noTerminal680 = false
            deleteKey = .underscore
            clearTerminal()
            powered = true
            machine680.reset()
            machine680.setRunning(true)
            refresh()
            statusMessage = "「\(item.name)」を ROM として取り付け、モニタなしで RESET ベクタから起動しました"
        } else {
            guard requireLibrary(.monitor680) else { return }
            boot680b(withTerminal: true, config: Config680(ramSize: ram))
            let bytes = try machine680.loadS19(text)
            if let start = item.start {
                for u in String(format: "J%04X", start).utf8 { machine680.sendSerial(u) }
                statusMessage = "「\(item.name)」(\(bytes) バイト)を読み込み、モニタの J \(String(format: "%04X", start)) で実行します"
            } else {
                statusMessage = "「\(item.name)」(\(bytes) バイト)を読み込みました。実行はモニタの J コマンドで"
            }
            refresh()
        }
    }

    // MARK: パネル操作

    func toggleSwitch(_ bit: Int) { switches ^= (1 << UInt16(bit)) }
    func clearSwitches() { switches = 0 }
    func setPower(_ on: Bool) {
        if computer == .altair680b {
            if on && !powered { machine680.reset() }
            powered = on
            if !on { machine680.setRunning(false) }
            refresh()
            return
        }
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
        screen.put(raw)
    }

    func typeKey(_ characters: String) {
        for scalar in characters.unicodeScalars where scalar.isASCII {
            var v = UInt8(scalar.value)
            if uppercaseInput, v >= 0x61, v <= 0x7A { v -= 0x20 }
            sendSerial(v)
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

    func typeReturn() { sendSerial(0x0D) }
    /// 削除キー。既定は BS(^H)で、CP/M は「BS-SP-BS」で画面上の文字を消す。
    /// DEL(7Fh)だと CP/M は削除した文字をそのままエコーする。Altair BASIC は 5Fh か 7Fh だけを削除として扱い、
    /// 08h は削除にならない(ROM で確認済み)ので、BASIC を起動したときは自動で '_' に切り替える。
    func typeBackspace() { sendSerial(deleteKey.code) }

    /// 前方削除(fn + delete)は、ADM-3A の RUB OUT キーにあたる 7Fh を送る。
    func typeRubout() { sendSerial(0x7F) }
    func clearTerminal() { screen = TerminalScreen() }

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
        guard requireLibrary(.basic8K) else { return }
        let names = ["8kBas_e0.bin", "8kBas_e8.bin", "8kBas_f0.bin", "8kBas_f8.bin"]
        do {
            machine.stop()
            machine.reset()  // 前回の HLT 状態などを解除(RESET)
            machine.removeROMs()
            machine.setRAMSize(0x8000)
            machine.clearMemory()  // 前のプログラムのメモリが残っていると BASIC が起動しない(電源投入時は 0)
            deleteKey = .underscore  // Altair BASIC は 08h を削除として扱わない
            var address: UInt16 = 0xE000
            for name in names {
                let bytes = [UInt8](try library.data("roms/\(name)"))
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

    /// ライブラリのイメージを、書き込み可能な作業用コピーとして Application Support に置く
    private func workingCopy(of name: String, libraryPath: String) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AltairSim/disks", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let dest = support.appendingPathComponent(name)
        if !fm.fileExists(atPath: dest.path) {
            let src = library.url(libraryPath)
            guard fm.fileExists(atPath: src.path) else { throw CocoaError(.fileNoSuchFile) }
            try fm.copyItem(at: src, to: dest)
        }
        return dest
    }

    /// 88-DCDD ブートローダ ROM(FF00h)でドライブ A から CP/M 2.2 を起動する。
    func bootCPM() {
        bootFromDisks(.cpm22, [("cpm22b23-56k.dsk", 0)], label: "CP/M 2.2")
    }

    /// CP/M 3(ドライブ A = システムディスク、B = ユーティリティディスク)を起動する。
    func bootCPM3() {
        bootFromDisks(.cpm3, [("cpm3_v1.0_56K_disk1.dsk", 0), ("cpm3_v1.0_56k_disk2.dsk", 1)], label: "CP/M 3")
    }

    /// Zork(Burcon 56K CP/M 2.2 のブータブルディスク)をドライブ A から起動する。
    func bootZork() {
        bootFromDisks(.zork, [("zork.dsk", 0)], label: "Zork ディスク")
    }

    /// 8080 命令テスト(.COM)を、BDOS 互換のシムを載せたこのマシン上で実行し、結果を端末に出す。
    func runCPUTest(_ file: String, title: String, fast: Bool) {
        guard requireLibrary(.cpuTest(file)) else { return }
        do {
            let com = [UInt8](try library.data("cpu_tests/\(file)"))
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

    private func bootFromDisks(_ feature: LibraryFeature, _ files: [(name: String, drive: Int)], label: String) {
        guard requireLibrary(feature) else { return }
        do {
            let urls = try files.map { (try workingCopy(of: $0.name, libraryPath: "disks/\($0.name)"), $0.drive) }
            try bootFromDiskURLs(urls, label: label)
        } catch {
            statusMessage = "\(label) の起動に失敗: \(error)"
        }
    }

    /// 88-DCDD ブートローダ(FF00h)で、指定のイメージ(作業用コピー)から起動する。
    private func bootFromDiskURLs(_ files: [(url: URL, drive: Int)], label: String) throws {
        let dbl = [UInt8](try library.data("roms/88dskrom.bin"))
        var paths: [String] = []

        switchComputerQuietly(.altair8800)
        machine.stop()
        machine.reset()  // 前回の HLT 状態などを解除(RESET)
        machine.removeROMs()
        machine.setRAMSize(0x10000)
        machine.clearMemory()
        deleteKey = .backspace  // CP/M は ^H で画面上の文字を消す
        for d in 0..<Self.visibleDrives { machine.disks.unmount(drive: d) }
        for f in files {
            machine.disks.mount(try DiskImage(contentsOf: f.url), drive: f.drive)
            paths.append(f.url.path)
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
    }

    func mountDisk(drive: Int) {
        let panel = NSOpenPanel()
        panel.message = "ドライブ \(Character(UnicodeScalar(UInt8(65 + drive)))) に装着するディスクイメージ(.dsk、\(diskGeometry.size) バイト以上)を選択"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let disk = try DiskImage(contentsOf: url, geometry: diskGeometry)
            activeDisks.unmount(drive: drive)
            activeDisks.mount(disk, drive: drive)
            refreshDrives()
            statusMessage = "ドライブ \(Character(UnicodeScalar(UInt8(65 + drive)))): \(url.lastPathComponent) を装着しました(書き込みはファイルに直接反映されます)"
        } catch {
            statusMessage = "ディスクの装着に失敗: \(error)"
        }
    }

    /// 新しい空のディスクイメージをファイルとして作り、ドライブへ装着する。未フォーマットの状態(全バイト 0)で、
    /// ゲスト側のフォーマット用ツール(CP/M の AFORMAT、FLEX の NEWDISK、CP/68 の INIT)でフォーマットして使う。
    func createBlankDisk(drive: Int) {
        let letter = Character(UnicodeScalar(UInt8(65 + drive)))
        let is680 = computer == .altair680b
        let panel = NSSavePanel()
        panel.message = "新しい空ディスク(未フォーマット、\(diskGeometry.size) バイト)を保存して、ドライブ \(letter) に装着します"
        panel.nameFieldStringValue = is680 ? "blank-680b.dsk" : "blank-8800.dsk"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // 680b(FD3712)は、書いて初めて存在するセクタ。記録ファイル(.fmt)で未フォーマットを覚えておく。
            // 88-DCDD は、ヘッダを書いていない生のセクタが CP/M のヘッダ検査で弾かれるので、バイト列だけでよい
            let disk = try DiskImage.createBlank(at: url, geometry: diskGeometry, unformatted: is680)
            activeDisks.unmount(drive: drive)
            activeDisks.mount(disk, drive: drive)
            refreshDrives()
            let tool = is680 ? "FLEX なら NEWDISK(例: NEWDISK \(drive))、CP/68 なら INIT(例: INIT \(drive))" : "CP/M なら AFORMAT \(letter):"
            statusMessage = "ドライブ \(letter): 新しい空ディスク \(url.lastPathComponent) を作って装着しました。未フォーマットなので、\(tool) でフォーマットしてください"
        } catch {
            statusMessage = "空ディスクの作成に失敗: \(error)"
        }
    }

    func ejectDisk(drive: Int) {
        activeDisks.unmount(drive: drive)
        refreshDrives()
        statusMessage = "ドライブ \(Character(UnicodeScalar(UInt8(65 + drive)))) のディスクを取り外しました"
    }

    func flushDisks() {
        machine.disks.flushAll()
        machine680.disks.flushAll()
    }

    /// 動かしている機種のディスクの寸法(8800: 88-DCDD の 137 バイト/セクタ、680b: IBM 3740 の 128 バイト × 26)
    private var diskGeometry: DiskImage.Geometry {
        computer == .altair680b ? .ibm3740 : .mitsDCDD
    }

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

    // MARK: Altair 680b

    private func tick680(elapsed: Double, now: TimeInterval) {
        if powered && machine680.running {
            switch cpuSpeed {
            case .realTime:
                cycleDebt += elapsed * Double(Altair680Machine.clockHz)
                let used = machine680.run(cycles: Int(cycleDebt))
                cycleDebt -= Double(used)
            case .fast:
                while machine680.running && ProcessInfo.processInfo.systemUptime - now < 0.008 {
                    machine680.run(cycles: 20_000)
                }
                cycleDebt = 0
            }
        } else {
            cycleDebt = 0
        }
        refreshThrottled(now: now)
    }

    /// 端末への 1 バイト入力を、動かしている機種へ送る
    func sendSerial(_ byte: UInt8) {
        if computer == .altair680b { machine680.sendSerial(byte) } else { machine.sendSerial(byte) }
    }

    func selectComputer(_ next: Computer) {
        guard next != computer else { return }
        machine.stop()
        machine680.setRunning(false)
        computer = next
        cycleDebt = 0
        if next == .altair680b {
            boot680b(withTerminal: true)
        } else {
            bootCPM()
        }
    }

    /// 起動処理はせずに、表示する機種だけ切り替える(selectComputer は切り替え時に既定の OS を起動する)。
    private func switchComputerQuietly(_ next: Computer) {
        guard next != computer else { return }
        machine.stop()
        machine680.setRunning(false)
        computer = next
        cycleDebt = 0
    }

    /// 680b の構成(モニタ、RAM の量、68-UIO ボードの有無、起動 PROM)
    struct Config680 {
        var monitor = "MON680.S19"        // FF00〜。ディスク OS には、SWI を RAM 経由にした SWIMON を使う
        var ramSize = 0x2000
        var uio = false
        var bootPROM: String?             // FC00 に置く起動 PROM(ディスク OS 用)
    }

    /// 680b の PROM モニタ(ACIA 版、FF00〜)を載せて、リセットして RUN にする。
    /// withTerminal = false は「端末なし」ストラップで、モニタは 0000 番地へ飛ぶ(フロントパネル運用)。
    func boot680b(withTerminal: Bool, config: Config680 = Config680()) {
        switchComputerQuietly(.altair680b)
        var needed = ["altair680/monitor/\(config.monitor)"]
        if let prom = config.bootPROM { needed.append("altair680/boot/\(prom)") }
        guard requireLibrary(LibraryFeature(name: "680b モニタ", paths: needed)) else { return }
        do {
            machine680.setRunning(false)
            machine680.removeROMs()
            machine680.setRAMSize(config.ramSize)
            machine680.uioInstalled = config.uio
            let monitor = String(decoding: try library.data("altair680/monitor/\(config.monitor)"), as: UTF8.self)
            try machine680.loadS19(monitor)
            if let prom = config.bootPROM {
                let text = String(decoding: try library.data("altair680/boot/\(prom)"), as: UTF8.self)
                try machine680.loadS19(text)
            }
            machine680.clearMemory()
            noTerminal680 = !withTerminal
            deleteKey = .underscore  // Altair BASIC(680)も 8800 版と同じく '_' で 1 文字削除
            clearTerminal()
            powered = true
            machine680.reset()
            machine680.setRunning(true)
            refresh()
            statusMessage = withTerminal
                ? "680b のモニタを起動しました(プロンプトは「.」。M で表示と書き込み、J で実行、L でテープ読み込み)"
                : "680b を「端末なし」で起動しました(リセット後は 0000 番地から実行します)"
        } catch {
            statusMessage = "680b のモニタの読み込みに失敗: \(error)"
        }
    }

    /// 68-UIO と FD3712 で動くディスク OS
    enum DiskOS {
        case flex3, cpm68
        var title: String { self == .flex3 ? "FLEX 3.0" : "CP/68" }
        var imageName: String { self == .flex3 ? "flex3-680.dsk" : "cp68-altair680.dsk" }
    }

    /// ディスク OS を起動する。実機の手順と同じく、SWIMON と起動 PROM(FC00)を載せ、68-UIO を差し、
    /// ドライブ 0 にディスクを入れて、モニタの J FC00 で起動 PROM へ飛ぶ。
    func boot680Disk(_ os: DiskOS) {
        guard requireLibrary(os == .flex3 ? .flex3 : .cpm68) else { return }
        do {
            let url = try workingCopy(of: os.imageName, libraryPath: "altair680/disks/\(os.imageName)")
            boot680DiskImage(url, title: os.title, linkFLEX: os == .flex3)
        } catch {
            statusMessage = "\(os.title) の起動に失敗: \(error)"
        }
    }

    /// 680b のディスクイメージ(作業用コピー)から、起動 PROM 経由で起動する。
    private func boot680DiskImage(_ url: URL, title: String, linkFLEX: Bool) {
        guard requireLibrary(LibraryFeature(name: title, paths: ["altair680/monitor/SWIMON.S19", "altair680/boot/BOOT.S19"])) else { return }
        do {
            let image = try DiskImage(contentsOf: url, geometry: .ibm3740)
            // 配布の FLEX 3.0 のイメージは、ブートローダにシステムファイルの位置が書かれていない(LINK.CMD を実行する前の状態)。
            // LINK と同じ処理を、作業用コピーに行う
            let linked = linkFLEX && FLEXImage.linkBootLoader(image)
            boot680b(withTerminal: true, config: Config680(monitor: "SWIMON.S19", ramSize: 0xC000, uio: true, bootPROM: "BOOT.S19"))
            for d in 0..<FD3712Controller.maxDrives { machine680.disks.unmount(drive: d) }
            machine680.disks.mount(image, drive: 0)
            deleteKey = .backspace
            for u in "JFC00".utf8 { machine680.sendSerial(u) }
            refresh()
            statusMessage = "\(title) を起動します(モニタの J FC00 で起動 PROM へ。RAM 48KB、ドライブ A: \(url.lastPathComponent)。変更は作業用コピーに保存されます)"
                + (linked ? "。ブートローダに FLEX3.SYS の位置を書き込みました(LINK と同じ処理)" : "")
        } catch {
            statusMessage = "\(title) の起動に失敗: \(error)"
        }
    }

    /// 紙テープ版の BASIC(S レコード)を、モニタの L コマンドで読み込んで起動する。
    /// 読み込みはシリアルから流し込むので、速度設定に応じて数秒かかる。
    func load680BASIC() {
        guard requireLibrary(.basic680) else { return }
        do {
            let tape = String(decoding: try library.data("altair680/basic/paper-basic-v1.1-r3.2.s19"), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            boot680b(withTerminal: true)
            for u in ("L" + tape + "J0000").utf8 { machine680.sendSerial(u) }
            statusMessage = "BASIC をモニタの L コマンドで読み込んで起動します(MEMORY SIZE? は Return、TERMINAL WIDTH? は Return、WANT SIN-COS-TAN-ATN? は N)"
        } catch {
            statusMessage = "BASIC の読み込みに失敗: \(error)"
        }
    }

    func toggle680Address(_ bit: Int) { sw680Address ^= (1 << UInt16(bit)); refresh() }
    func toggle680Data(_ bit: Int) { sw680Data ^= (1 << UInt8(bit)); refresh() }
    func panel680Reset() { guard powered else { return }; machine680.reset(); refresh() }
    func panel680SetRun(_ run: Bool) { guard powered else { return }; machine680.setRunning(run); refresh() }
    func panel680Deposit() { guard powered else { return }; machine680.deposit(); refresh() }
}
