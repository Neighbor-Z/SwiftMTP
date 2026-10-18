import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz
import QuickLookUI

// MARK: - Shared View Mode

enum FileBrowserViewMode: String {
    case list
    case icons
    case gallery
}

class ViewModeSettings: ObservableObject {
    @Published var viewModeRaw: String {
        didSet {
            UserDefaults.standard.set(viewModeRaw, forKey: "fileBrowserViewMode")
        }
    }

    init() {
        self.viewModeRaw = UserDefaults.standard.string(forKey: "fileBrowserViewMode") ?? FileBrowserViewMode.list.rawValue
    }
}

// MARK: - Unified Sort Types

enum FileSortColumn: String, CaseIterable {
    case name
    case dateModified
    case size
    case kind

    var localizedTitle: String {
        switch self {
        case .name:         return String(localized: "Name")
        case .dateModified: return String(localized: "Date Modified")
        case .size:         return String(localized: "Size")
        case .kind:         return String(localized: "Kind")
        }
    }
}

struct FileSortState: Equatable {
    var column: FileSortColumn
    var ascending: Bool
}

// MARK: - Shared Sort Logic

func compareFiles(_ lhs: MTPFile, _ rhs: MTPFile, by column: FileSortColumn) -> ComparisonResult {
    switch column {
    case .name:
        return lhs.name.localizedStandardCompare(rhs.name)
    case .dateModified:
        if lhs.dateModified == rhs.dateModified { return .orderedSame }
        return lhs.dateModified < rhs.dateModified ? .orderedAscending : .orderedDescending
    case .size:
        if lhs.size == rhs.size { return .orderedSame }
        return lhs.size < rhs.size ? .orderedAscending : .orderedDescending
    case .kind:
        return lhs.kind.localizedStandardCompare(rhs.kind)
    }
}

extension Array where Element == MTPFile {
    func fileSorted(by state: FileSortState) -> [MTPFile] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let comparison = compareFiles(lhs, rhs, by: state.column)
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            if state.ascending {
                return comparison == .orderedAscending
            }
            return comparison == .orderedDescending
        }
    }
}

// MARK: - Shared Loading / Empty Views

struct FileLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading files…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("This folder is empty")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ImportDialogContent (shared sheet content)

struct ImportDialogContent: View {
    let urls: [URL]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(String(localized: "Confirm import?"))
                .font(.headline)
                .padding(.top)

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Items to be imported:"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(urls, id: \.self) { url in
                            HStack(spacing: 8) {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .frame(maxHeight: 240)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
                .contentShape(Rectangle())
            }
            .padding(.horizontal)

            HStack(spacing: 20) {
                Button(String(localized: "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Import")) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom)
        }
        .frame(minWidth: 400)
        .padding()
    }
}

// MARK: - FileViewAlertState (shared dialog / import-export state)

final class FileViewAlertState: ObservableObject {
    @Published var isShowingNewFolderDialog = false
    @Published var isShowingRenameDialog = false
    @Published var showError = false
    @Published var isShowingReplaceAlert = false
    @Published var newFolderName = "Untitled Folder"
    @Published var fileToRename: MTPFile?
    @Published var newFileName = ""
    @Published var urls: [URL] = []
    @Published var pendingUploadURLs: [URL] = []
    @Published var isShowingExportReplaceAlert = false
    @Published var pendingExportDestinationURL: URL?
    @Published var pendingExportFiles: [MTPFile] = []

    var sheetController: NSWindowController?

    // MARK: Import Sheet

