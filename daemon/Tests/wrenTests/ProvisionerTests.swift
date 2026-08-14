import Foundation
import XCTest
@testable import wren

final class ProvisionerTests: XCTestCase {
    func testResourcesURLResolvesCLIThroughInstalledSymlink() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Wren.app")
        let executable = app.appendingPathComponent(
            "Contents/MacOS/wren")
        let resources = app.appendingPathComponent(
            "Contents/Resources")
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: resources,
            withIntermediateDirectories: true)
        try infoPlist().write(
            to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(
            fileManager.createFile(atPath: executable.path, contents: nil))
        let cli = root.appendingPathComponent(".local/bin/wren")
        try fileManager.createDirectory(
            at: cli.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: cli,
            withDestinationURL: executable)
        defer { try? fileManager.removeItem(at: root) }

        let bundle = Bundle(for: ProvisionerTests.self)
        XCTAssertNotEqual(bundle.bundleURL, app)
        XCTAssertEqual(
            WrenPaths.resourcesURL(bundle: bundle, executable: cli),
            resources.standardizedFileURL)
    }

    func testResourcesURLRejectsUnrelatedAppBundleResources() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Other.app")
        let executable = app.appendingPathComponent(
            "Contents/MacOS/wren")
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: app.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true)
        try infoPlist(identifier: "com.example.other").write(
            to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertTrue(
            fileManager.createFile(atPath: executable.path, contents: nil))
        defer { try? fileManager.removeItem(at: root) }

        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(
            WrenPaths.resourcesURL(bundle: bundle, executable: executable),
            executable.deletingLastPathComponent().standardizedFileURL)
    }

    private func infoPlist(
        identifier: String = WrenPaths.bundleIdentifier
    ) throws -> Data {
        let values = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "wren",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .xml,
            options: 0)
    }
}
