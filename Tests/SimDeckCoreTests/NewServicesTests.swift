import XCTest
@testable import SimDeckCore

final class SnapshotServiceTests: XCTestCase {
    private var root: URL!
    private var avdPath: URL!
    private var service: SnapshotService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotTests-\(UUID().uuidString)")
        avdPath = root.appendingPathComponent("Test.avd")
        let snapshots = avdPath.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(
            at: snapshots.appendingPathComponent("default_boot"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: snapshots.appendingPathComponent("named_a"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: snapshots.appendingPathComponent("named_b"),
            withIntermediateDirectories: true
        )
        service = SnapshotService(
            tools: ToolPaths(
                avdmanager: URL(fileURLWithPath: "/usr/bin/true"),
                emulator: nil,
                adb: nil,
                sdkRoot: nil,
                javaHome: nil
            )
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListExcludesQuickBoot() {
        XCTAssertEqual(service.list(avdPath: avdPath.path), ["named_a", "named_b"])
    }

    func testDeleteStoppedRemovesOnlyNamedSnapshot() throws {
        try service.delete(serial: nil, avdName: "Test", avdPath: avdPath.path, name: "named_a")
        let snapshots = avdPath.appendingPathComponent("snapshots")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshots.appendingPathComponent("named_a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshots.appendingPathComponent("named_b").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshots.appendingPathComponent("default_boot").path))
    }

    func testDeleteRejectsPathTraversal() {
        XCTAssertThrowsError(
            try service.delete(serial: nil, avdName: "Test", avdPath: avdPath.path, name: "../evil")
        ) { error in
            guard case SnapshotError.invalidName = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

final class AVDProvisioningScanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvisioningTests-\(UUID().uuidString)")
        try makeImage("android-34", "google_apis_playstore", "arm64-v8a", file: "system.img")
        try makeImage("android-37.0", "google_apis_playstore_ps16k", "arm64-v8a", file: "ramdisk.img")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("system-images/android-33/empty/arm64-v8a"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScansInstalledImagesAndSortsByAPIDescending() {
        let service = AVDProvisioningService(
            tools: ToolPaths(
                avdmanager: URL(fileURLWithPath: "/usr/bin/true"),
                emulator: nil,
                adb: nil,
                sdkRoot: root,
                javaHome: nil
            )
        )
        let images = service.systemImages()
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].apiLevel, 37)
        XCTAssertEqual(
            images[0].id,
            "system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a"
        )
        XCTAssertEqual(images[1].apiLevel, 34)
    }

    private func makeImage(_ api: String, _ tag: String, _ abi: String, file: String) throws {
        let directory = root.appendingPathComponent("system-images/\(api)/\(tag)/\(abi)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent(file).path,
            contents: Data()
        )
    }
}

final class CommandRunnerFileTests: XCTestCase {
    func testRunToFileWritesStdout() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-to-file-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try CommandRunner.runToFile(
            URL(fileURLWithPath: "/bin/echo"),
            ["hello"],
            output: output
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "hello\n")
    }
}