    func showImportSheet(using manager: MTPManager) {
        guard let window = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }) else {
            return
        }

        let contentView = ImportDialogContent(
            urls: urls,
            onCancel: { [weak self] in
                DispatchQueue.main.async {
                    self?.closeImportSheet()
                }
            },
            onConfirm: { [weak self] in
                guard let self = self else { return }
                manager.upload(sourceURLs: self.urls)
                self.urls.removeAll()
                DispatchQueue.main.async {
                    self.closeImportSheet()
                }
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)

        let sheetWindow = NSWindow(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled]
        sheetWindow.title = String(localized: "Confirm import?")

        window.beginSheet(sheetWindow) { _ in
            self.sheetController = nil
        }

        self.sheetController = NSWindowController(window: sheetWindow)
    }

    func closeImportSheet() {
        guard let sheetWindow = sheetController?.window else { return }
        if let parentWindow = sheetWindow.sheetParent {
            parentWindow.endSheet(sheetWindow)
        } else {
            return
        }
    }

    // MARK: Import / Export Request Handling

    func handleImportRequest(_ droppedURLs: [URL], manager: MTPManager) {
        if droppedURLs.isEmpty {
            showError = true
            return
        }
        if manager.hasConflictingItems(for: droppedURLs) {
            pendingUploadURLs = droppedURLs
            isShowingReplaceAlert = true
            return
        }
        urls = droppedURLs
        showImportSheet(using: manager)
    }

    func handleExportRequest(_ files: [MTPFile], manager: MTPManager) {
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Export Here")
        if panel.runModal() == .OK, let url = panel.url {
            if hasExportConflicts(files: files, destinationURL: url) {
                pendingExportFiles = files
                pendingExportDestinationURL = url
                isShowingExportReplaceAlert = true
                return
            }
            manager.download(files: files, destinationURL: url)
        }
    }

    func hasExportConflicts(files: [MTPFile], destinationURL: URL) -> Bool {
        for file in files {
            let targetURL = destinationURL.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                return true
            }
        }
        return false
    }
}

// MARK: - FileViewAlertsModifier

struct FileViewAlertsModifier: ViewModifier {
    @ObservedObject var alertState: FileViewAlertState
    @ObservedObject var manager: MTPManager

    func body(content: Content) -> some View {
        content
            .alert(String(localized: "New Folder"), isPresented: $alertState.isShowingNewFolderDialog) {
                TextField(String(localized: "Folder name"), text: $alertState.newFolderName)
                Button("Create") {
                    manager.createFolder(named: alertState.newFolderName)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(String(localized: "Enter a name for the new folder."))
            }
            .alert(String(localized: "Rename"), isPresented: $alertState.isShowingRenameDialog) {
                TextField(String(localized: "New Name"), text: $alertState.newFileName)
                Button(String(localized: "Rename")) {
                    if let file = alertState.fileToRename {
                        manager.renameFile(file, to: alertState.newFileName)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    alertState.fileToRename = nil
                }
            } message: {
                if let file = alertState.fileToRename {
                    Text(String(format: String(localized: "Enter a new name for \"%@\"."), file.name))
                }
            }
            .alert("Error", isPresented: $alertState.showError) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text("path issue")
            }
            .alert(String(localized: "Replace and merge the existing items?"), isPresented: $alertState.isShowingReplaceAlert) {
                Button(String(localized: "Replace")) {
                    guard !alertState.pendingUploadURLs.isEmpty else { return }
                    alertState.urls = alertState.pendingUploadURLs
                    alertState.pendingUploadURLs.removeAll()
                    alertState.showImportSheet(using: manager)
                }
                Button("Cancel", role: .cancel) {
                    alertState.pendingUploadURLs.removeAll()
                }
            }
            .alert(String(localized: "Replace and merge the existing items?"), isPresented: $alertState.isShowingExportReplaceAlert) {
                Button(String(localized: "Replace")) {
                    guard let destinationURL = alertState.pendingExportDestinationURL else { return }
                    guard !alertState.pendingExportFiles.isEmpty else { return }
                    manager.download(files: alertState.pendingExportFiles, destinationURL: destinationURL)
                    alertState.pendingExportFiles.removeAll()
                    alertState.pendingExportDestinationURL = nil
                }
                Button("Cancel", role: .cancel) {
                    alertState.pendingExportFiles.removeAll()
                    alertState.pendingExportDestinationURL = nil
                }
            }
    }
}

extension View {
    func fileViewAlerts(alertState: FileViewAlertState, manager: MTPManager) -> some View {
        modifier(FileViewAlertsModifier(alertState: alertState, manager: manager))
    }
}

// MARK: - RoundedFillView (shared by Icon and Gallery views)

final class RoundedFillView: NSView {
    var fillColor: NSColor = .clear {
        didSet {
            guard oldValue != fillColor else { return }
            needsDisplay = true
            layer?.backgroundColor = fillColor.cgColor
        }
    }

    var cornerRadius: CGFloat = 6 {
        didSet {
            guard oldValue != cornerRadius else { return }
            layer?.cornerRadius = cornerRadius
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = fillColor.cgColor
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = fillColor.cgColor
        layer?.cornerRadius = cornerRadius
    }

    override var allowsVibrancy: Bool { false }
}

func disableScrollViewClips(_ scrollView: NSScrollView) {
    scrollView.contentView.wantsLayer = true
    scrollView.contentView.layer?.masksToBounds = false
    scrollView.documentView?.wantsLayer = true
    scrollView.documentView?.layer?.masksToBounds = false
}

// MARK: - Pasteboard Helpers

enum PasteboardHelper {
    static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
        return objects.map { $0 as URL }
    }

