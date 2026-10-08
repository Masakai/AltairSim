import AltairCore
import AppKit
import SwiftUI

@main
struct AltairSimApp: App {
    @StateObject private var model = SimulatorModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Altair 8800 Simulator") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 640)
        }
        .defaultSize(width: 1560, height: 760)
    }
}

struct ContentView: View {
    @ObservedObject var model: SimulatorModel

    /// パネル、読み込みボタン、速度設定、状態表示の左カラム
    private var computerPicker: some View {
        HStack {
            Picker("機種", selection: Binding(get: { model.computer }, set: { model.selectComputer($0) })) {
                ForEach(SimulatorModel.Computer.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            Spacer()
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 12) {
            computerPicker
            if model.computer == .altair680b {
                column680
            } else {
                column8800
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            Spacer(minLength: 0)
        }
    }

    /// Altair 680b: パネルと、モニタ・BASIC の起動ボタン(ディスクはない)
    private var column680: some View {
        VStack(spacing: 12) {
            FrontPanel680View(model: model)
            HStack {
                Button("モニタ起動", action: { model.boot680b(withTerminal: true) })
                    .help("PROM モニタを起動して「.」のプロンプトを出す")
                Button("BASIC を読み込んで起動", action: model.load680BASIC)
                    .help("紙テープ版 BASIC を、モニタの L コマンドで読み込んで J 0000 で起動")
                Button("FLEX 3.0", action: { model.boot680Disk(.flex3) })
                    .help("68-UIO と FD3712 のディスクから FLEX 3.0 を起動(RAM 48KB)")
                Button("CP/68", action: { model.boot680Disk(.cpm68) })
                    .help("68-UIO と FD3712 のディスクから CP/68 を起動(RAM 48KB)")
                Menu("ディスク") {
                    ForEach(0..<SimulatorModel.visibleDrives, id: \.self) { d in
                        let name = String(UnicodeScalar(UInt8(65 + d)))
                        Button("ドライブ \(name) にディスクを装着…") { model.mountDisk(drive: d) }
                    }
                    Divider()
                    ForEach(0..<SimulatorModel.visibleDrives, id: \.self) { d in
                        let name = String(UnicodeScalar(UInt8(65 + d)))
                        Button("ドライブ \(name) を取り外す") { model.ejectDisk(drive: d) }
                    }
                }
                Toggle("端末なし(フロントパネル運用)", isOn: $model.noTerminal680).font(.caption)
                Spacer()
            }
            TerminalControls(model: model)
            DiskDriveView(model: model, first: 0)
            DiskDriveView(model: model, first: 2)
        }
    }

    private var column8800: some View {
        VStack(spacing: 12) {
            FrontPanelView(model: model)
            HStack {
                Button("BASIC 8K", action: model.bootBasicROM).help("Altair BASIC 8K ROM で起動")
                Button("CP/M 2.2", action: model.bootCPM).help("CP/M 2.2 をドライブ A から起動")
                Button("CP/M 3", action: model.bootCPM3).help("CP/M 3 をドライブ A・B から起動")
                Button("Zork", action: model.bootZork).help("Zork ディスクをドライブ A から起動(ZORK1 / ZORK2 と入力)")
                Menu("ディスク") {
                    ForEach(0..<SimulatorModel.visibleDrives, id: \.self) { d in
                        let name = String(UnicodeScalar(UInt8(65 + d)))
                        Button("ドライブ \(name) にディスクを装着…") { model.mountDisk(drive: d) }
                    }
                    Divider()
                    ForEach(0..<SimulatorModel.visibleDrives, id: \.self) { d in
                        let name = String(UnicodeScalar(UInt8(65 + d)))
                        Button("ドライブ \(name) を取り外す") { model.ejectDisk(drive: d) }
                    }
                }
                Menu("デモを読み込む") {
                    Button("ECHO(受信文字をそのまま返す)") { model.loadDemo("ECHO", DemoPrograms.echo) }
                    Button("HELLO(文字列を出力して HLT)") { model.loadDemo("HELLO", DemoPrograms.hello) }
                    Divider()
                    Button("LEDテスト: アドレス(A8-A15 を歩くビット)") {
                        model.loadDemo("LEDテスト(アドレス)", LEDTestPrograms.address, autorun: true)
                    }
                    Button("LEDテスト: データ(D0-D7 のパターン)") {
                        model.loadDemo("LEDテスト(データ)", LEDTestPrograms.data, autorun: true)
                    }
                    Button("LEDテスト: ステータス(INTE→STACK→INP→OUT→WO)") {
                        model.loadDemo("LEDテスト(ステータス)", LEDTestPrograms.status, autorun: true)
                    }
                    Button("LEDテスト: HLTA(HLT で停止)") {
                        model.loadDemo("LEDテスト(HLTA)", LEDTestPrograms.halt, autorun: true)
                    }
                }
                Menu("8080 テスト") {
                    Button("TST8080(CPU 診断、数ミリ秒)") {
                        model.runCPUTest("TST8080.COM", title: "TST8080", fast: false)
                    }
                    Button("8080PRE(前段テスト、数ミリ秒)") {
                        model.runCPUTest("8080PRE.COM", title: "8080PRE", fast: false)
                    }
                    Button("CPUTEST(SuperSoft、2MHz で約 2 分)") {
                        model.runCPUTest("CPUTEST.COM", title: "CPUTEST", fast: false)
                    }
                    Button("8080EXM(全命令の CRC 照合、最速で数十分〜数時間)") {
                        model.runCPUTest("8080EXM.COM", title: "8080EXM", fast: true)
                    }
                }
                Button("ファイルを読み込む(.hex / .bin)…", action: model.loadFile)
                Spacer()
            }
            TerminalControls(model: model)
            HexEntryView(model: model)
            DiskDriveView(model: model, first: 0)
            DiskDriveView(model: model, first: 2)
        }
    }

    var body: some View {
        // 幅があるときは左にパネル、右に端末。狭いときは縦に積む。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                controlColumn.frame(minWidth: 780, idealWidth: 860)
                TerminalView(model: model).frame(minWidth: 520, idealWidth: 640, maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 1340)
            VStack(spacing: 12) {
                controlColumn
                TerminalView(model: model)
            }
        }
        .padding(16)
    }
}

/// 16 進での入力補助。スイッチ値の設定と、バイト列の一括書き込み。
struct HexEntryView: View {
    @ObservedObject var model: SimulatorModel
    @State private var switchText = ""
    @State private var depositText = "0000: 3E 01 76"

    var body: some View {
        HStack(spacing: 8) {
            Text("スイッチ").font(.caption)
            TextField("FF00", text: $switchText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 64)
                .onSubmit { if model.setSwitches(hex: switchText) { switchText = model.switchesHex } }
            Button("設定") { if model.setSwitches(hex: switchText) { switchText = model.switchesHex } }
            Divider().frame(height: 18)
            Text("書き込み").font(.caption)
            TextField("0000: 3E 01 76", text: $depositText)
                .font(.system(.body, design: .monospaced))
                .onSubmit { model.depositHex(depositText) }
            Button("書き込む") { model.depositHex(depositText) }
                .help("EXAMINE → DEPOSIT → DEPOSIT NEXT … と同じ手順で RAM に書き込みます")
        }
        .onAppear { switchText = model.switchesHex }
        .onChange(of: model.switches) { _, _ in switchText = model.switchesHex }
    }
}
