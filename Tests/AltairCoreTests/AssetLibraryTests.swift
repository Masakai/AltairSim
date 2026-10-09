import XCTest
@testable import AltairCore

final class AssetLibraryTests: XCTestCase {
    private func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("asset-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testCatalogPathsAreUniqueAndFeaturesReferToCatalog() {
        let paths = AssetLibrary.catalog.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
        let names = AssetLibrary.catalog.map { $0.fileName.lowercased() }
        XCTAssertEqual(Set(names).count, names.count, "名前での判別が一意になる")
        let features: [LibraryFeature] = [.basic8K, .cpm22, .cpm3, .zork, .monitor680, .basic680, .flex3, .cpm68,
                                          .cpuTest("TST8080.COM"), .cpuTest("8080PRE.COM"), .cpuTest("CPUTEST.COM"), .cpuTest("8080EXM.COM")]
        for f in features { for p in f.paths { XCTAssertNotNil(AssetLibrary.asset(path: p), "\(f.name): \(p)") } }
    }

    func testMissingFeatureAndMessage() throws {
        let lib = AssetLibrary(root: try makeTemp())
        XCTAssertFalse(lib.isAvailable(.cpm22))
        XCTAssertEqual(lib.missing(.cpm22).map(\.fileName), ["88dskrom.bin", "cpm22b23-56k.dsk"])
        XCTAssertTrue(lib.missingMessage(.cpm22).contains("cpm22b23-56k.dsk"))
        XCTAssertThrowsError(try lib.data("roms/88dskrom.bin"))
    }

    func testImportFilesAndFolderByName() throws {
        let src = try makeTemp()
        let sub = src.appendingPathComponent("download/inner", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // 大文字小文字が違っても名前で判別する。サイズが想定と違うものは警告つきで取り込む
        try Data(count: 256).write(to: sub.appendingPathComponent("88DSKROM.BIN"))
        try Data(count: 10).write(to: src.appendingPathComponent("zork.dsk"))
        try Data(count: 5).write(to: src.appendingPathComponent("unrelated.txt"))

        let lib = AssetLibrary(root: try makeTemp())
        let report = lib.importItems([src])
        XCTAssertEqual(Set(report.imported.map(\.asset.path)), ["roms/88dskrom.bin", "disks/zork.dsk"])
        XCTAssertEqual(report.unrecognized, ["unrelated.txt"])
        XCTAssertEqual(report.sizeWarnings.count, 1)
        XCTAssertTrue(report.sizeWarnings[0].contains("zork.dsk"))
        XCTAssertTrue(lib.has("roms/88dskrom.bin"))
        XCTAssertEqual(try lib.data("roms/88dskrom.bin").count, 256)
        XCTAssertTrue(lib.isAvailable(.zork))
    }

    func testImportAsOtherNameAndRemove() throws {
        let src = try makeTemp()
        let odd = src.appendingPathComponent("CPM22B.IMG")
        try Data(repeating: 7, count: 100).write(to: odd)
        let lib = AssetLibrary(root: try makeTemp())
        let asset = try XCTUnwrap(AssetLibrary.asset(path: "disks/cpm22b23-56k.dsk"))
        XCTAssertEqual(lib.importItems([odd]).unrecognized, ["CPM22B.IMG"])
        try lib.importFile(odd, as: asset)
        XCTAssertEqual(try lib.data(asset.path), Data(repeating: 7, count: 100))
        // 上書き(差し替え)
        try Data(repeating: 9, count: 50).write(to: odd)
        try lib.importFile(odd, as: asset)
        XCTAssertEqual(try lib.data(asset.path).count, 50)
        try lib.remove(asset)
        XCTAssertFalse(lib.has(asset.path))
    }

    func testImportFromTarball() throws {
        // z80pack のアーカイブと同じ構造: <名前>/ と disks/library/<ディスク>.dsk
        let work = try makeTemp()
        let tree = work.appendingPathComponent("tree/disks/library", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data(count: 256_256).write(to: tree.appendingPathComponent("cpm22.dsk"))
        try Data(count: 10).write(to: tree.appendingPathComponent("other.dsk"))
        let tgz = work.appendingPathComponent("cpm22.tgz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", tgz.path, "-C", work.appendingPathComponent("tree").path, "disks"]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let lib = AssetLibrary(root: try makeTemp())
        let report = lib.importItems([tgz])
        XCTAssertEqual(report.imported.map(\.asset.path), ["imsai/disks/cpm22.dsk"])
        XCTAssertEqual(report.unrecognized, ["other.dsk"])
        XCTAssertTrue(report.sizeWarnings.isEmpty)
        XCTAssertTrue(lib.has("imsai/disks/cpm22.dsk"))
        // 壊れたアーカイブは失敗として報告し、他の取り込みを止めない
        let bad = work.appendingPathComponent("bad.tgz")
        try Data([1, 2, 3]).write(to: bad)
        let report2 = lib.importItems([bad])
        XCTAssertEqual(report2.failed.count, 1)
        XCTAssertTrue(report2.imported.isEmpty)
        // 展開用の一時フォルダは残らない
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("altairsim-untar-") } ?? []
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }
}
