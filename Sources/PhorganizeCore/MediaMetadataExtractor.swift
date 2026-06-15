import AVFoundation
import Foundation
import ImageIO

public struct MediaMetadataExtractor {
    public static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff",
        "dng", "crw", "cr2", "cr3", "raf", "x3f", "orf"
    ]

    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v"
    ]

    public init() {}

    public func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.supportedImageExtensions.contains(ext) || Self.supportedVideoExtensions.contains(ext)
    }

    public func extractMetadata(from url: URL, timeZone: TimeZone) async -> MediaMetadata? {
        let ext = url.pathExtension.lowercased()

        if Self.supportedImageExtensions.contains(ext),
           let metadata = extractImageMetadata(from: url, timeZone: timeZone) {
            return metadata
        }

        if Self.supportedVideoExtensions.contains(ext),
           let metadata = await extractVideoMetadata(from: url, timeZone: timeZone) {
            return metadata
        }

        return extractFileAttributeMetadata(from: url)
    }

    private func extractImageMetadata(from url: URL, timeZone: TimeZone) -> MediaMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]

        let cameraModel = normalizedCameraModel(
            tiff?[kCGImagePropertyTIFFModel as String] as? String
        )
        let lensModel = normalizedCameraModel(exif?[kCGImagePropertyExifLensModel as String] as? String)

        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime as String] as? String

        guard let dateString,
              let date = parseEXIFDate(
                dateString,
                offset: exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
                timeZone: timeZone
              ) else {
            return nil
        }

        return MediaMetadata(creationDate: date, cameraModel: cameraModel, lensModel: lensModel, source: .image)
    }

    private func extractVideoMetadata(from url: URL, timeZone: TimeZone) async -> MediaMetadata? {
        let asset = AVURLAsset(url: url)
        let items: [AVMetadataItem]
        do {
            items = try await asset.load(.commonMetadata) + asset.load(.metadata)
        } catch {
            return extractFileAttributeMetadata(from: url)
        }

        var creationDate: Date?
        var cameraModel: String?
        var lensModel: String?

        for item in items {
            let key = [
                item.identifier?.rawValue,
                item.commonKey?.rawValue,
                item.key as? String
            ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

            guard let loadedValue = try? await item.load(.stringValue) else {
                continue
            }

            let value = loadedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }

            if creationDate == nil,
               key.contains("creation") || key.contains("created") || key.contains("date") {
                creationDate = parseVideoDate(value, timeZone: timeZone)
            }

            if cameraModel == nil,
               key.contains("model") || key.contains("camera") {
                cameraModel = normalizedCameraModel(value)
            }

            if lensModel == nil, key.contains("lens") {
                lensModel = normalizedCameraModel(value)
            }
        }

        if let creationDate {
            return MediaMetadata(creationDate: creationDate, cameraModel: cameraModel, lensModel: lensModel, source: .video)
        }

        return extractFileAttributeMetadata(from: url)
    }

    private func extractFileAttributeMetadata(from url: URL) -> MediaMetadata? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.creationDate] as? Date
                ?? attributes[.modificationDate] as? Date else {
            return nil
        }

        return MediaMetadata(creationDate: date, cameraModel: nil, lensModel: nil, source: .fileAttributes)
    }

    private func parseEXIFDate(_ value: String, offset: String?, timeZone: TimeZone) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if let offset, !offset.isEmpty {
            let normalizedOffset = normalizeOffset(offset)
            for format in ["yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ssXX"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                if let date = formatter.date(from: "\(trimmed)\(normalizedOffset)") {
                    return date
                }
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: trimmed)
    }

    private func parseVideoDate(_ value: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            return date
        }

        for format in [
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy:MM:dd HH:mm:ss"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private func normalizeOffset(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 5,
           trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)] != ":" {
            let split = trimmed.index(trimmed.startIndex, offsetBy: 3)
            return "\(trimmed[..<split]):\(trimmed[split...])"
        }
        return trimmed
    }

    private func normalizedCameraModel(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "(null)" ? nil : trimmed
    }
}
