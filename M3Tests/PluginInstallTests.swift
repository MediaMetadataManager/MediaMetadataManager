//
//  PluginInstallTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/20/2026.
//
//  Built-in plugins, user-installed plugins and unpacking a picked .zip.
//

import XCTest
@testable import M3

final class PluginInstallTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginInstallTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func url(_ name: String) -> URL {
        return URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
    }

    func testBuiltInPluginsAreListedAndMarked() {
        let result = MetadataPluginLoader.mergeBundles(installed: [],
                                                       builtIn: [url("PlexPlugin.bundle"), url("JellyfinPlugin.bundle")])
        XCTAssertEqual(result.map { $0.name }, ["PlexPlugin", "JellyfinPlugin"])
        XCTAssertTrue(result.allSatisfy { $0.isBuiltIn })
    }

    func testInstalledPluginIsNotMarkedBuiltIn() {
        let result = MetadataPluginLoader.mergeBundles(installed: [url("HelperPlugin.bundle")], builtIn: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isBuiltIn)
    }

    func testInstalledPluginReplacesBuiltInCopyWithTheSameName() {
        let result = MetadataPluginLoader.mergeBundles(installed: [url("PlexPlugin.bundle")],
                                                       builtIn: [url("PlexPlugin.bundle"), url("JellyfinPlugin.bundle")])
        XCTAssertEqual(result.filter { $0.name == "PlexPlugin" }.count, 1)
        XCTAssertFalse(result.first { $0.name == "PlexPlugin" }!.isBuiltIn)
        XCTAssertTrue(result.first { $0.name == "JellyfinPlugin" }!.isBuiltIn)
    }

    func testNameMatchIgnoresCase() {
        let result = MetadataPluginLoader.mergeBundles(installed: [url("plexplugin.bundle")], builtIn: [url("PlexPlugin.bundle")])
        XCTAssertEqual(result.count, 1)
    }

    func testBundleFoundInsideAZipAtTheTopAndOneFolderDown() throws {
        // A zip with a bundle at its top level.
        let top = scratch.appendingPathComponent("top", isDirectory: true)
        try FileManager.default.createDirectory(at: top.appendingPathComponent("A.bundle"), withIntermediateDirectories: true)
        let topZip = scratch.appendingPathComponent("top.zip")
        try zip(folderContents: top, to: topZip)
        let topFound = try MetadataPluginLoader.extractBundles(fromZip: topZip, into: scratch.appendingPathComponent("out1"))
        XCTAssertEqual(topFound.map { $0.lastPathComponent }, ["A.bundle"])

        // A zip made from a folder: the bundle sits one level down.
        let nested = scratch.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("Plugin Files/B.bundle"), withIntermediateDirectories: true)
        let nestedZip = scratch.appendingPathComponent("nested.zip")
        try zip(folderContents: nested, to: nestedZip)
        let nestedFound = try MetadataPluginLoader.extractBundles(fromZip: nestedZip, into: scratch.appendingPathComponent("out2"))
        XCTAssertEqual(nestedFound.map { $0.lastPathComponent }, ["B.bundle"])
    }

    func testZipWithoutABundleGivesNothing() throws {
        let folder = scratch.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let zipURL = scratch.appendingPathComponent("plain.zip")
        try zip(folderContents: folder, to: zipURL)
        let found = try MetadataPluginLoader.extractBundles(fromZip: zipURL, into: scratch.appendingPathComponent("out3"))
        XCTAssertTrue(found.isEmpty)
    }

    func testNotAZipIsReportedAsUnpackFailure() throws {
        let fake = scratch.appendingPathComponent("fake.zip")
        try "not a zip".write(to: fake, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MetadataPluginLoader.extractBundles(fromZip: fake, into: scratch.appendingPathComponent("out4")))
    }

    func testAFolderWithoutAPrincipalClassIsNotAPlugin() throws {
        let bundle = scratch.appendingPathComponent("Empty.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.empty", "CFBundlePackageType": "BNDL"]
        (plist as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        XCTAssertFalse(MetadataPluginLoader.looksLikePlugin(bundle))

        let withClass = scratch.appendingPathComponent("WithClass.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: withClass.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist2: [String: Any] = ["CFBundleIdentifier": "test.class", "CFBundlePackageType": "BNDL", "NSPrincipalClass": "Something"]
        (plist2 as NSDictionary).write(to: withClass.appendingPathComponent("Contents/Info.plist"), atomically: true)
        XCTAssertTrue(MetadataPluginLoader.looksLikePlugin(withClass))
    }

    /// Zips what is inside `folder` (not the folder itself).
    private func zip(folderContents folder: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", folder.path, zipURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
