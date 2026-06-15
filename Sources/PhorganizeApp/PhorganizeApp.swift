import AppKit
#if SWIFT_PACKAGE
import PhorganizeCore
#endif
import SwiftUI
import UniformTypeIdentifiers

@main
struct PhorganizeMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, idealWidth: 980, minHeight: 860, idealHeight: 940)
        }
        .defaultSize(width: 980, height: 940)
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppModel: ObservableObject {
    private struct RunSignature: Equatable {
        var sourcePath: String
        var destinationPath: String
        var options: OrganizationOptions
    }

    @Published var sourcePath: String = "" {
        didSet {
            saveLocation(path: sourcePath, bookmarkKey: Keys.sourceBookmark, pathKey: Keys.sourcePath)
            markPendingChange()
            refreshSourceSummary()
        }
    }

    @Published var destinationPath: String = "" {
        didSet {
            saveLocation(path: destinationPath, bookmarkKey: Keys.destinationBookmark, pathKey: Keys.destinationPath)
            markPendingChange()
        }
    }

    @Published var options: OrganizationOptions = .default {
        didSet {
            saveOptions()
            markPendingChange()
            if oldValue.recursive != options.recursive {
                refreshSourceSummary()
            }
        }
    }

    @Published var isProcessing = false
    @Published var hasPendingChange = true
    @Published var phase = L10n.string("phase.ready")
    @Published var progressValue = 0.0
    @Published var progressText = ""
    @Published var resultLines: [String] = []
    @Published var sourceSummaryText = ""

    private let organizer = FileOrganizer()
    private let defaults = UserDefaults.standard
    private var sourceSummaryRequestID = UUID()

    private enum Keys {
        static let sourcePath = "phorganize.source.path"
        static let sourceBookmark = "phorganize.source.bookmark"
        static let destinationPath = "phorganize.destination.path"
        static let destinationBookmark = "phorganize.destination.bookmark"
        static let options = "phorganize.options"
    }

    init() {
        sourcePath = loadPath(bookmarkKey: Keys.sourceBookmark, pathKey: Keys.sourcePath)
        destinationPath = loadPath(bookmarkKey: Keys.destinationBookmark, pathKey: Keys.destinationPath)
        options = loadOptions()
        refreshSourceSummary()
    }

    var canRun: Bool {
        !isProcessing
            && hasPendingChange
            && FileManager.default.fileExists(atPath: sourcePath)
            && FileManager.default.fileExists(atPath: destinationPath)
    }

    var actionTitle: String {
        options.operationMode == .move
            ? L10n.string("action.moveFiles")
            : L10n.string("action.copyFiles")
    }

    var destinationWarningText: String {
        guard options.recursive,
              !sourcePath.isEmpty,
              !destinationPath.isEmpty else {
            return ""
        }

        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL.path
        guard destination == source || destination.hasPrefix(source + "/") else {
            return ""
        }

        return L10n.string("destination.warningRecursiveNested")
    }

    func chooseSource() {
        chooseFolder { [weak self] url in
            self?.sourcePath = url.path
        }
    }

    func chooseDestination() {
        chooseFolder { [weak self] url in
            self?.destinationPath = url.path
        }
    }

    func acceptSource(_ url: URL) {
        sourcePath = url.path
    }

    func acceptDestination(_ url: URL) {
        destinationPath = url.path
    }

    func run() {
        let source = resolvedURL(bookmarkKey: Keys.sourceBookmark, fallbackPath: sourcePath)
        let destination = resolvedURL(bookmarkKey: Keys.destinationBookmark, fallbackPath: destinationPath)
        let selectedOptions = options
        let runSignature = currentRunSignature()

        isProcessing = true
        progressValue = 0
        progressText = ""
        resultLines = []
        phase = L10n.string("phase.readingMetadata")

        Task {
            let sourceAccess = source.startAccessingSecurityScopedResource()
            let destinationAccess = destination.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                if destinationAccess { destination.stopAccessingSecurityScopedResource() }
            }

            do {
                let plan = try await organizer.plan(
                    sourceURL: source,
                    destinationURL: destination,
                    options: selectedOptions
                ) { [weak self] completed, total in
                    await MainActor.run {
                        self?.setProgress(completed: completed, total: total)
                        self?.progressText = L10n.format("progress.metadata", completed, total)
                    }
                }

                await MainActor.run {
                    self.phase = L10n.string("phase.copyingFiles")
                    self.progressValue = 0
                    self.progressText = L10n.format("progress.files", 0, plan.files.count)
                }

                let summary = await organizer.execute(
                    plan: plan,
                    options: selectedOptions
                ) { [weak self] completed, total in
                    await MainActor.run {
                        self?.setProgress(completed: completed, total: total)
                        self?.progressText = L10n.format("progress.files", completed, total)
                    }
                }

                await MainActor.run {
                    self.isProcessing = false
                    self.hasPendingChange = self.currentRunSignature() != runSignature || summary.failed > 0
                    self.phase = L10n.string("phase.done")
                    self.progressValue = 1
                    self.resultLines = self.makeResultLines(summary)
                    NSWorkspace.shared.open(destination)
                }
            } catch {
                await MainActor.run {
                    self.isProcessing = false
                    self.hasPendingChange = true
                    self.phase = L10n.string("phase.failed")
                    self.resultLines = [error.localizedDescription]
                }
            }
        }
    }

    private func setProgress(completed: Int, total: Int) {
        progressValue = total > 0 ? Double(completed) / Double(total) : 1
    }

    private func makeResultLines(_ summary: OrganizationSummary) -> [String] {
        var lines = [
            L10n.format("summary.planned", summary.planned),
            L10n.format("summary.copied", summary.copied),
            L10n.format("summary.cloned", summary.cloned),
            L10n.format("summary.moved", summary.moved),
            L10n.format("summary.failed", summary.failed),
            L10n.format("summary.skippedUnsupported", summary.skippedUnsupported),
            L10n.format("summary.skippedMetadata", summary.skippedMetadata),
            L10n.format("summary.skippedExistingIdentical", summary.skippedExistingIdentical)
        ]

        let failedResults = summary.results.compactMap { result -> String? in
            if case .failed(let message) = result.status {
                return "\(result.plannedFile.sourceURL.path): \(message)"
            }
            if case .copiedButSourceDeleteFailed(let message) = result.status {
                return "\(result.plannedFile.sourceURL.path): \(message)"
            }
            return nil
        }

        if !failedResults.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.failedFiles"))
            lines.append(contentsOf: failedResults)
        }

        if !summary.skippedUnsupportedFiles.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.unsupportedFiles"))
            lines.append(contentsOf: summary.skippedUnsupportedFiles.map(\.path))
        }

        if !summary.skippedMetadataFiles.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.metadataSkippedFiles"))
            lines.append(contentsOf: summary.skippedMetadataFiles.map(\.path))
        }

        if !summary.existingIdenticalFiles.isEmpty {
            lines.append("")
            lines.append(L10n.string("result.existingIdenticalFiles"))
            lines.append(contentsOf: summary.existingIdenticalFiles.map {
                "\($0.sourceURL.path) -> \($0.existingTargetURL.path)"
            })
        }
        return lines
    }

    private func markPendingChange() {
        hasPendingChange = true
    }

    private func currentRunSignature() -> RunSignature {
        RunSignature(sourcePath: sourcePath, destinationPath: destinationPath, options: options)
    }

    private func refreshSourceSummary() {
        let path = sourcePath
        guard FileManager.default.fileExists(atPath: path) else {
            sourceSummaryText = path.isEmpty ? "" : L10n.string("source.summaryMissing")
            return
        }

        let requestID = UUID()
        sourceSummaryRequestID = requestID
        let recursive = options.recursive
        let sourceURL = resolvedURL(bookmarkKey: Keys.sourceBookmark, fallbackPath: path)
        sourceSummaryText = L10n.string("source.summaryScanning")

        Task {
            let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }

            do {
                let summary = try await Task.detached {
                    try FileOrganizer().summarizeSource(
                        sourceURL: sourceURL,
                        recursive: recursive
                    )
                }.value

                guard self.sourceSummaryRequestID == requestID else {
                    return
                }
                self.sourceSummaryText = self.makeSourceSummaryText(summary)
            } catch {
                guard self.sourceSummaryRequestID == requestID else {
                    return
                }
                self.sourceSummaryText = error.localizedDescription
            }
        }
    }

    private func makeSourceSummaryText(_ summary: SourceFileSummary) -> String {
        if summary.supportedFiles == 0 {
            return L10n.format(
                "source.summaryEmpty",
                summary.totalFiles,
                summary.unsupportedFiles
            )
        }

        let typeSummary = summary.supportedExtensionCounts
            .map { "\($0.extensionName): \($0.count)" }
            .joined(separator: ", ")

        return L10n.format(
            "source.summary",
            summary.supportedFiles,
            typeSummary,
            summary.unsupportedFiles,
            summary.totalFiles
        )
    }

    private func chooseFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            completion(url)
        }
    }

    private func saveLocation(path: String, bookmarkKey: String, pathKey: String) {
        defaults.set(path, forKey: pathKey)

        guard !path.isEmpty else {
            defaults.removeObject(forKey: bookmarkKey)
            return
        }

        let url = URL(fileURLWithPath: path)
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: bookmarkKey)
        }
    }

    private func loadPath(bookmarkKey: String, pathKey: String) -> String {
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url.path
            }
        }

        return defaults.string(forKey: pathKey) ?? ""
    }

    private func resolvedURL(bookmarkKey: String, fallbackPath: String) -> URL {
        if let data = defaults.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }

        return URL(fileURLWithPath: fallbackPath)
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) {
            defaults.set(data, forKey: Keys.options)
        }
    }

    private func loadOptions() -> OrganizationOptions {
        guard let data = defaults.data(forKey: Keys.options),
              let decoded = try? JSONDecoder().decode(OrganizationOptions.self, from: data) else {
            return .default
        }
        return decoded
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FolderDropBox(
                        title: L10n.string("source.title"),
                        subtitle: L10n.string("source.subtitle"),
                        path: model.sourcePath,
                        detailText: model.sourceSummaryText,
                        detailIsWarning: false,
                        buttonTitle: L10n.string("source.choose"),
                        onChoose: model.chooseSource,
                        onDropURL: model.acceptSource
                    )

                    RulesView(options: $model.options)

                    FolderDropBox(
                        title: L10n.string("destination.title"),
                        subtitle: L10n.string("destination.subtitle"),
                        path: model.destinationPath,
                        detailText: model.destinationWarningText,
                        detailIsWarning: !model.destinationWarningText.isEmpty,
                        buttonTitle: L10n.string("destination.choose"),
                        onChoose: model.chooseDestination,
                        onDropURL: model.acceptDestination
                    )

                    ActionView(model: model)
                }
                .padding()
            }
        }
    }
}

