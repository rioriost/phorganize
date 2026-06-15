import Darwin
import CryptoKit
import Foundation

actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        permits = max(1, value)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume()
        }
    }
}

public struct TargetPlanner {
    public typealias ExistingFileComparator = (_ sourceURL: URL, _ existingTargetURL: URL) -> Bool

    private struct Draft {
        var sourceURL: URL
        var directoryURL: URL
        var baseName: String
        var pathExtension: String
        var metadata: MediaMetadata
        var requiresSequence: Bool

        var key: String {
            "\(directoryURL.path)\u{0}\(baseName)\u{0}\(pathExtension)"
        }
    }

    public static func makePlan(
        candidates: [MediaFileCandidate],
        destinationURL: URL,
        options: OrganizationOptions
    ) -> [PlannedFile] {
        makePlanningResult(
            candidates: candidates,
            destinationURL: destinationURL,
            options: options,
            existingFileComparator: { _, _ in false }
        ).files
    }

    public static func makePlanningResult(
        candidates: [MediaFileCandidate],
        destinationURL: URL,
        options: OrganizationOptions,
        existingFileComparator: ExistingFileComparator
    ) -> TargetPlanningResult {
        let sortedCandidates = candidates.sorted { $0.sourceURL.path < $1.sourceURL.path }
        let drafts = sortedCandidates.map {
            makeDraft(candidate: $0, destinationURL: destinationURL, options: options)
        }
        let grouped = Dictionary(grouping: drafts, by: \.key)
        var usedTargets = Set<String>()
        var planned: [PlannedFile] = []
        var existingIdenticalFiles: [ExistingIdenticalFile] = []

        for var draft in drafts {
            draft.requiresSequence = (grouped[draft.key]?.count ?? 0) > 1

            var sequence = draft.requiresSequence ? 1 : 0
            while true {
                let targetURL = makeTargetURL(from: draft, sequence: sequence)

                if usedTargets.contains(targetURL.path) {
                    sequence += 1
                    continue
                }

                if FileManager.default.fileExists(atPath: targetURL.path) {
                    if existingFileComparator(draft.sourceURL, targetURL) {
                        usedTargets.insert(targetURL.path)
                        existingIdenticalFiles.append(
                            ExistingIdenticalFile(
                                sourceURL: draft.sourceURL,
                                existingTargetURL: targetURL
                            )
                        )
                        break
                    }

                    sequence += 1
                    continue
                }

                usedTargets.insert(targetURL.path)
                planned.append(
                    PlannedFile(
                        sourceURL: draft.sourceURL,
                        targetURL: targetURL,
                        metadata: draft.metadata,
                        operationMode: options.operationMode
                    )
                )
                break
            }
        }

        return TargetPlanningResult(
            files: planned,
            existingIdenticalFiles: existingIdenticalFiles
        )
    }

    private static func makeDraft(
        candidate: MediaFileCandidate,
        destinationURL: URL,
        options: OrganizationOptions
    ) -> Draft {
        let date = candidate.metadata.creationDate
        let timeZone = options.timeZone
        let year = format(date, "yyyy", timeZone)
        let month = format(date, "MM", timeZone)
        let day = format(date, "dd", timeZone)

        var directoryURL = destinationURL
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)

        if options.includeCameraFolder {
            directoryURL = directoryURL.appendingPathComponent(
                sanitizePathComponent(candidate.metadata.cameraModel),
                isDirectory: true
            )
        }

        if options.includeLensFolder {
            directoryURL = directoryURL.appendingPathComponent(
                sanitizePathComponent(candidate.metadata.lensModel),
                isDirectory: true
            )
        }

        let baseName = options.renameByDate
            ? format(date, "yyyyMMdd-HHmmss", timeZone)
            : candidate.sourceURL.deletingPathExtension().lastPathComponent

