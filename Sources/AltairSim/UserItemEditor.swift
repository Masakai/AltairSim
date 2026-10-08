import AltairCore
import SwiftUI

/// ユーザー追加項目の追加・編集シート。
struct UserItemEditor: View {
    enum Mode: Identifiable {
        case add(URL)
        case edit(UserItem)
        var id: String {
            switch self {
            case .add(let u): return "add-" + u.path
            case .edit(let i): return "edit-" + i.id.uuidString
            }
        }
    }

    @ObservedObject var model: SimulatorModel
    let mode: Mode
    /// 閉じるときに呼ぶ。引数は設定画面に出す結果メッセージ(キャンセルは nil)
    let done: (String?) -> Void

    @State private var name = ""
    @State private var kind: UserItem.Kind = .program8800
    @State private var address = "0000"
    @State private var start = ""
    @State private var asROM = false
    @State private var ramKB = 64
    @State private var error = ""
    @State private var loaded = false

    private var fileName: String {
        switch mode {
        case .add(let u): return u.lastPathComponent
        case .edit(let i): return i.originalName
        }
    }
    private var isAdd: Bool { if case .add = mode { return true } else { return false } }
    private var is680: Bool { kind == .program680 || kind == .disk680 }
    private var isProgram: Bool { kind == .program8800 || kind == .program680 }
    private var isHexFile: Bool { fileName.lowercased().hasSuffix(".hex") }
    private var ramChoices: [Int] { kind == .program680 ? [8, 16, 32, 48] : [4, 8, 16, 32, 48, 64] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAdd ? "ユーザー追加" : "ユーザー追加項目の編集").font(.headline)
            Form {
                LabeledContent("ファイル") { Text(fileName).foregroundStyle(.secondary) }
                TextField("名前", text: $name, prompt: Text("一覧に出す名前"))
                if isAdd {
                    Picker("種類", selection: $kind) {
                        ForEach(UserItem.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } else {
                    LabeledContent("種類") { Text(kind.title).foregroundStyle(.secondary) }
                }
                if kind == .program8800 {
                    Toggle("ROM として取り付ける", isOn: $asROM)
                    if !isHexFile {
                        hexField("配置アドレス(16 進)", $address, example: "0100")
                    }
                    hexField("開始アドレス(16 進)", $start, example: "空なら先頭")
                    Picker("RAM", selection: $ramKB) { ForEach(ramChoices, id: \.self) { Text("\($0) KB").tag($0) } }
                } else if kind == .program680 {
                    Toggle("ROM として起動(モニタなし。RESET ベクタから)", isOn: $asROM)
                    if !asROM {
                        hexField("開始アドレス(16 進)", $start, example: "空なら読み込むだけ")
                    }
                    Picker("RAM", selection: $ramKB) { ForEach(ramChoices, id: \.self) { Text("\($0) KB").tag($0) } }
                }
            }
            .formStyle(.grouped)

            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                Spacer()
                Button("キャンセル") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(isAdd ? "追加" : "保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear(perform: load)
        .onChange(of: kind) { _, new in
            guard isAdd else { return }
            ramKB = new == .program680 ? 48 : 64
        }
    }

    /// 16 進の入力欄。空のときは使い方を薄く表示し、枠をつけてクリックする場所が分かるようにする。
    private func hexField(_ title: String, _ text: Binding<String>, example: String) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(example))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(width: 200)
        }
    }

    private var hint: String {
        switch kind {
        case .disk8800: return "88-DCDD 用のディスクイメージ(337,568 バイト以上)。「起動」は 88dskrom から起動します。書き込みは作業用コピーに入ります。"
        case .disk680: return "68-UIO / FD3712 用のディスクイメージ(256,256 バイト以上)。FLEX や CP/68 と同じ起動 PROM(BOOT.S19)から起動します。"
        case .program8800: return ".hex は各レコードのアドレスへ、.bin は配置アドレスへ読み込みます。開始アドレスにスイッチを合わせて EXAMINE し、実行します。"
        case .program680: return ".s19 を読み込みます。ROM にしない場合は 680b のモニタを起動してから RAM へ読み込み、開始アドレスがあれば J で実行します。"
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .add(let url):
            name = url.deletingPathExtension().lastPathComponent
            kind = UserLibrary.guessKind(of: url) ?? .program8800
            ramKB = kind == .program680 ? 48 : 64
        case .edit(let item):
            name = item.name; kind = item.kind
            address = String(format: "%04X", item.address)
            start = item.start.map { String(format: "%04X", $0) } ?? ""
            asROM = item.asROM; ramKB = item.ramKB
        }
    }

    private func parseHex(_ text: String) -> UInt16?? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "$", with: "")
        if t.isEmpty { return .some(nil) }
        guard let v = UInt16(t, radix: 16) else { return nil }
        return .some(v)
    }

    private func save() {
        var addr: UInt16 = 0
        var startAddr: UInt16?
        if isProgram {
            guard let st = parseHex(start) else { error = "開始アドレスは 16 進で入力してください(例: 0100)"; return }
            startAddr = st
            if kind == .program8800 && !isHexFile {
                guard let a = parseHex(address), let a else { error = "配置アドレスは 16 進で入力してください(例: 0100)"; return }
                addr = a
            }
        }
        do {
            switch mode {
            case .add(let url):
                try model.addUserItem(source: url, name: name, kind: kind, address: addr, start: startAddr, asROM: isProgram && asROM, ramKB: ramKB)
                done("「\(name)」を追加しました")
            case .edit(var item):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { error = "名前を入力してください"; return }
                item.name = trimmed; item.address = addr; item.start = startAddr
                item.asROM = isProgram && asROM; item.ramKB = ramKB
                try model.updateUserItem(item)
                done("「\(trimmed)」を更新しました")
            }
        } catch {
            self.error = "\(error)"
        }
    }
}