struct FolderDropBox: View {
    let title: String
    let subtitle: String
    let path: String
    let detailText: String
    let detailIsWarning: Bool
    let buttonTitle: String
    let onChoose: () -> Void
    let onDropURL: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [7]))
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
                )
                .overlay {
                    VStack(spacing: 10) {
                        Text(path.isEmpty ? subtitle : path)
                            .font(path.isEmpty ? .body : .system(.body, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .foregroundStyle(path.isEmpty ? .secondary : .primary)

                        if !detailText.isEmpty {
                            Text(detailText)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(detailIsWarning ? .orange : .secondary)
                        }

                        Button(buttonTitle, action: onChoose)
                    }
                    .padding()
                }
                .frame(height: detailText.isEmpty ? 140 : 170)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                    loadDroppedURL(from: providers)
                }
        }
    }

    private func loadDroppedURL(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let string = item as? String {
                url = URL(string: string)
            } else if let droppedURL = item as? URL {
                url = droppedURL
            } else {
                url = nil
            }

            if let url {
                DispatchQueue.main.async {
                    onDropURL(url)
                }
            }
        }

        return true
    }
}

struct RulesView: View {
    @Binding var options: OrganizationOptions

    private var timeZoneIdentifiers: [String] {
        let identifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
        if identifiers.contains(options.timezoneIdentifier) {
            return identifiers
        }
        return ([options.timezoneIdentifier] + identifiers).filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("rules.title"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.string("rules.mode"))

                    Picker("", selection: $options.operationMode) {
                        Text(L10n.string("mode.copy")).tag(OperationMode.copy)
                        Text(L10n.string("mode.move")).tag(OperationMode.move)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer()
                }

                HStack(spacing: 20) {
                    Toggle(L10n.string("rules.recursive"), isOn: $options.recursive)
                    Toggle(L10n.string("rules.cameraFolder"), isOn: $options.includeCameraFolder)
                    Toggle(L10n.string("rules.lensFolder"), isOn: $options.includeLensFolder)

                    Picker(L10n.string("rules.extensionCase"), selection: $options.extensionCase) {
                        Text(L10n.string("extension.preserve")).tag(ExtensionCase.preserve)
                        Text(L10n.string("extension.lower")).tag(ExtensionCase.lower)
                        Text(L10n.string("extension.upper")).tag(ExtensionCase.upper)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                HStack(spacing: 20) {
                    Toggle(L10n.string("rules.renameByDate"), isOn: $options.renameByDate)

                    Picker(L10n.string("rules.timezone"), selection: $options.timezoneIdentifier) {
                        ForEach(timeZoneIdentifiers, id: \.self) { identifier in
                            Text(timeZoneLabel(identifier)).tag(identifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 320)
                }

                HStack(spacing: 20) {
                    Stepper(L10n.format("rules.metadataParallelism", options.metadataConcurrency), value: $options.metadataConcurrency, in: 1...64)
                    Stepper(L10n.format("rules.copyParallelism", options.copyConcurrency), value: $options.copyConcurrency, in: 1...16)
                    Spacer()
                }
            }
            .padding()
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func timeZoneLabel(_ identifier: String) -> String {
        guard let timeZone = TimeZone(identifier: identifier) else {
            return identifier
        }

        let seconds = timeZone.secondsFromGMT()
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        return "\(identifier) (GMT\(sign)\(String(format: "%02d:%02d", hours, minutes)))"
    }
}

struct ActionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.phase)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(model.actionTitle) {
                    model.run()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRun)
            }

            ProgressView(value: model.progressValue)
            Text(model.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.resultLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.resultLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
