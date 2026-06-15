import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhorganizeCore

final class MediaMetadataExtractorTests: XCTestCase {
    func testSupportedExtensionsAreCaseInsensitive() {
        let extractor = MediaMetadataExtractor()

        XCTAssertTrue(extractor.isSupported(URL(fileURLWithPath: "/tmp/photo.CR3")))
        XCTAssertTrue(extractor.isSupported(URL(fileURLWithPath: "/tmp/movie.Mp4")))
        XCTAssertFalse(extractor.isSupported(URL(fileURLWithPath: "/tmp/readme.txt")))
    }

    func testExtractsImageMetadataWithoutSubprocesses() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("photo.jpg")
        try writeJPEG(
            to: imageURL,
            date: "2023:05:15 10:30:00",
            offset: "+09:00",
            cameraModel: " Canon EOS R6m2 ",
            lensModel: " RF24-70mm F2.8 L IS USM "
        )

        let metadata = await MediaMetadataExtractor().extractMetadata(
            from: imageURL,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )

        XCTAssertEqual(metadata?.cameraModel, "Canon EOS R6m2")
        XCTAssertEqual(metadata?.lensModel, "RF24-70mm F2.8 L IS USM")
        XCTAssertEqual(metadata?.source, .image)
        XCTAssertEqual(metadata?.creationDate, makeDate("2023-05-15T01:30:00Z"))
    }

    func testInvalidSupportedImageFallsBackToFileAttributes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("broken.jpg")
        FileManager.default.createFile(atPath: imageURL.path, contents: Data("not an image".utf8))

        let metadata = await MediaMetadataExtractor().extractMetadata(from: imageURL, timeZone: .current)

        XCTAssertNotNil(metadata?.creationDate)
        XCTAssertNil(metadata?.cameraModel)
        XCTAssertEqual(metadata?.source, .fileAttributes)
    }

    func testMissingFileHasNoMetadata() async {
        let metadata = await MediaMetadataExtractor().extractMetadata(
            from: URL(fileURLWithPath: "/tmp/phorganize-\(UUID().uuidString).jpg"),
            timeZone: .current
        )

        XCTAssertNil(metadata)
    }

    private func writeJPEG(
        to url: URL,
        date: String,
        offset: String,
        cameraModel: String,
        lensModel: String
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: date,
                kCGImagePropertyExifOffsetTimeOriginal as String: offset,
                kCGImagePropertyExifLensModel as String: lensModel
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFModel as String: cameraModel
            ]
        ]

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeDate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
