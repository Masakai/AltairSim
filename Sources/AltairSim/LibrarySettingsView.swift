import AltairCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 設定画面。ROM・ディスクイメージ・テストプログラムは同梱していないので、利用者が取得して取り込む。
struct LibrarySettingsView: View {
    @ObservedObject var model: SimulatorModel
    @State private var message = ""
    @State private var dropping = false

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
                Button("Finder で開く") { openInFinder() }
                Spacer()
                Text("\(presentCount) / \(AssetLibrary.catalog.count) 件")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }

            List {
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
        .frame(width: 720, height: 640)
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
                Text("\(asset.fileName)  ·  \(asset.size) バイト")
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
        panel.message = "\(asset.title)(\(asset.fileName)、\(asset.size) バイト)にするファイルを選択"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.library.importFile(url, as: asset)
            model.libraryRevision += 1
            let size = (try? FileManager.default.attributesOfItem(atPath: model.library.url(asset.path).path)[.size] as? Int) ?? nil
            if let size, size != asset.size {
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
