import Foundation

/// 利用者が自分で用意する ROM・ディスクイメージ・テストプログラムの 1 ファイル。
/// これらは配布元のライセンスの都合でアプリには同梱せず、利用者が取得して取り込む。
public struct LibraryAsset: Identifiable, Hashable, Sendable {
    /// ライブラリのルートからの相対パス(例: `roms/88dskrom.bin`)
    public let path: String
    public let title: String
    public let group: String
    /// 想定しているファイルサイズ(取り込み時の確認用。違っても取り込みは止めない)
    public let size: Int
    /// 取得元(ページの URL)
    public let source: String

    public var id: String { path }
    public var fileName: String { (path as NSString).lastPathComponent }
}

/// 機能ごとに必要なファイルの組。
public struct LibraryFeature: Sendable {
    public let name: String
    public let paths: [String]

    public init(name: String, paths: [String]) {
        self.name = name
        self.paths = paths
    }

    public static let basic8K = LibraryFeature(name: "BASIC 8K", paths: ["roms/8kBas_e0.bin", "roms/8kBas_e8.bin", "roms/8kBas_f0.bin", "roms/8kBas_f8.bin"])
    public static let cpm22 = LibraryFeature(name: "CP/M 2.2", paths: ["roms/88dskrom.bin", "disks/cpm22b23-56k.dsk"])
    public static let cpm3 = LibraryFeature(name: "CP/M 3", paths: ["roms/88dskrom.bin", "disks/cpm3_v1.0_56K_disk1.dsk", "disks/cpm3_v1.0_56k_disk2.dsk"])
    public static let zork = LibraryFeature(name: "Zork", paths: ["roms/88dskrom.bin", "disks/zork.dsk"])
    public static func cpuTest(_ file: String) -> LibraryFeature { LibraryFeature(name: "8080 テスト(\(file))", paths: ["cpu_tests/\(file)"]) }
    public static let monitor680 = LibraryFeature(name: "680b モニタ", paths: ["altair680/monitor/MON680.S19"])
    public static let basic680 = LibraryFeature(name: "680b BASIC", paths: ["altair680/monitor/MON680.S19", "altair680/basic/paper-basic-v1.1-r3.2.s19"])
    public static let flex3 = LibraryFeature(name: "FLEX 3.0", paths: ["altair680/monitor/SWIMON.S19", "altair680/boot/BOOT.S19", "altair680/disks/flex3-680.dsk"])
    public static let cpm68 = LibraryFeature(name: "CP/68", paths: ["altair680/monitor/SWIMON.S19", "altair680/boot/BOOT.S19", "altair680/disks/cp68-altair680.dsk"])
    public static let imsaiCPM = LibraryFeature(name: "IMSAI CP/M 1.31", paths: ["imsai/disks/imsai-cpm13.dsk"])
}

public struct LibraryImportReport {
    /// 取り込んだもの(コピー元のファイル名つき)
    public var imported: [(asset: LibraryAsset, from: String)] = []
    /// 想定のサイズと違うが取り込んだもの
    public var sizeWarnings: [String] = []
    /// ファイル名がカタログにないもの
    public var unrecognized: [String] = []
    /// コピーに失敗したもの
    public var failed: [String] = []

    public var summary: String {
        var parts: [String] = []
        if !imported.isEmpty { parts.append("\(imported.count) 件を取り込みました") }
        if !sizeWarnings.isEmpty { parts.append("サイズが想定と違う: " + sizeWarnings.joined(separator: "、")) }
        if !unrecognized.isEmpty { parts.append("対象外(名前が一覧にない。「ユーザー追加…」で登録できます): " + unrecognized.joined(separator: "、")) }
        if !failed.isEmpty { parts.append("失敗: " + failed.joined(separator: "、")) }
        return parts.isEmpty ? "取り込むファイルがありませんでした" : parts.joined(separator: "。")
    }
}

public enum AssetLibraryError: Error, CustomStringConvertible {
    case missing(LibraryAsset)
    public var description: String {
        switch self {
        case .missing(let a): return "\(a.fileName) がライブラリにありません(\(a.title)。取得元: \(a.source))"
        }
    }
}