        return Draft(
            sourceURL: candidate.sourceURL,
            directoryURL: directoryURL,
            baseName: sanitizeFileBaseName(baseName),
            pathExtension: options.extensionCase.apply(to: candidate.sourceURL.pathExtension),
            metadata: candidate.metadata,
            requiresSequence: false
        )
    }

    private static func makeTargetURL(from draft: Draft, sequence: Int) -> URL {
        let suffix = sequence > 0 ? "_\(sequence)" : ""
        let filename = draft.pathExtension.isEmpty
            ? "\(draft.baseName)\(suffix)"
            : "\(draft.baseName)\(suffix).\(draft.pathExtension)"

        return draft.directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private static func format(_ date: Date, _ dateFormat: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }

    private static func sanitizePathComponent(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = trimmed.isEmpty ? "(null)" : trimmed
        return fallback
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private static func sanitizeFileBaseName(_ value: String) -> String {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return sanitized.isEmpty ? "untitled" : sanitized
    }
}

public final class FileOrganizer {
    private typealias SHA256Digest = SHA256.Digest

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private let extractor: MediaMetadataExtractor
    private let fileManager: FileManager

    public init(extractor: MediaMetadataExtractor = MediaMetadataExtractor(), fileManager: FileManager = .default) {
        self.extractor = extractor
        self.fileManager = fileManager
    }

    public func summarizeSource(sourceURL: URL, recursive: Bool) throws -> SourceFileSummary {
        let discovered = try discoverFiles(sourceURL: sourceURL, recursive: recursive)
        let supported = discovered.filter { extractor.isSupported($0) }
        let counts = Dictionary(grouping: supported) { url in
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "(none)" : ext
        }
        .map { (extensionName: $0.key, count: $0.value.count) }
        .sorted {
            if $0.count == $1.count {
                return $0.extensionName < $1.extensionName
            }
            return $0.count > $1.count
        }
        .map { SupportedExtensionCount(extensionName: $0.extensionName, count: $0.count) }

        return SourceFileSummary(
            totalFiles: discovered.count,
            supportedFiles: supported.count,
            unsupportedFiles: discovered.count - supported.count,
            supportedExtensionCounts: counts
        )
    }

    public func plan(
        sourceURL: URL,
        destinationURL: URL,
        options: OrganizationOptions,
        progress: ((Int, Int) async -> Void)? = nil
    ) async throws -> OrganizationPlan {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw OrganizerError.sourceMissing(sourceURL.path)
        }

        try ensureDestinationCanBeCreated(destinationURL)

        let discovered = try discoverFiles(sourceURL: sourceURL, recursive: options.recursive)
        let supported = discovered.filter { extractor.isSupported($0) }
        let unsupported = discovered.filter { !extractor.isSupported($0) }
        let semaphore = AsyncSemaphore(value: options.metadataConcurrency)

        var candidates: [MediaFileCandidate] = []
        var skippedMetadataFiles: [URL] = []
        var completed = 0

        await withTaskGroup(of: (URL, MediaFileCandidate?).self) { group in
            for url in supported {
                group.addTask {
                    await semaphore.acquire()
                    let metadata = await self.extractor.extractMetadata(from: url, timeZone: options.timeZone)
                    await semaphore.release()

                    guard let metadata else {
                        return (url, nil)
                    }
                    return (url, MediaFileCandidate(sourceURL: url, metadata: metadata))
                }
            }

            for await (url, candidate) in group {
                completed += 1
                if let candidate {
                    candidates.append(candidate)
                } else {
                    skippedMetadataFiles.append(url)
                }
                await progress?(completed, supported.count)
            }
        }

        let planningResult = TargetPlanner.makePlanningResult(
            candidates: candidates,
            destinationURL: destinationURL,
            options: options,
            existingFileComparator: { sourceURL, existingTargetURL in
                (try? self.filesHaveSameSHA256(sourceURL, existingTargetURL)) == true
            }
        )

        return OrganizationPlan(
            files: planningResult.files,
            destinationURL: destinationURL,
            skippedUnsupportedCount: unsupported.count,
            skippedMetadataCount: skippedMetadataFiles.count,
            skippedUnsupportedFiles: unsupported.sorted { $0.path < $1.path },
            skippedMetadataFiles: skippedMetadataFiles.sorted { $0.path < $1.path },
            existingIdenticalFiles: planningResult.existingIdenticalFiles
        )
    }

    public func execute(
        plan: OrganizationPlan,
        options: OrganizationOptions,
        progress: ((Int, Int) async -> Void)? = nil
    ) async -> OrganizationSummary {
        let semaphore = AsyncSemaphore(value: options.copyConcurrency)
        var completed = 0
        var results: [FileExecutionResult] = []

        await withTaskGroup(of: FileExecutionResult.self) { group in
            for plannedFile in plan.files {
                group.addTask {
                    await semaphore.acquire()
                    let result = self.perform(plannedFile, destinationRootURL: plan.destinationURL)
                    await semaphore.release()
                    return result
                }
            }

            for await result in group {
                completed += 1
                results.append(result)
                await progress?(completed, plan.files.count)
            }
        }

        return OrganizationSummary(
            planned: plan.files.count,
            copied: results.filter { $0.status == .copied }.count,
            cloned: results.filter { $0.status == .cloned }.count,
            moved: results.filter { $0.status == .moved }.count,
            failed: results.filter {
                if case .failed = $0.status { return true }
                if case .copiedButSourceDeleteFailed = $0.status { return true }
                return false
            }.count,
            skippedUnsupported: plan.skippedUnsupportedCount,
            skippedMetadata: plan.skippedMetadataCount,
            skippedExistingIdentical: plan.existingIdenticalFiles.count,
            results: results.sorted { $0.plannedFile.sourceURL.path < $1.plannedFile.sourceURL.path },
            skippedUnsupportedFiles: plan.skippedUnsupportedFiles,
            skippedMetadataFiles: plan.skippedMetadataFiles,
            existingIdenticalFiles: plan.existingIdenticalFiles
        )
    }

    private func discoverFiles(sourceURL: URL, recursive: Bool) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw OrganizerError.sourceMissing(sourceURL.path)
        }

        if !isDirectory.boolValue {
            return [sourceURL]
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            return enumerator.compactMap { item in
                guard let url = item as? URL,
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isHidden != true else {
                    return nil
                }
                return url
            }
            .sorted { $0.path < $1.path }
        }

        return try fileManager
            .contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .filter {
                let values = try? $0.resourceValues(forKeys: Set(keys))
                return values?.isRegularFile == true && values?.isHidden != true
            }
            .sorted { $0.path < $1.path }
    }

    private func ensureDestinationCanBeCreated(_ destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            return
        }

        let parent = destinationURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else {
            throw OrganizerError.destinationParentMissing(parent.path)
        }
    }

    private func perform(_ plannedFile: PlannedFile, destinationRootURL: URL?) -> FileExecutionResult {
        do {
            let sourceIdentity = try fileIdentity(of: plannedFile.sourceURL)
            let usedClone = try copySafely(
                from: plannedFile.sourceURL,
                to: plannedFile.targetURL,
                destinationRootURL: destinationRootURL
            )
            if plannedFile.operationMode == .move {
                do {
                    try deleteSourceIfIdentityUnchanged(plannedFile.sourceURL, expected: sourceIdentity)
                } catch {
                    return FileExecutionResult(
                        plannedFile: plannedFile,
                        status: .copiedButSourceDeleteFailed(error.localizedDescription)
                    )
                }
                return FileExecutionResult(plannedFile: plannedFile, status: .moved)
            }
            return FileExecutionResult(plannedFile: plannedFile, status: usedClone ? .cloned : .copied)
        } catch {
            return FileExecutionResult(plannedFile: plannedFile, status: .failed(error.localizedDescription))
        }
    }

    private func copySafely(from sourceURL: URL, to targetURL: URL, destinationRootURL: URL?) throws -> Bool {
        let targetDirectory = targetURL.deletingLastPathComponent()
        try prepareDestinationDirectory(targetDirectory, destinationRootURL: destinationRootURL)

        guard !pathExistsUsingLstat(targetURL) else {
            throw OrganizerError.targetAlreadyExists(targetURL.path)
        }

        let temporaryURL = targetDirectory.appendingPathComponent(
            ".\(targetURL.lastPathComponent).phorganize-\(UUID().uuidString).tmp",
            isDirectory: false
        )

        var usedClone = false
        do {
            guard !pathExistsUsingLstat(temporaryURL) else {
                throw OrganizerError.targetAlreadyExists(temporaryURL.path)
            }

            if isSameVolume(sourceURL, targetDirectory), cloneFile(from: sourceURL, to: temporaryURL) {
                usedClone = true
            } else {
                try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            }

            try ensureRegularFileWithoutSymlink(temporaryURL)
            try verifyFileSize(sourceURL: sourceURL, copiedURL: temporaryURL)
            guard !pathExistsUsingLstat(targetURL) else {
                throw OrganizerError.targetAlreadyExists(targetURL.path)
            }
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
            try ensureRegularFileWithoutSymlink(targetURL)
            try verifyFileSize(sourceURL: sourceURL, copiedURL: targetURL)
            return usedClone
        } catch {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func prepareDestinationDirectory(_ targetDirectory: URL, destinationRootURL: URL?) throws {
        let rootURL = (destinationRootURL ?? targetDirectory).standardizedFileURL
        let targetURL = targetDirectory.standardizedFileURL
        let rootPath = rootURL.path
        let targetPath = targetURL.path

        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw OrganizerError.destinationEscapesRoot(targetPath)
        }

        try createDirectoryRejectingSymlink(rootURL)

        let rootComponents = rootURL.pathComponents
        let targetComponents = targetURL.pathComponents
        var current = rootURL

        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            try createDirectoryRejectingSymlink(current)
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        let resolvedTarget = targetURL.resolvingSymlinksInPath().path
        guard resolvedTarget == resolvedRoot || resolvedTarget.hasPrefix(resolvedRoot + "/") else {
            throw OrganizerError.destinationEscapesRoot(targetPath)
        }
    }

    private func createDirectoryRejectingSymlink(_ url: URL) throws {
        var statBuffer = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &statBuffer)
        }

        if result == 0 {
            if (statBuffer.st_mode & S_IFMT) == S_IFLNK {
                throw OrganizerError.destinationContainsSymbolicLink(url.path)
            }
            guard (statBuffer.st_mode & S_IFMT) == S_IFDIR else {
                throw OrganizerError.destinationParentMissing(url.path)
            }
            return
        }

        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            if pathExistsUsingLstat(url) {
                try ensureDirectoryWithoutSymlink(url)
                return
            }
            throw error
        }
        try ensureDirectoryWithoutSymlink(url)
    }

    private func ensureDirectoryWithoutSymlink(_ url: URL) throws {
        var statBuffer = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &statBuffer)
        }

        guard result == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFDIR else {
            throw OrganizerError.destinationParentMissing(url.path)
        }

        if (statBuffer.st_mode & S_IFMT) == S_IFLNK {
            throw OrganizerError.destinationContainsSymbolicLink(url.path)
        }
    }

    private func ensureRegularFileWithoutSymlink(_ url: URL) throws {
        var statBuffer = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &statBuffer)
        }

        guard result == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            throw OrganizerError.sourceNotRegularFile(url.path)
        }
    }

    private func pathExistsUsingLstat(_ url: URL) -> Bool {
        var statBuffer = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &statBuffer) == 0
        }
    }

    private func fileIdentity(of url: URL) throws -> FileIdentity {
        var statBuffer = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &statBuffer)
        }

        guard result == 0,
              (statBuffer.st_mode & S_IFMT) == S_IFREG else {
            throw OrganizerError.sourceNotRegularFile(url.path)
        }

        return FileIdentity(device: statBuffer.st_dev, inode: statBuffer.st_ino)
    }

    private func deleteSourceIfIdentityUnchanged(_ sourceURL: URL, expected: FileIdentity) throws {
        guard try fileIdentity(of: sourceURL) == expected else {
            throw OrganizerError.sourceIdentityChanged(sourceURL.path)
        }

        let result = sourceURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return unlink(path)
        }

        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func verifyFileSize(sourceURL: URL, copiedURL: URL) throws {
        let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let copiedSize = try copiedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize

        guard sourceSize == copiedSize else {
            throw OrganizerError.copyVerificationFailed(copiedURL.path)
        }
    }

    private func isSameVolume(_ sourceURL: URL, _ targetDirectory: URL) -> Bool {
        guard let sourceVolume = try? sourceURL.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let targetVolume = try? targetDirectory.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }

        return (sourceVolume as AnyObject).isEqual(targetVolume)
    }

    private func cloneFile(from sourceURL: URL, to targetURL: URL) -> Bool {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            targetURL.withUnsafeFileSystemRepresentation { targetPath in
                guard let sourcePath, let targetPath else {
                    return Int32(-1)
                }
                return clonefile(sourcePath, targetPath, 0)
            }
        }

        return result == 0
    }

    private func filesHaveSameSHA256(_ sourceURL: URL, _ targetURL: URL) throws -> Bool {
        _ = try fileIdentity(of: sourceURL)
        try ensureRegularFileWithoutSymlink(targetURL)
        let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let targetSize = try targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize

        guard sourceSize == targetSize else {
            return false
        }

        return try sha256Digest(of: sourceURL) == sha256Digest(of: targetURL)
    }

    private func sha256Digest(of url: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 4 * 1_024 * 1_024)
            guard !data.isEmpty else {
                return false
            }
            hasher.update(data: data)
            return true
        }) {}

        return hasher.finalize()
    }
}
