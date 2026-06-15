import Foundation

public enum OperationMode: String, Codable, CaseIterable, Identifiable {
    case copy
    case move

    public var id: String { rawValue }
}

public enum ExtensionCase: String, Codable, CaseIterable, Identifiable {
    case preserve
    case lower
    case upper

    public var id: String { rawValue }

    func apply(to pathExtension: String) -> String {
        switch self {
        case .preserve:
            return pathExtension
        case .lower:
            return pathExtension.lowercased()
        case .upper:
            return pathExtension.uppercased()
        }
    }
}

public struct OrganizationOptions: Codable, Equatable {
    public var recursive: Bool
    public var includeCameraFolder: Bool
    public var includeLensFolder: Bool
    public var renameByDate: Bool
    public var extensionCase: ExtensionCase
    public var operationMode: OperationMode
    public var timezoneOffsetHours: Int
    public var timezoneIdentifier: String
    public var metadataConcurrency: Int
    public var copyConcurrency: Int

    public init(
        recursive: Bool = false,
        includeCameraFolder: Bool = true,
        includeLensFolder: Bool = false,
        renameByDate: Bool = true,
        extensionCase: ExtensionCase = .preserve,
        operationMode: OperationMode = .copy,
        timezoneOffsetHours: Int = TimeZone.current.secondsFromGMT() / 3_600,
        timezoneIdentifier: String? = nil,
        metadataConcurrency: Int = max(2, min(ProcessInfo.processInfo.activeProcessorCount * 2, 16)),
        copyConcurrency: Int = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 6))
    ) {
        self.recursive = recursive
        self.includeCameraFolder = includeCameraFolder
        self.includeLensFolder = includeLensFolder
        self.renameByDate = renameByDate
        self.extensionCase = extensionCase
        self.operationMode = operationMode
        self.timezoneOffsetHours = timezoneOffsetHours
        self.timezoneIdentifier = timezoneIdentifier ?? TimeZone.current.identifier
        self.metadataConcurrency = metadataConcurrency
        self.copyConcurrency = copyConcurrency
    }

    private enum CodingKeys: String, CodingKey {
        case recursive
        case includeCameraFolder
        case includeLensFolder
        case renameByDate
        case extensionCase
        case operationMode
        case timezoneOffsetHours
        case timezoneIdentifier
        case metadataConcurrency
        case copyConcurrency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OrganizationOptions.default

        recursive = try container.decodeIfPresent(Bool.self, forKey: .recursive) ?? defaults.recursive
        includeCameraFolder = try container.decodeIfPresent(Bool.self, forKey: .includeCameraFolder) ?? defaults.includeCameraFolder
        includeLensFolder = try container.decodeIfPresent(Bool.self, forKey: .includeLensFolder) ?? defaults.includeLensFolder
        renameByDate = try container.decodeIfPresent(Bool.self, forKey: .renameByDate) ?? defaults.renameByDate
        extensionCase = try container.decodeIfPresent(ExtensionCase.self, forKey: .extensionCase) ?? defaults.extensionCase
        operationMode = try container.decodeIfPresent(OperationMode.self, forKey: .operationMode) ?? defaults.operationMode
        timezoneOffsetHours = try container.decodeIfPresent(Int.self, forKey: .timezoneOffsetHours) ?? defaults.timezoneOffsetHours
        timezoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timezoneIdentifier)
            ?? TimeZone(secondsFromGMT: timezoneOffsetHours * 3_600)?.identifier
            ?? defaults.timezoneIdentifier
        metadataConcurrency = try container.decodeIfPresent(Int.self, forKey: .metadataConcurrency) ?? defaults.metadataConcurrency
        copyConcurrency = try container.decodeIfPresent(Int.self, forKey: .copyConcurrency) ?? defaults.copyConcurrency
    }

    public static var `default`: OrganizationOptions {
        OrganizationOptions()
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timezoneIdentifier)
            ?? TimeZone(secondsFromGMT: timezoneOffsetHours * 3_600)
            ?? .current
    }
}

public struct SupportedExtensionCount: Equatable {
    public var extensionName: String
    public var count: Int

    public init(extensionName: String, count: Int) {
        self.extensionName = extensionName
        self.count = count
    }
}

public struct SourceFileSummary: Equatable {
    public var totalFiles: Int
    public var supportedFiles: Int
    public var unsupportedFiles: Int
    public var supportedExtensionCounts: [SupportedExtensionCount]

    public init(
        totalFiles: Int,
        supportedFiles: Int,
        unsupportedFiles: Int,
        supportedExtensionCounts: [SupportedExtensionCount]
    ) {
        self.totalFiles = totalFiles
        self.supportedFiles = supportedFiles
        self.unsupportedFiles = unsupportedFiles
        self.supportedExtensionCounts = supportedExtensionCounts
    }
}

public enum MetadataSource: String, Codable {
    case image
    case video
    case fileAttributes
}

public struct MediaMetadata: Codable, Equatable {
    public var creationDate: Date
    public var cameraModel: String?
    public var lensModel: String?
    public var source: MetadataSource

    public init(creationDate: Date, cameraModel: String?, lensModel: String? = nil, source: MetadataSource) {
        self.creationDate = creationDate
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.source = source
    }
}

public struct MediaFileCandidate: Equatable {
    public var sourceURL: URL
    public var metadata: MediaMetadata

