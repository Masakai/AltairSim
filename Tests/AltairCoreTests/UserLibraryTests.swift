import XCTest
@testable import AltairCore

final class UserLibraryTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("user-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testGuessKindByExtensionAndSize() throws {
        let d = try temp()
        func make(_ name: String, _ size: Int) throws -> URL {
            let u = d.appendingPathComponent(name); try Data(count: size).write(to: u); return u
        }
        XCTAssertEqual(UserLibrary.guessKind(of: try make("a.dsk", DiskImage.Geometry.mitsDCDD.size)), .disk8800)
        XCTAssertEqual(UserLibrary.guessKind(of: try make("b.dsk", DiskImage.Geometry.ibm3740.size)), .disk680)
        XCTAssertNil(UserLibrary.guessKind(of: try make("c.dsk", 1000)))
        XCTAssertEqual(UserLibrary.guessKind(of: try make("d.hex", 10)), .program8800)
        XCTAssertEqual(UserLibrary.guessKind(of: try make("e.BIN", 10)), .program8800)
        XCTAssertEqual(UserLibrary.guessKind(of: try make("f.S19", 10)), .program680)
        XCTAssertNil(UserLibrary.guessKind(of: try make("g.txt", 10)))
    }

    func testAddPersistsAndRemoves() throws {
        let src = try temp()
        let prog = src.appendingPathComponent("hello.bin")
        try Data([0x3E, 0x01, 0x76]).write(to: prog)
        let root = try temp()
        let ul = UserLibrary(library: AssetLibrary(root: root))
        XCTAssertTrue(ul.items().isEmpty)

        let item = try ul.add(source: prog, name: "  Hello  ", kind: .program8800, address: 0x0100, start: 0x0100, asROM: false, ramKB: 32)
        XCTAssertEqual(item.name, "Hello", "名前の前後の空白は取る")
        XCTAssertEqual(try Data(contentsOf: ul.fileURL(item)), Data([0x3E, 0x01, 0x76]))

        // 別のインスタンスで読み直しても同じ内容(保存されている)
        let again = UserLibrary(library: AssetLibrary(root: root)).items()
        XCTAssertEqual(again, [item])
        XCTAssertEqual(again[0].address, 0x0100)
        XCTAssertEqual(again[0].start, 0x0100)
        XCTAssertEqual(again[0].ramKB, 32)

        var edited = item; edited.name = "Hello2"; edited.start = nil
        try ul.update(edited)
        XCTAssertEqual(ul.items().first?.name, "Hello2")
        XCTAssertNil(ul.items().first?.start)

        try ul.remove(item)
        XCTAssertTrue(ul.items().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ul.fileURL(item).path))
    }

    func testValidation() throws {
        let src = try temp()
        let small = src.appendingPathComponent("small.dsk"); try Data(count: 100).write(to: small)
        let empty = src.appendingPathComponent("empty.bin"); try Data().write(to: empty)
        let ul = UserLibrary(library: AssetLibrary(root: try temp()))
        XCTAssertThrowsError(try ul.add(source: small, name: "x", kind: .disk8800))
        XCTAssertThrowsError(try ul.add(source: small, name: "x", kind: .disk680))
        XCTAssertThrowsError(try ul.add(source: empty, name: "x", kind: .program8800))
        XCTAssertThrowsError(try ul.add(source: small, name: "   ", kind: .program8800))
        XCTAssertTrue(ul.items().isEmpty, "失敗したものは登録されない")
        let files = try? FileManager.default.contentsOfDirectory(atPath: ul.library.url("user/files").path)
        XCTAssertTrue((files ?? []).isEmpty, "失敗したときにファイルが残らない")
    }

    func testDiskKindsAcceptRealSizes() throws {
        let src = try temp()
        let d = src.appendingPathComponent("x.dsk")
        try Data(count: DiskImage.Geometry.ibm3740.size).write(to: d)
        let ul = UserLibrary(library: AssetLibrary(root: try temp()))
        let item = try ul.add(source: d, name: "680 disk", kind: .disk680)
        XCTAssertNoThrow(try DiskImage(contentsOf: ul.fileURL(item), geometry: .ibm3740))
    }
}
