import XCTest
@testable import PhorganizeCore

final class TargetPlannerTests: XCTestCase {
    func testDateCameraAndDuplicateTargetNames() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let metadata = MediaMetadata(creationDate: date, cameraModel: "Canon EOS R6m2", source: .image)
        let options = OrganizationOptions(
            recursive: false,
            includeCameraFolder: true,
            renameByDate: true,
            extensionCase: .upper,
            operationMode: .copy,
            timezoneOffsetHours: 9,
            metadataConcurrency: 2,
            copyConcurrency: 1
        )

        let candidates = [
            MediaFileCandidate(sourceURL: URL(fileURLWithPath: "/tmp/IMG_0002.cr3"), metadata: metadata),
            MediaFileCandidate(sourceURL: URL(fileURLWithPath: "/tmp/IMG_0001.cr3"), metadata: metadata)
        ]

        let plan = TargetPlanner.makePlan(candidates: candidates, destinationURL: destination, options: options)
        let targets = plan.map { $0.targetURL.path.replacingOccurrences(of: destination.path, with: "") }

        XCTAssertEqual(targets, [
            "/2025/02/06/Canon EOS R6m2/20250206-181616_1.CR3",
            "/2025/02/06/Canon EOS R6m2/20250206-181616_2.CR3"
        ])
    }

    func testMissingCameraUsesNullDirectory() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let metadata = MediaMetadata(creationDate: date, cameraModel: nil, source: .video)
        let options = OrganizationOptions(
            includeCameraFolder: true,
            timezoneOffsetHours: 9
        )

        let plan = TargetPlanner.makePlan(
            candidates: [
                MediaFileCandidate(sourceURL: URL(fileURLWithPath: "/tmp/clip.MP4"), metadata: metadata)
            ],
            destinationURL: destination,
            options: options
        )

        XCTAssertTrue(plan[0].targetURL.path.hasSuffix("/2025/02/06/(null)/20250206-181616.MP4"))
    }

    func testLensFolderIsCreatedBelowCameraFolder() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let metadata = MediaMetadata(
            creationDate: date,
            cameraModel: "Canon EOS R6m2",
            lensModel: "RF24-70mm F2.8 L IS USM",
            source: .image
        )
        let options = OrganizationOptions(
            includeCameraFolder: true,
            includeLensFolder: true,
            timezoneIdentifier: "UTC"
        )

        let plan = TargetPlanner.makePlan(
            candidates: [
                MediaFileCandidate(sourceURL: URL(fileURLWithPath: "/tmp/photo.CR3"), metadata: metadata)
            ],
            destinationURL: destination,
            options: options
        )

        XCTAssertTrue(
            plan[0].targetURL.path.hasSuffix(
                "/2025/02/06/Canon EOS R6m2/RF24-70mm F2.8 L IS USM/20250206-091616.CR3"
            )
        )
    }

    func testLensFolderUsesNullWhenLensMetadataIsMissing() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let metadata = MediaMetadata(
            creationDate: date,
            cameraModel: "Canon EOS R6m2",
            lensModel: nil,
            source: .image
        )
        let options = OrganizationOptions(
            includeCameraFolder: true,
            includeLensFolder: true,
            timezoneIdentifier: "UTC"
        )

        let plan = TargetPlanner.makePlan(
            candidates: [
                MediaFileCandidate(sourceURL: URL(fileURLWithPath: "/tmp/photo.CR3"), metadata: metadata)
            ],
            destinationURL: destination,
            options: options
        )

        XCTAssertTrue(
            plan[0].targetURL.path.hasSuffix(
                "/2025/02/06/Canon EOS R6m2/(null)/20250206-091616.CR3"
            )
        )
    }

    func testExistingIdenticalTargetIsSkipped() throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let metadata = MediaMetadata(creationDate: date, cameraModel: nil, source: .image)
        let existingTarget = destination
            .appendingPathComponent("2025/02/06/(null)", isDirectory: true)
            .appendingPathComponent("20250206-091616.jpg")
        try FileManager.default.createDirectory(
            at: existingTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: existingTarget.path, contents: Data("same".utf8))

        let result = TargetPlanner.makePlanningResult(
            candidates: [
                MediaFileCandidate(sourceURL: URL(fileURLWithPath: "/tmp/source.jpg"), metadata: metadata)
            ],
            destinationURL: destination,
            options: OrganizationOptions(includeCameraFolder: true, timezoneIdentifier: "UTC"),
            existingFileComparator: { _, _ in true }
        )

        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.existingIdenticalFiles.map(\.existingTargetURL), [existingTarget])
    }

    func testExistingDifferentTargetGetsSequenceSuffix() throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let date = try XCTUnwrap(makeDate("2025-02-06T09:16:16Z"))
        let metadata = MediaMetadata(creationDate: date, cameraModel: nil, source: .image)
        let existingTarget = destination
            .appendingPathComponent("2025/02/06/(null)", isDirectory: true)
            .appendingPathComponent("20250206-091616.jpg")
        try FileManager.default.createDirectory(
            at: existingTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: existingTarget.path, contents: Data("different".utf8))

        let result = TargetPlanner.makePlanningResult(
            candidates: [
                MediaFileCandidate(sourceURL: URL(fileURLWithPath: "/tmp/source.jpg"), metadata: metadata)
            ],
            destinationURL: destination,
            options: OrganizationOptions(includeCameraFolder: true, timezoneIdentifier: "UTC"),
            existingFileComparator: { _, _ in false }
        )

        XCTAssertTrue(result.existingIdenticalFiles.isEmpty)
        XCTAssertEqual(
            result.files[0].targetURL.lastPathComponent,
            "20250206-091616_1.jpg"
        )
    }

    func testSourceSummaryCountsSupportedExtensions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for filename in ["a.CR3", "b.cr3", "clip.MP4", "note.txt"] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(filename).path,
                contents: Data()
            )
        }

        let summary = try FileOrganizer().summarizeSource(sourceURL: directory, recursive: false)

        XCTAssertEqual(summary.totalFiles, 4)
        XCTAssertEqual(summary.supportedFiles, 3)
        XCTAssertEqual(summary.unsupportedFiles, 1)
        XCTAssertEqual(summary.supportedExtensionCounts, [
            SupportedExtensionCount(extensionName: "CR3", count: 2),
            SupportedExtensionCount(extensionName: "MP4", count: 1)
        ])
    }

    private func makeDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