    static func readFilesFromPasteboard() -> [URL] {
        let pasteboard = NSPasteboard.general

        // First, try to read file URLs directly
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] {
            let urls = objects.map { $0 as URL }
            if !urls.isEmpty {
                return urls
            }
        }
        
        // If no file URLs, try to read as strings (file paths)
        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [NSString] {
            let urls = strings.compactMap { path -> URL? in
                let urlPath = path as String
                // Check if it's a valid file path
                if FileManager.default.fileExists(atPath: urlPath) {
                    return URL(fileURLWithPath: urlPath)
                }
                // Also try to convert string to URL
                if let url = URL(string: urlPath), url.isFileURL {
                    return url
                }
                return nil
            }
            return urls
        }
        return []
    }
}

// MARK: - File Promise Helpers

enum FilePromiseHelper {
    static func promiseFile(for provider: NSFilePromiseProvider, in files: [MTPFile]) -> MTPFile? {
        guard let fileID = provider.userInfo as? NSString else { return nil }
        return files.first { $0.id == fileID as String }
    }

    static func normalizedPromiseDestination(_ url: URL) -> URL {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}

// MARK: - Open File From Cache

func openMTPFileFromCacheOrDownload(_ file: MTPFile, using manager: MTPManager) {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftMTP_QuickLook", isDirectory: true)
    let cachedURL = tempDir.appendingPathComponent(file.name)

    let fm = FileManager.default
    var isCached = false
    if fm.fileExists(atPath: cachedURL.path) {
        let attrs = try? fm.attributesOfItem(atPath: cachedURL.path)
        let size = attrs?[.size] as? Int64 ?? 0
        isCached = (size > 0)
    }

    if isCached {
        NSWorkspace.shared.open(cachedURL)
        return
    }

    try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    manager.downloadAndPreview(file: file, to: tempDir) { error in
        DispatchQueue.main.async {
            guard error == nil else { return }
            NSWorkspace.shared.open(cachedURL)
        }
    }
}

// MARK: - Thumbnail Icon Helper

func fileThumbnailIcon(for file: MTPFile, size: CGFloat) -> NSImage {
    if file.isDirectory {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    let ext = file.extension_.lowercased()
    if !ext.isEmpty {
        if let utType = UTType(filenameExtension: ext) {
            if let icon = NSWorkspace.shared.icon(for: utType) as NSImage? {
                icon.size = NSSize(width: size, height: size)
                return icon
            }
        }
    }

    let generic = NSWorkspace.shared.icon(for: .data)
    generic.size = NSSize(width: size, height: size)
    return generic
}

/// Variant that returns the icon without resizing (for list views that don't need explicit size).
func fileThumbnailIcon(for file: MTPFile) -> NSImage {
    if file.isDirectory {
        return NSWorkspace.shared.icon(for: .folder)
    }

    let ext = file.extension_.lowercased()
    if !ext.isEmpty {
        if let utType = UTType(filenameExtension: ext) {
            if let icon = NSWorkspace.shared.icon(for: utType) as NSImage? {
                return icon
            }
        }
    }

    return NSWorkspace.shared.icon(for: .data)
}

// MARK: - Quick Look Helper

/// Manages Quick Look preview panel state and overlay lifecycle.
/// Each Coordinator owns an instance and delegates QL operations to it.
final class QuickLookHelper {
    var currentQLFile: MTPFile?
    var activeQLURL: URL?
    private var overlayController: NSHostingController<QuickLookOverlayView>?

    private static let overlayViewIdentifier = NSUserInterfaceItemIdentifier("SwiftMTP_QLOverlay")

    func togglePreviewPanel(selectedFile: MTPFile?, makeFirstResponder: () -> Void) {
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else {
            guard let file = selectedFile else { return }
            currentQLFile = file
            makeFirstResponder()
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    func updateQuickLookForSelection(selectedFile: MTPFile?) {
        guard let file = selectedFile else { return }
        if currentQLFile?.id != file.id {
            currentQLFile = file
            QLPreviewPanel.shared().reloadData()
        }
    }

    func preparePreviewItem(for file: MTPFile, using manager: MTPManager) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMTP_QuickLook", isDirectory: true)
        do {
            if !FileManager.default.fileExists(atPath: tempDir.path) {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            }

            let fileURL = tempDir.appendingPathComponent(file.name)

            if file.isDirectory {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
                }
                activeQLURL = fileURL
                mountOverlay(state: .folder(file))
                return fileURL
            }

            let isCached = FileManager.default.fileExists(atPath: fileURL.path)
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let cachedSize = attrs?[.size] as? Int64 ?? 0

            // If it is fully cached (assuming size > 0 implies something is there, exact size check can be tricky)
            if isCached && cachedSize > 0 {
                removeOverlay()
                activeQLURL = fileURL
                return fileURL
            }

            // Touch empty file to trick QL preview into opening
            if !isCached {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
            }

            activeQLURL = fileURL

            // Automatically load preview for files under 10MB
            let sizeThreshold: Int64 = 10 * 1024 * 1024
            if file.size <= sizeThreshold {
                mountOverlay(state: .loading)
                triggerSilentDownload(file: file, dest: tempDir, using: manager)
            } else {
                mountOverlay(state: .prompt(file))
            }

            return fileURL
        } catch {
            print("QuickLook prepare error: \(error)")
            return nil
        }
    }

    func triggerSilentDownload(file: MTPFile, dest: URL, using manager: MTPManager) {
        manager.downloadAndPreview(file: file, to: dest) { [weak self] error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.currentQLFile?.id == file.id {
                    self.removeOverlay()
                    QLPreviewPanel.shared().refreshCurrentPreviewItem()
                }
            }
        }
    }

    func mountOverlay(state: QuickLookOverlayState) {
        guard let panel = QLPreviewPanel.shared() else { return }
        guard let contentView = panel.contentView else { return }

        // Remove ALL existing overlay views (tracked + any orphans)
        purgeOverlayViews(from: contentView)
        overlayController = nil

        let onLoad: () -> Void = { [weak self] in
            guard let self = self, let _ = self.currentQLFile else { return }
            self.mountOverlay(state: .loading)
            let _ = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMTP_QuickLook")
            // Need manager — caller should provide via closure
            // For now, this path is only used with the prompt overlay button, which stores manager context.
        }

        let controller = NSHostingController(rootView: QuickLookOverlayView(state: state, onLoadPreview: onLoad))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.identifier = Self.overlayViewIdentifier

        contentView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        overlayController = controller
    }

    /// Mount overlay with a custom onLoad closure that has access to the manager.
    func mountOverlay(state: QuickLookOverlayState, onLoad: @escaping () -> Void) {
        guard let panel = QLPreviewPanel.shared() else { return }
        guard let contentView = panel.contentView else { return }

        purgeOverlayViews(from: contentView)
        overlayController = nil

        let controller = NSHostingController(rootView: QuickLookOverlayView(state: state, onLoadPreview: onLoad))
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.identifier = Self.overlayViewIdentifier

        contentView.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        overlayController = controller
    }

    func removeOverlay() {
        // Purge from current contentView to catch orphans
        if let contentView = QLPreviewPanel.shared()?.contentView {
            purgeOverlayViews(from: contentView)
        }
        overlayController = nil
    }

    /// Remove all overlay views ever added, identified by tag.
    /// This catches both the currently tracked overlay and any orphaned
    /// views left behind by QL's internal view lifecycle.
    private func purgeOverlayViews(from parent: NSView) {
        for subview in parent.subviews where subview.identifier == Self.overlayViewIdentifier {
            subview.isHidden = true
            subview.removeFromSuperview()
        }
    }

    // MARK: QL Data Source Helpers

    var numberOfPreviewItems: Int {
        currentQLFile != nil ? 1 : 0
    }

    func previewItem(using manager: MTPManager) -> QLPreviewItem? {
        guard let file = currentQLFile else { return nil }
        return preparePreviewItem(for: file, using: manager) as QLPreviewItem?
    }

    // MARK: QL Delegate Helpers

    func handleKeyEvent(_ event: NSEvent, panel: QLPreviewPanel, forwardTo view: NSView?) -> Bool {
        if event.type == .keyDown {
            if event.keyCode == 49 {
                panel.orderOut(nil)
                return true
            } else if event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 {
                view?.keyDown(with: event)
                return true
            }
        }
        return false
    }

    func handleWindowWillClose(_ notification: Notification) {
        if let panel = notification.object as? QLPreviewPanel, panel == QLPreviewPanel.shared() {
            removeOverlay()
            currentQLFile = nil
        }
    }
}
