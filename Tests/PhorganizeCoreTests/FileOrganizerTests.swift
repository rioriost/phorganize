import XCTest
@testable import PhorganizeCore

final class FileOrganizerTests: XCTestCase {
    func testPlanFindsSupportedFilesRecursivelyAndReportsUnsupportedFiles() async throws {
        let source = try makeTemporaryDirectory()
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.appendingPathComponent("root.jpg").path, contents: Data("root".utf8))
        FileManager.default.createFile(atPath: nested.appendingPathComponent("child.MP4").path, contents: Data("movie".utf8))
        FileManager.default.createFile(atPath: source.appendingPathComponent("ignored.txt").path, contents: Data("ignored".utf8))

        let plan = try await FileOrganizer().plan(
            sourceURL: source,
            destinationURL: destination,
            options: OrganizationOptions(recursive: true, includeCameraFolder: false, metadataConcurrency: 2)
        )

        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(plan.skippedUnsupportedCount, 1)
        XCTAssertEqual(plan.skippedUnsupportedFiles.map(\.lastPathComponent), ["ignored.txt"])
        XCTAssertTrue(plan.files.allSatisfy { $0.targetURL.path.contains("/\(currentYear())/") })
    }

    func testPlanNonRecursiveIgnoresNestedFiles() async throws {
        let source = try makeTemporaryDirectory()
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.appendingPathComponent("root.jpg").path, contents: Data("root".utf8))
        FileManager.default.createFile(atPath: nested.appendingPathComponent("child.jpg").path, contents: Data("child".utf8))

        let plan = try await FileOrganizer().plan(
            sourceURL: source,
            destinationURL: destination,
            options: OrganizationOptions(recursive: false, includeCameraFolder: false)
        )

        XCTAssertEqual(plan.files.map { $0.sourceURL.lastPathComponent }, ["root.jpg"])
    }

    func testPlanSkipsExistingIdenticalFileUsingHash() async throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let sourceFile = source.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: sourceFile.path, contents: Data("same-content".utf8))
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: sourceFile.path)
        let existingTarget = destination
            .appendingPathComponent("2025/02/06/(null)", isDirectory: true)
            .appendingPathComponent("20250206-091616.jpg")
        try FileManager.default.createDirectory(
            at: existingTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: existingTarget.path, contents: Data("same-content".utf8))

        let plan = try await FileOrganizer().plan(
            sourceURL: source,
            destinationURL: destination,
            options: OrganizationOptions(
                includeCameraFolder: true,
                timezoneIdentifier: "UTC"
            )
        )

        XCTAssertTrue(plan.files.isEmpty)
        XCTAssertEqual(plan.existingIdenticalFiles.map(\.sourceURL.lastPathComponent), ["photo.jpg"])
        XCTAssertEqual(plan.existingIdenticalFiles.map(\.existingTargetURL), [existingTarget])
    }

    func testPlanSequencesExistingDifferentFileUsingHash() async throws {
        let source = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let sourceFile = source.appendingPathComponent("photo.jpg")
        FileManager.default.createFile(atPath: sourceFile.path, contents: Data("new-content".utf8))
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: sourceFile.path)
        let existingTarget = destination
            .appendingPathComponent("2025/02/06/(null)", isDirectory: true)
            .appendingPathComponent("20250206-091616.jpg")
        try FileManager.default.createDirectory(
            at: existingTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: existingTarget.path, contents: Data("old-content".utf8))

        let plan = try await FileOrganizer().plan(
            sourceURL: source,
            destinationURL: destination,
            options: OrganizationOptions(
                includeCameraFolder: true,
                timezoneIdentifier: "UTC"
            )
        )

        XCTAssertTrue(plan.existingIdenticalFiles.isEmpty)
        XCTAssertEqual(plan.files.map(\.targetURL.lastPathComponent), ["20250206-091616_1.jpg"])
    }

    func testPlanThrowsForMissingSourceAndMissingDestinationParent() async throws {
        let organizer = FileOrganizer()
        let missingSource = URL(fileURLWithPath: "/tmp/phorganize-\(UUID().uuidString)")
        let missingDestination = URL(fileURLWithPath: "/tmp/phorganize-\(UUID().uuidString)/out")

        do {
            _ = try await organizer.plan(
                sourceURL: missingSource,
                destinationURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                options: .default
            )
            XCTFail("Expected missing source to throw")
        } catch OrganizerError.sourceMissing(let path) {
            XCTAssertEqual(path, missingSource.path)
        }

        let source = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        FileManager.default.createFile(atPath: source.appendingPathComponent("photo.jpg").path, contents: Data("photo".utf8))

        do {
            _ = try await organizer.plan(
                sourceURL: source,
                destinationURL: missingDestination,
                options: .default
            )
            XCTFail("Expected missing destination parent to throw")
        } catch OrganizerError.destinationParentMissing(let path) {
            XCTAssertEqual(path, missingDestination.deletingLastPathComponent().path)
        }
    }

    func testExecuteCopiesAndMovesWithVerification() async throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let copySource = directory.appendingPathComponent("copy.jpg")
        let moveSource = directory.appendingPathComponent("move.jpg")
        let copyTarget = destination.appendingPathComponent("copy-target.jpg")
        let moveTarget = destination.appendingPathComponent("move-target.jpg")
        FileManager.default.createFile(atPath: copySource.path, contents: Data("copy".utf8))
        FileManager.default.createFile(atPath: moveSource.path, contents: Data("move".utf8))

        let metadata = MediaMetadata(creationDate: Date(), cameraModel: nil, source: .fileAttributes)
        let plan = OrganizationPlan(
            files: [
                PlannedFile(sourceURL: copySource, targetURL: copyTarget, metadata: metadata, operationMode: .copy),
                PlannedFile(sourceURL: moveSource, targetURL: moveTarget, metadata: metadata, operationMode: .move)
            ],
            skippedUnsupportedCount: 1,
            skippedMetadataCount: 2,
            skippedUnsupportedFiles: [directory.appendingPathComponent("ignored.txt")],
            skippedMetadataFiles: [directory.appendingPathComponent("metadata.jpg")]
        )

        let summary = await FileOrganizer().execute(plan: plan, options: OrganizationOptions(copyConcurrency: 2))

        XCTAssertEqual(summary.planned, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.copied + summary.cloned, 1)
        XCTAssertEqual(summary.moved, 1)
        XCTAssertEqual(summary.skippedUnsupported, 1)
        XCTAssertEqual(summary.skippedMetadata, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copySource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyTarget.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moveSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moveTarget.path))
        XCTAssertEqual(summary.skippedUnsupportedFiles.map(\.lastPathComponent), ["ignored.txt"])
        XCTAssertEqual(summary.skippedMetadataFiles.map(\.lastPathComponent), ["metadata.jpg"])
    }

    func testExecuteReportsFailureWhenTargetAlreadyExists() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.jpg")
        let target = directory.appendingPathComponent("target.jpg")
        FileManager.default.createFile(atPath: source.path, contents: Data("source".utf8))
        FileManager.default.createFile(atPath: target.path, contents: Data("target".utf8))
        let metadata = MediaMetadata(creationDate: Date(), cameraModel: nil, source: .fileAttributes)

        let summary = await FileOrganizer().execute(
            plan: OrganizationPlan(
                files: [
                    PlannedFile(sourceURL: source, targetURL: target, metadata: metadata, operationMode: .copy)
                ],
                skippedUnsupportedCount: 0,
                skippedMetadataCount: 0
            ),
            options: OrganizationOptions(copyConcurrency: 1)
        )

        XCTAssertEqual(summary.failed, 1)
        guard case .failed(let message) = summary.results[0].status else {
            return XCTFail("Expected failed result")
        }
        XCTAssertTrue(message.contains("Target already exists"))
    }

    func testExecuteRejectsDestinationSymlinkInsideSelectedRoot() async throws {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("source.jpg")
        let destinationRoot = directory.appendingPathComponent("destination", isDirectory: true)
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        let symlink = destinationRoot.appendingPathComponent("2025", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: Data("source".utf8))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

        let metadata = MediaMetadata(creationDate: Date(), cameraModel: nil, source: .fileAttributes)
        let summary = await FileOrganizer().execute(
            plan: OrganizationPlan(
                files: [
                    PlannedFile(
                        sourceURL: source,
                        targetURL: symlink.appendingPathComponent("redirected.jpg"),
                        metadata: metadata,
                        operationMode: .copy
                    )
                ],
                destinationURL: destinationRoot,
                skippedUnsupportedCount: 0,
                skippedMetadataCount: 0
            ),
            options: .default
        )

        XCTAssertEqual(summary.failed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("redirected.jpg").path))
        guard case .failed(let message) = summary.results[0].status else {
            return XCTFail("Expected failed result")
        }
        XCTAssertTrue(message.contains("symbolic link"))
    }

    func testMoveRejectsSymlinkSourceAndDoesNotDeleteIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let realSource = directory.appendingPathComponent("real.jpg")
        let symlinkSource = directory.appendingPathComponent("link.jpg")
        let target = directory.appendingPathComponent("target.jpg")
        FileManager.default.createFile(atPath: realSource.path, contents: Data("source".utf8))
        try FileManager.default.createSymbolicLink(at: symlinkSource, withDestinationURL: realSource)

        let metadata = MediaMetadata(creationDate: Date(), cameraModel: nil, source: .fileAttributes)
        let summary = await FileOrganizer().execute(
            plan: OrganizationPlan(
                files: [
                    PlannedFile(sourceURL: symlinkSource, targetURL: target, metadata: metadata, operationMode: .move)
                ],
                destinationURL: directory,
                skippedUnsupportedCount: 0,
                skippedMetadataCount: 0
            ),
            options: .default
        )

        XCTAssertEqual(summary.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkSource.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: realSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    private func currentYear() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: Date())
    }

    private func makeDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
