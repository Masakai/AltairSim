import AltairCore
import AppKit
import SwiftUI

/// 「CP/M ディスクをつくる」シート。FORTRAN-80 や COBOL-80 などのファイルを、Altair 8800 用の CP/M 2.2 ディスクイメージ 1 枚にまとめて、
/// ユーザー追加の項目として登録する。ドライブ B に装着して、ドライブ A の CP/M 2.2 から使う。
struct CPMDiskBuilder: View {
    @ObservedObject var model: SimulatorModel
    let done: (String?) -> Void

    private struct Source: Identifiable {
        let id = UUID()
        let name: String       // ディスクに入るときの名前(大文字)
        let url: URL
        let size: Int
    }

    private static let fortranFiles = ["F80.COM", "M80.COM", "L80.COM", "LIB.COM", "CREF80.COM", "FORLIB.REL"]
    private static let cobolFiles = ["COBOL.COM", "COBOL1.OVR", "COBOL2.OVR", "COBOL3.OVR", "COBOL4.OVR", "RUNCOB.COM", "COBLIB.REL", "COBLBX.REL", "L80.COM", "M80.COM"]

    @State private var diskName = "FORTRAN-80"
    @State private var keepOriginalFiles = false
    @State private var baseFile: URL?
    @State private var sources: [Source] = []
    @State private var error = ""

    private var totalKB: Int { (sources.reduce(0) { $0 + (($1.size + 2047) / 2048) * 2 }) }
    private let capacityKB = 296

    private var libraryBase: URL { model.library.url("disks/cpm22b23-56k.dsk") }
    private var base: URL? { baseFile ?? (model.library.has("disks/cpm22b23-56k.dsk") ? libraryBase : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CP/M ディスクをつくる").font(.headline)
            Text("ファイルを Altair 8800 用の CP/M 2.2 ディスク 1 枚にまとめます。つくったディスクは、ユーザー追加に登録されます。ドライブ B に装着して、ドライブ A の CP/M 2.2 から使います。")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("名前", text: $diskName, prompt: Text("一覧に出す名前"))
                LabeledContent("もとのディスク") {
                    HStack {
                        Text(base?.lastPathComponent ?? "なし(CP/M 2.2b を取り込むか、ファイルを選んでください)")
                            .foregroundStyle(base == nil ? Color.red : Color.secondary)
                        Button("選ぶ…", action: chooseBase).controlSize(.small)
                    }
                }
                Toggle("もとのディスクにあるファイルを残す", isOn: $keepOriginalFiles)
                    .help("オフ: ファイルを全部消して、システム領域だけを引き継いだ空のディスクにします")
            }
            .formStyle(.grouped)
            .frame(height: 170)

            HStack {
                Button("FORTRAN-80 一式") { addLibrary(Self.fortranFiles, label: "FORTRAN-80") }
                    .help("F80、M80、L80、LIB、CREF80、FORLIB.REL")
                Button("COBOL-80 一式") { addLibrary(Self.cobolFiles, label: "COBOL-80") }
                    .help("COBOL.COM とオーバーレイ、RUNCOB、ライブラリ、M80、L80")
                Button("ファイルを追加…", action: addFiles)
                Spacer()
                Text("\(totalKB) KB / \(capacityKB) KB")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(totalKB > capacityKB ? Color.red : Color.secondary)
            }

            List {
                if sources.isEmpty {
                    Text("まだファイルがありません。一式のボタンか「ファイルを追加…」で入れてください(一式は、設定画面の一覧で取り込んでおく必要があります)。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(sources) { s in
                    HStack {
                        Text(s.name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text("\(s.size) バイト").font(.caption).foregroundStyle(.secondary)
                        Button("外す") { sources.removeAll { $0.id == s.id } }.controlSize(.small)
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 160)

            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("キャンセル") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("つくる", action: build)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sources.isEmpty || base == nil || diskName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 560)
    }

    private func chooseBase() {
        let panel = NSOpenPanel()
        panel.message = "もとにする Altair 8800 用 CP/M 2.2 のディスクイメージ(.dsk)を選択"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        baseFile = url
    }

    private func add(_ name: String, url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil else { return }
        let upper = name.uppercased()
        sources.removeAll { $0.name == upper }
        sources.append(Source(name: upper, url: url, size: size))
    }

    private func addLibrary(_ names: [String], label: String) {
        let paths = names.map { "cpm/lang/\($0)" }
        let missing = paths.filter { !model.library.has($0) }
        if !missing.isEmpty {
            error = "\(label) のファイルが取り込まれていません: " + missing.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
                + "(設定画面の一覧の「CP/M 言語系の単体ファイル」から取り込めます)"
        } else {
            error = ""
        }
        for p in paths where model.library.has(p) { add((p as NSString).lastPathComponent, url: model.library.url(p)) }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.message = "ディスクに入れるファイルを選択(CP/M のファイル名は 8 文字+3 文字の英数字)"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK else { return }
        error = ""
        for u in panel.urls { add(u.lastPathComponent, url: u) }
    }

    private func build() {
        guard let base else { return }
        error = ""
        do {
            let disk = try CPMDisk(contentsOf: base)
            if !keepOriginalFiles { disk.eraseAllFiles() }
            for s in sources { try disk.add(name: s.name, data: [UInt8](try Data(contentsOf: s.url))) }
            let stem = diskName.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }.map(String.init).joined()
            let tmpFolder = FileManager.default.temporaryDirectory.appendingPathComponent("altairsim-cpm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpFolder) }
            let tmp = tmpFolder.appendingPathComponent((stem.isEmpty ? "cpm-disk" : stem) + ".dsk")
            try disk.write(to: tmp)
            try model.addUserItem(source: tmp, name: diskName, kind: .disk8800, address: 0, start: nil, asROM: false, ramKB: 64)
            done("「\(diskName)」をつくりました(\(sources.count) ファイル、空き \(disk.freeKB) KB)。ユーザー追加の一覧から、ドライブ B に装着できます")
        } catch {
            self.error = "\(error)"
        }
    }
}
