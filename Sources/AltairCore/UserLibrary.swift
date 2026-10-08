import Foundation

/// 利用者が自由に追加する項目(別のディスクイメージ、ROM、プログラム)。
/// ファイルは `library/user/files/` にコピーし、一覧は `library/user/items.json` に保存する。
public struct UserItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case disk8800, disk680, program8800, program680

        public var title: String {
            switch self {
            case .disk8800: return "Altair 8800 ディスク"
            case .disk680: return "Altair 680b ディスク"
            case .program8800: return "Altair 8800 プログラム/ROM"
            case .program680: return "Altair 680b プログラム/ROM"
            }
        }
        public var isDisk: Bool { self == .disk8800 || self == .disk680 }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// ライブラリのルートからの相対パス(`user/files/<id>-<元のファイル名>`)
    public var file: String
    public var originalName: String
    /// 8800 のバイナリ(.bin)を置くアドレス。.hex は各レコードのアドレスを使う
    public var address: UInt16
    /// 実行を始めるアドレス。nil のとき 8800 は読み込み先頭、680b のプログラムは読み込むだけ(ROM は RESET ベクタ)
    public var start: UInt16?
    /// true: ROM として取り付ける(8800)、モニタなしで RESET ベクタから起動する(680b)
    public var asROM: Bool
    /// RAM の量(KB)
    public var ramKB: Int

    public init(id: UUID = UUID(), name: String, kind: Kind, file: String, originalName: String,
                address: UInt16 = 0, start: UInt16? = nil, asROM: Bool = false, ramKB: Int = 64) {
        self.id = id; self.name = name; self.kind = kind; self.file = file; self.originalName = originalName
        self.address = address; self.start = start; self.asROM = asROM; self.ramKB = ramKB
    }
}

public enum UserLibraryError: Error, CustomStringConvertible {
    case tooSmall(kind: UserItem.Kind, size: Int, need: Int)
    case emptyName
    case unreadable(String)

    public var description: String {
        switch self {
        case .tooSmall(let kind, let size, let need): return "\(kind.title) のイメージは \(need) バイト以上が必要です(このファイルは \(size) バイト)"
        case .emptyName: return "名前を入力してください"
        case .unreadable(let s): return "ファイルを読めません: \(s)"
        }
    }
}

public final class UserLibrary {
    public let library: AssetLibrary

    public init(library: AssetLibrary) { self.library = library }

    private var manifestURL: URL { library.url("user/items.json") }

    public func fileURL(_ item: UserItem) -> URL { library.url(item.file) }

    public func items() -> [UserItem] {
        guard let data = try? Data(contentsOf: manifestURL),
              let list = try? JSONDecoder().decode([UserItem].self, from: data) else { return [] }
        return list
    }

    private func save(_ items: [UserItem]) throws {
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(items).write(to: manifestURL, options: .atomic)
    }

    /// ファイルの拡張子とサイズから、種類の見当をつける(利用者が後で変えられる)。
    public static func guessKind(of url: URL) -> UserItem.Kind? {
        let ext = url.pathExtension.lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        switch ext {
        case "dsk", "img":
            guard let size else { return nil }
            if size >= DiskImage.Geometry.mitsDCDD.size { return .disk8800 }
            if size >= DiskImage.Geometry.ibm3740.size { return .disk680 }
            return nil
        case "hex", "bin", "com", "rom": return .program8800
        case "s19", "s28", "srec", "mot", "sx": return .program680
        default: return nil
        }
    }

    /// ファイルをライブラリへコピーして登録する。ディスクはサイズを確認する。
    @discardableResult
    public func add(source: URL, name: String, kind: UserItem.Kind, address: UInt16 = 0, start: UInt16? = nil,
                    asROM: Bool = false, ramKB: Int = 64) throws -> UserItem {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw UserLibraryError.emptyName }
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int) ?? nil else {
            throw UserLibraryError.unreadable(source.lastPathComponent)
        }
        switch kind {
        case .disk8800:
            let need = DiskImage.Geometry.mitsDCDD.size
            guard size >= need else { throw UserLibraryError.tooSmall(kind: kind, size: size, need: need) }
        case .disk680:
            let need = DiskImage.Geometry.ibm3740.size
            guard size >= need else { throw UserLibraryError.tooSmall(kind: kind, size: size, need: need) }
        case .program8800, .program680:
            guard size > 0 else { throw UserLibraryError.unreadable("\(source.lastPathComponent)(空のファイル)") }
        }
        let id = UUID()
        let rel = "user/files/\(id.uuidString)-\(source.lastPathComponent)"
        let dest = library.url(rel)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: dest)
        let item = UserItem(id: id, name: trimmed, kind: kind, file: rel, originalName: source.lastPathComponent,
                            address: address, start: start, asROM: asROM, ramKB: ramKB)
        var list = items()
        list.append(item)
        do { try save(list) } catch { try? fm.removeItem(at: dest); throw error }
        return item
    }

    /// 項目の設定(名前、アドレスなど)を更新する。ファイルは変えない。
    public func update(_ item: UserItem) throws {
        var list = items()
        guard let i = list.firstIndex(where: { $0.id == item.id }) else { return }
        list[i] = item
        try save(list)
    }

    public func remove(_ item: UserItem) throws {
        var list = items()
        list.removeAll { $0.id == item.id }
        try save(list)
        let url = fileURL(item)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
