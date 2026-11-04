import AltairCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 設定画面。ROM・ディスクイメージ・テストプログラムは同梱していないので、利用者が取得して取り込む。
struct LibrarySettingsView: View {
    @ObservedObject var model: SimulatorModel
    @State private var message = ""
    @State private var dropping = false
    @State private var editor: UserItemEditor.Mode?
    @State private var showCPMBuilder = false

    private var groups: [(name: String, assets: [LibraryAsset])] {
        var order: [String] = []
        for a in AssetLibrary.catalog where !order.contains(a.group) { order.append(a.group) }
        return order.map { g in (g, AssetLibrary.catalog.filter { $0.group == g }) }
    }

    private var presentCount: Int {
        _ = model.libraryRevision
        return AssetLibrary.catalog.filter { model.library.has($0.path) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ROM・ディスクイメージの取り込み").font(.headline)
            Text("これらのファイルはライセンスの都合でアプリに含めていません。各配布元の条件を確認したうえで、ご自身の判断で取得して取り込んでください。取り込んだファイルは下のフォルダにコピーされます。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.library.root.path)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("ファイル・フォルダを取り込み…", action: importMany)
                    .help("複数のファイルや、ファイルの入ったフォルダを選びます。ファイル名で項目を判別します")
                Button("ユーザー追加…", action: addUser)
                    .help("一覧にない ROM・プログラム・ディスクイメージを、名前をつけて追加します")
                Button("CP/M ディスクをつくる…") { showCPMBuilder = true }
                    .help("FORTRAN-80 や COBOL-80 などのファイルを、CP/M 2.2 のディスクイメージ 1 枚にまとめます")
                Button("Finder で開く") { openInFinder() }
                Spacer()
                Text("\(presentCount) / \(AssetLibrary.catalog.count) 件")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }

            List {
                Section("ユーザー追加") {
                    if model.userItems.isEmpty {
                        Text("まだありません。「ユーザー追加…」から、手持ちの ROM・プログラム・ディスクイメージを追加できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.userItems) { item in userRow(item) }
                }
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.assets) { asset in row(asset) }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropping, perform: handleDrop)

            Text(message.isEmpty ? "ファイルやフォルダをこの一覧へドラッグしても取り込めます。" : message)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
        }
        .padding(16)
        .frame(width: 720, height: 700)
        .onAppear { model.reloadUserItems() }
        .sheet(isPresented: $showCPMBuilder) {
            CPMDiskBuilder(model: model) { result in
                showCPMBuilder = false
                if let result { message = result }
            }
        }
        .sheet(item: $editor) { mode in
            UserItemEditor(model: model, mode: mode) { result in
                editor = nil
                if let result { message = result }
            }
        }
    }

    private func userRow(_ item: UserItem) -> some View {
        _ = model.libraryRevision
        let size = (try? FileManager.default.attributesOfItem(atPath: model.userLibrary.fileURL(item).path)[.size] as? Int) ?? nil
        var detail = "\(item.kind.title)  ·  \(item.originalName)"
        if let size { detail += "  ·  \(size.formatted()) バイト" }
        return HStack(spacing: 8) {
            Image(systemName: item.kind.isDisk ? "opticaldiscdrive" : "memorychip")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(item.kind.isDisk ? "起動" : "実行") { model.launchUser(item) }
                .controlSize(.small)
            if item.kind.isDisk {
                Menu("装着") {
                    ForEach(0..<SimulatorModel.visibleDrives, id: \.self) { d in
                        Button("ドライブ \(String(UnicodeScalar(UInt8(65 + d))))") { model.mountUser(item, drive: d) }
                    }
                }
                .controlSize(.small).fixedSize()
                if model.hasUserWorkingCopy(item) {
                    Button("作業コピーを破棄") { model.discardUserWorkingCopy(item) }
                        .controlSize(.small)
                        .help("書き込みを捨てて、追加したときのイメージに戻します")
                }
            }
            Button("編集…") { editor = .edit(item) }.controlSize(.small)
            Button("削除") { model.removeUserItem(item) }.controlSize(.small)
        }
    }

    private func addUser() {
        let panel = NSOpenPanel()
        panel.message = "追加するファイル(.dsk / .hex / .bin / .s19 など)を選択"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editor = .add(url)
    }

    private func row(_ asset: LibraryAsset) -> some View {
        _ = model.libraryRevision
        let present = model.library.has(asset.path)
        return HStack(spacing: 8) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? Color.green : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.title)
                Text(asset.size > 0 ? "\(asset.fileName)  ·  \(asset.size) バイト" : asset.fileName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = URL(string: asset.source) {
                Link("取得元", destination: url).font(.caption)
            }
            Button(present ? "差し替え…" : "取り込み…") { importOne(asset) }
                .controlSize(.small)
            if present {
                Button("削除") { model.removeLibraryAsset(asset) }
                    .controlSize(.small)
            }
        }
    }

    private func importMany() {
        let panel = NSOpenPanel()
        panel.message = "取り込むファイル、またはファイルの入ったフォルダを選択"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        message = model.importLibraryItems(panel.urls).summary
    }

    private func importOne(_ asset: LibraryAsset) {
        let panel = NSOpenPanel()
        panel.message = asset.size > 0 ? "\(asset.title)(\(asset.fileName)、\(asset.size) バイト)にするファイルを選択" : "\(asset.title)(\(asset.fileName))にするファイルを選択"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.library.importFile(url, as: asset)
            model.libraryRevision += 1
            let size = (try? FileManager.default.attributesOfItem(atPath: model.library.url(asset.path).path)[.size] as? Int) ?? nil
            if let size, asset.size > 0, size != asset.size {
                message = "\(asset.fileName) を取り込みました。ただしサイズが想定と違います(\(size) バイト、想定 \(asset.size))"
            } else {
                message = "\(asset.fileName) を取り込みました"
            }
        } catch {
            message = "取り込みに失敗: \(error.localizedDescription)"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            message = model.importLibraryItems(urls).summary
        }
        return true
    }

    private func openInFinder() {
        let root = model.library.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}