    public init(sourceURL: URL, metadata: MediaMetadata) {
        self.sourceURL = sourceURL
        self.metadata = metadata
    }
}

public struct PlannedFile: Identifiable, Equatable {
    public var id: String { sourceURL.path }
    public var sourceURL: URL
    public var targetURL: URL
    public var metadata: MediaMetadata
    public var operationMode: OperationMode

    public init(
        sourceURL: URL,
        targetURL: URL,
        metadata: MediaMetadata,
        operationMode: OperationMode
    ) {
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        self.metadata = metadata
        self.operationMode = operationMode
    }
}

public struct ExistingIdenticalFile: Equatable {
    public var sourceURL: URL
    public var existingTargetURL: URL

    public init(sourceURL: URL, existingTargetURL: URL) {
        self.sourceURL = sourceURL
        self.existingTargetURL = existingTargetURL
    }
}

public struct TargetPlanningResult: Equatable {
    public var files: [PlannedFile]
    public var existingIdenticalFiles: [ExistingIdenticalFile]

    public init(files: [PlannedFile], existingIdenticalFiles: [ExistingIdenticalFile]) {
        self.files = files
        self.existingIdenticalFiles = existingIdenticalFiles
    }
}

public struct OrganizationPlan: Equatable {
    public var files: [PlannedFile]
    public var destinationURL: URL?
    public var skippedUnsupportedCount: Int
    public var skippedMetadataCount: Int
    public var skippedUnsupportedFiles: [URL]
    public var skippedMetadataFiles: [URL]
    public var existingIdenticalFiles: [ExistingIdenticalFile]

    public init(
        files: [PlannedFile],
        destinationURL: URL? = nil,
        skippedUnsupportedCount: Int,
        skippedMetadataCount: Int,
        skippedUnsupportedFiles: [URL] = [],
        skippedMetadataFiles: [URL] = [],
        existingIdenticalFiles: [ExistingIdenticalFile] = []
    ) {
        self.files = files
        self.destinationURL = destinationURL
        self.skippedUnsupportedCount = skippedUnsupportedCount
        self.skippedMetadataCount = skippedMetadataCount
        self.skippedUnsupportedFiles = skippedUnsupportedFiles
        self.skippedMetadataFiles = skippedMetadataFiles
        self.existingIdenticalFiles = existingIdenticalFiles
    }
}

public enum ExecutionStatus: Equatable {
    case copied
    case cloned
    case moved
    case copiedButSourceDeleteFailed(String)
    case failed(String)
}

public struct FileExecutionResult: Equatable {
    public var plannedFile: PlannedFile
    public var status: ExecutionStatus

    public init(plannedFile: PlannedFile, status: ExecutionStatus) {
        self.plannedFile = plannedFile
        self.status = status
    }
}

public struct OrganizationSummary: Equatable {
    public var planned: Int
    public var copied: Int
    public var cloned: Int
    public var moved: Int
    public var failed: Int
    public var skippedUnsupported: Int
    public var skippedMetadata: Int
    public var skippedExistingIdentical: Int
    public var results: [FileExecutionResult]
    public var skippedUnsupportedFiles: [URL]
    public var skippedMetadataFiles: [URL]
    public var existingIdenticalFiles: [ExistingIdenticalFile]

    public init(
        planned: Int,
        copied: Int,
        cloned: Int,
        moved: Int,
        failed: Int,
        skippedUnsupported: Int,
        skippedMetadata: Int,
        skippedExistingIdentical: Int = 0,
        results: [FileExecutionResult],
        skippedUnsupportedFiles: [URL] = [],
        skippedMetadataFiles: [URL] = [],
        existingIdenticalFiles: [ExistingIdenticalFile] = []
    ) {
        self.planned = planned
        self.copied = copied
        self.cloned = cloned
        self.moved = moved
        self.failed = failed
        self.skippedUnsupported = skippedUnsupported
        self.skippedMetadata = skippedMetadata
        self.skippedExistingIdentical = skippedExistingIdentical
        self.results = results
        self.skippedUnsupportedFiles = skippedUnsupportedFiles
        self.skippedMetadataFiles = skippedMetadataFiles
        self.existingIdenticalFiles = existingIdenticalFiles
    }
}

public enum OrganizerError: Error, LocalizedError {
    case sourceMissing(String)
    case destinationParentMissing(String)
    case targetAlreadyExists(String)
    case copyVerificationFailed(String)
    case destinationEscapesRoot(String)
    case destinationContainsSymbolicLink(String)
    case sourceNotRegularFile(String)
    case sourceIdentityChanged(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "Source does not exist: \(path)"
        case .destinationParentMissing(let path):
            return "Destination parent does not exist: \(path)"
        case .targetAlreadyExists(let path):
            return "Target already exists: \(path)"
        case .copyVerificationFailed(let path):
            return "Copy verification failed: \(path)"
        case .destinationEscapesRoot(let path):
            return "Destination path escapes the selected root: \(path)"
        case .destinationContainsSymbolicLink(let path):
            return "Destination path contains a symbolic link: \(path)"
        case .sourceNotRegularFile(let path):
            return "Source is not a regular file: \(path)"
        case .sourceIdentityChanged(let path):
            return "Source changed before deletion: \(path)"
        }
    }
}