public final class AssetLibrary: @unchecked Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// 既定の置き場所。環境変数 `ALTAIR_LIBRARY` があればそれを使う(テスト用)。
    public static var defaultRoot: URL {
        if let env = ProcessInfo.processInfo.environment["ALTAIR_LIBRARY"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appendingPathComponent("AltairSim/library", isDirectory: true)
    }

    public static var shared: AssetLibrary { AssetLibrary(root: defaultRoot) }

    // MARK: カタログ

    private static let altairclone = "https://altairclone.com/downloads"
    private static let deramp680 = "https://deramp.com/downloads/altair/software/altair_680"

    public static let catalog: [LibraryAsset] = {
        func a(_ path: String, _ title: String, _ group: String, _ size: Int, _ source: String) -> LibraryAsset {
            LibraryAsset(path: path, title: title, group: group, size: size, source: source)
        }
        let bas = "\(altairclone)/roms/8K%20BASIC/"
        let g8 = "Altair 8800 ROM"
        let gd = "Altair 8800 ディスク"
        let gt = "8080 命令テスト"
        let g6 = "Altair 680b"
        let cpu = "https://github.com/superzazu/8080/tree/master/cpu_tests"
        let gi = "IMSAI 8080 ディスク"
        let gl = "Altair 8800 言語系のディスク"
        let gf = "CP/M 言語系の単体ファイル(ディスクにまとめて使う)"
        let fortranSource = "\(altairclone)/cpm/CPM%202.2/FORTRAN-80%20v3.44/"
        let cobolSource = "\(altairclone)/cpm/CPM%202.2/COBOL-80/"
        let imsaiDeramp = "https://deramp.com/downloads/mfe_archive/010-S100%20Computers%20and%20Boards/00-Imsai/40-Imsai%20Software/IMSAI%20CPM/imsai-cpm13/disks/library/imsai-cpm13.dsk"
        let imsaiZ80pack = "https://www.icl1900.co.uk/unix4fun/z80pack/ftp/imsai"
        let imsaiFormatCOM = "https://deramp.com/downloads/mfe_archive/010-S100%20Computers%20and%20Boards/00-Imsai/40-Imsai%20Software/IMDOS/FORMAT.COM"
        return [
            a("roms/8kBas_e0.bin", "Altair BASIC 8K ROM(E000h)", g8, 2048, bas),
            a("roms/8kBas_e8.bin", "Altair BASIC 8K ROM(E800h)", g8, 2048, bas),
            a("roms/8kBas_f0.bin", "Altair BASIC 8K ROM(F000h)", g8, 2048, bas),
            a("roms/8kBas_f8.bin", "Altair BASIC 8K ROM(F800h)", g8, 2048, bas),
            a("roms/88dskrom.bin", "ディスクブートローダ(FF00h)", g8, 256, "https://github.com/tommojphillips/Altair8800/tree/master/roms"),
            a("disks/cpm22b23-56k.dsk", "CP/M 2.2b(56K)", gd, 337_664, "\(altairclone)/cpm/CPM%202.2/CPM%202.2B/"),
            a("disks/cpm3_v1.0_56K_disk1.dsk", "CP/M 3 ディスク 1(システム)", gd, 337_664, "\(altairclone)/cpm/CPM%203.0/"),
            a("disks/cpm3_v1.0_56k_disk2.dsk", "CP/M 3 ディスク 2(ユーティリティ)", gd, 337_664, "\(altairclone)/cpm/CPM%203.0/"),
            a("disks/zork.dsk", "Zork(Burcon 56K CP/M 2.2)", gd, 337_568, "\(altairclone)/cpm/CPM%202.2/Zork/"),
            a("cpu_tests/TST8080.COM", "TST8080(CPU 診断)", gt, 1536, cpu),
            a("cpu_tests/8080PRE.COM", "8080PRE(前段テスト)", gt, 1024, cpu),
            a("cpu_tests/CPUTEST.COM", "CPUTEST(SuperSoft)", gt, 19_200, cpu),
            a("cpu_tests/8080EXM.COM", "8080EXM(全命令の CRC 照合)", gt, 4608, cpu),
            a("altair680/monitor/MON680.S19", "680b PROM モニタ(ACIA 版)", g6, 632, "\(deramp680)/PROM%20Monitor/"),
            a("altair680/monitor/SWIMON.S19", "680b SWI 版モニタ(ディスク OS 用)", g6, 632, "\(deramp680)/PROM%20Monitor/"),
            a("altair680/basic/paper-basic-v1.1-r3.2.s19", "680 BASIC V1.1 R3.2(紙テープ版)", g6, 18_760, "\(deramp680)/BASIC/"),
            a("altair680/boot/BOOT.S19", "ディスク起動 PROM(FC00h)", g6, 596, "\(deramp680)/FLEX%201.0/BOOT.S19"),
            a("altair680/disks/flex3-680.dsk", "FLEX 3.0(680b)", g6, 256_256, "\(deramp680)/FLEX%203.0/"),
            a("altair680/disks/cp68-altair680.dsk", "CP/68(680b)", g6, 256_256, "\(deramp680)/CP68/"),
            // IMSAI 8080(FIF、IBM 3740 形式)。CP/M 1.31 は deramp.com、そのほかは z80pack のミラー(.tgz の中の disks/library/ にある)
            a("imsai/disks/imsai-cpm13.dsk", "IMSAI CP/M 1.31(16K)", gi, 256_256, imsaiDeramp),
            a("imsai/disks/um-cpm13.dsk", "CP/M 1.33(52K、Udo Munk による復元)", gi, 256_256, "\(imsaiZ80pack)/um-cpm13.tgz"),
            a("imsai/disks/cpm22.dsk", "CP/M 2.2(54K)", gi, 256_256, "\(imsaiZ80pack)/cpm22.tgz"),
            a("imsai/disks/fig80.dsk", "Fig-Forth 8080(CP/M 2.2 上)", gi, 256_256, "\(imsaiZ80pack)/fig80.tgz"),
            a("imsai/disks/imdos202.dsk", "IMDOS 2.02(54K)", gi, 256_256, "\(imsaiZ80pack)/imdos202.tgz"),
            a("imsai/disks/imdos205r0-1.dsk", "IMDOS 2.05 rev.0 ディスク 1(54K)", gi, 256_256, "\(imsaiZ80pack)/imdos205r0.tgz"),
            a("imsai/disks/imdos205r0-2.dsk", "IMDOS 2.05 rev.0 ディスク 2", gi, 256_256, "\(imsaiZ80pack)/imdos205r0.tgz"),
            a("imsai/disks/imdos205r1-maslin.dsk", "IMDOS 2.05 rev.1(16K、Maslin 版)", gi, 256_256, "\(imsaiZ80pack)/imdos205r1-maslin.tgz"),
            a("imsai/disks/imdos205r1-peters.dsk", "IMDOS 2.05 rev.1(16K、Peters 版)", gi, 256_256, "\(imsaiZ80pack)/imdos205r1-peters.tgz"),
            a("imsai/cpm/FORMAT.COM", "IMDOS の FORMAT.COM(IMSAI FORMATTER-INITIALIZER 2.05)", gi, 3712, imsaiFormatCOM),
            // 言語系のディスク(altairclone.com)
            a("disks/bascom.dsk", "Microsoft BASIC コンパイラ 5.3a(CP/M 2.2)", gl, 337_664, "\(altairclone)/cpm/CPM%202.2/BASIC%20Compiler%205.3a/"),
            a("disks/bdsc.dsk", "BDS C コンパイラ(CP/M 2.2)", gl, 337_664, "\(altairclone)/cpm/CPM%202.2/BDS%20C%20Compiler/"),
            a("disks/DOS 1.0 and Fortran 2.8.dsk", "Altair DOS 1.0 と FORTRAN 2.8(Altair DOS 用、未検証)", gl, 337_664, "\(altairclone)/altair_dos/"),
            a("disks/Fortran 2-8.dsk", "Altair FORTRAN 2.8(Altair DOS 用、未検証)", gl, 337_664, "\(altairclone)/altair_dos/"),
            // 単体のファイル(「CP/M ディスクをつくる…」で 1 枚のディスクにまとめる。サイズは配布元の表記が丸めてあるので、確認しない)
            a("cpm/lang/F80.COM", "FORTRAN-80 コンパイラ(F80.COM、v3.44)", gf, 0, fortranSource),
            a("cpm/lang/FORLIB.REL", "FORTRAN-80 のライブラリ(FORLIB.REL)", gf, 0, fortranSource),
            a("cpm/lang/M80.COM", "MACRO-80 アセンブラ(M80.COM)", gf, 0, fortranSource),
            a("cpm/lang/L80.COM", "LINK-80 リンカ(L80.COM)", gf, 0, fortranSource),
            a("cpm/lang/LIB.COM", "LIB-80 ライブラリアン(LIB.COM)", gf, 0, fortranSource),
            a("cpm/lang/CREF80.COM", "CREF-80(CREF80.COM)", gf, 0, fortranSource),
            a("cpm/lang/COBOL.COM", "COBOL-80 コンパイラ(COBOL.COM)", gf, 0, cobolSource),
            a("cpm/lang/COBOL1.OVR", "COBOL-80 のオーバーレイ 1(COBOL1.OVR)", gf, 0, cobolSource),
            a("cpm/lang/COBOL2.OVR", "COBOL-80 のオーバーレイ 2(COBOL2.OVR)", gf, 0, cobolSource),
            a("cpm/lang/COBOL3.OVR", "COBOL-80 のオーバーレイ 3(COBOL3.OVR)", gf, 0, cobolSource),
            a("cpm/lang/COBOL4.OVR", "COBOL-80 のオーバーレイ 4(COBOL4.OVR)", gf, 0, cobolSource),
            a("cpm/lang/COBLIB.REL", "COBOL-80 のライブラリ(COBLIB.REL)", gf, 0, cobolSource),
            a("cpm/lang/COBLBX.REL", "COBOL-80 のライブラリ(COBLBX.REL)", gf, 0, cobolSource),
            a("cpm/lang/RUNCOB.COM", "COBOL-80 の実行環境(RUNCOB.COM)", gf, 0, cobolSource),
        ]
    }()

    public static func asset(path: String) -> LibraryAsset? { catalog.first { $0.path == path } }

    // MARK: 参照

    public func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    public func has(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    /// ライブラリにあるファイルの内容。なければ取得元つきのエラーを投げる。
    public func data(_ path: String) throws -> Data {
        guard has(path) else {
            throw AssetLibraryError.missing(Self.asset(path: path) ?? LibraryAsset(path: path, title: path, group: "", size: 0, source: "(不明)"))
        }
        return try Data(contentsOf: url(path))
    }

    public func missing(_ feature: LibraryFeature) -> [LibraryAsset] {
        feature.paths.filter { !has($0) }.compactMap(Self.asset(path:))
    }

    public func isAvailable(_ feature: LibraryFeature) -> Bool { missing(feature).isEmpty }

    /// 足りないときに端末下の状態欄へ出す案内文。
    public func missingMessage(_ feature: LibraryFeature) -> String {
        let names = missing(feature).map(\.fileName).joined(separator: "、")
        return "\(feature.name) に必要なファイルがありません: \(names)(メニュー「AltairSim ▸ 設定…」から取り込めます)"
    }

    // MARK: 取り込み

    /// ファイルまたはフォルダ(中を再帰的に探す)を、名前でカタログと照合してライブラリへコピーする。
    public func importItems(_ urls: [URL]) -> LibraryImportReport {
        var report = LibraryImportReport()
        let fm = FileManager.default
        var files: [URL] = []
        var temporaryFolders: [URL] = []
        defer { for t in temporaryFolders { try? fm.removeItem(at: t) } }
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { report.failed.append(u.lastPathComponent); continue }
            let lower = u.lastPathComponent.lowercased()
            if !isDir.boolValue, lower.hasSuffix(".tgz") || lower.hasSuffix(".tar.gz") {
                // z80pack のミラーなどは、ディスクイメージを .tgz にまとめて配っている。一時フォルダへ展開して、中を調べる
                guard let folder = Self.extractTarball(u) else { report.failed.append("\(u.lastPathComponent)(展開できません)"); continue }
                temporaryFolders.append(folder)
                if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        files.append(f)
                    }
                }
                continue
            }
            if isDir.boolValue {
                if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        files.append(f)
                    }
                }
            } else {
                files.append(u)
            }
        }
        var seen = Set<String>()
        for f in files {
            let key = f.lastPathComponent.lowercased()
            guard let asset = Self.catalog.first(where: { $0.fileName.lowercased() == key }) else {
                report.unrecognized.append(f.lastPathComponent)
                continue
            }
            guard seen.insert(asset.path).inserted else { continue }  // 同じ名前が複数あれば最初のものだけ
            do {
                let dest = url(asset.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: f, to: dest)
                report.imported.append((asset, f.lastPathComponent))
                let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? nil
                if let size, asset.size > 0, size != asset.size {
                    report.sizeWarnings.append("\(asset.fileName)(\(size) バイト、想定 \(asset.size))")
                }
            } catch {
                report.failed.append("\(f.lastPathComponent)(\(error.localizedDescription))")
            }
        }
        return report
    }

    /// .tgz / .tar.gz を一時フォルダへ展開する(失敗したら nil)。呼んだ側が、使い終わったフォルダを消す。
    static func extractTarball(_ archive: URL) -> URL? {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent("altairsim-untar-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -x 展開、-z gzip、-f ファイル、-C 展開先。絶対パスや「..」を含むエントリは、macOS の tar が既定で拒否する
        p.arguments = ["-xzf", archive.path, "-C", dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { try? fm.removeItem(at: dest); return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { try? fm.removeItem(at: dest); return nil }
        return dest
    }

    /// 名前が違っていても、利用者が指定した項目としてコピーする(取得元のファイル名が配布物と違うとき用)。
    public func importFile(_ source: URL, as asset: LibraryAsset) throws {
        let fm = FileManager.default
        let dest = url(asset.path)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
    }

    /// ライブラリから 1 件削除する(作業用コピーは消さない)。
    public func remove(_ asset: LibraryAsset) throws {
        if has(asset.path) { try FileManager.default.removeItem(at: url(asset.path)) }
    }
}
