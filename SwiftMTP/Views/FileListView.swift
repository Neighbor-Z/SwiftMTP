import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz
import QuickLookUI

struct FileListView: View {
    @ObservedObject var manager: MTPManager
    @Binding var selection: Set<MTPFile.ID>
    var onDoubleClick: (MTPFile) -> Void
    var onAddToFavorites: ((MTPFile) -> Void)?
    var isPathFavorited: ((String) -> Bool)?

    @AppStorage("fileListFontSize") private var fileListFontSize: Int = 12
    @AppStorage("doubleClickToOpenFile") private var doubleClickToOpenFile: Bool = true

    @State private var isShowingNewFolderDialog = false
    @State private var isShowingRenameDialog = false
    @State private var showError = false
    @State private var isShowingReplaceAlert = false
    @State private var newFolderName = "Untitled Folder"
    @State private var fileToRename: MTPFile?
    @State private var newFileName = ""
    @State private var sortState = FileListSortState(column: .name, ascending: true)
    @State private var urls: [URL] = []
    @State private var pendingUploadURLs: [URL] = []
    @State private var isShowingExportReplaceAlert = false
    @State private var pendingExportDestinationURL: URL?
    @State private var pendingExportFiles: [MTPFile] = []
    @State private var sheetController: NSWindowController?

    var body: some View {
        Group {
            if !manager.connectionState.isConnected {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.isLoading {
                loadingView
            } else {
                fileList
            }
        }
        .alert(String(localized: "New Folder"), isPresented: $isShowingNewFolderDialog) {
            TextField(String(localized: "Folder name"), text: $newFolderName)
            Button("Create") {
                manager.createFolder(named: newFolderName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(localized: "Enter a name for the new folder."))
        }
        .alert(String(localized: "Rename"), isPresented: $isShowingRenameDialog) {
            TextField(String(localized: "New Name"), text: $newFileName)
            Button(String(localized: "Rename")) {
                if let file = fileToRename {
                    manager.renameFile(file, to: newFileName)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                fileToRename = nil
            }
        } message: {
            if let file = fileToRename {
                Text(String(format: String(localized: "Enter a new name for \"%@\"."), file.name))
            }
        }
        .alert("Error", isPresented: $showError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text("path issue")
        }
        .alert(String(localized: "Replace and merge the existing items?"), isPresented: $isShowingReplaceAlert) {
            Button(String(localized: "Replace")) {
                guard !pendingUploadURLs.isEmpty else { return }
                urls = pendingUploadURLs
                pendingUploadURLs.removeAll()
                showImportSheet()
            }
            Button("Cancel", role: .cancel) {
                pendingUploadURLs.removeAll()
            }
        }
        .alert(String(localized: "Replace and merge the existing items?"), isPresented: $isShowingExportReplaceAlert) {
            Button(String(localized: "Replace")) {
                guard let destinationURL = pendingExportDestinationURL else { return }
                guard !pendingExportFiles.isEmpty else { return }
                manager.download(files: pendingExportFiles, destinationURL: destinationURL)
                pendingExportFiles.removeAll()
                pendingExportDestinationURL = nil
            }
            Button("Cancel", role: .cancel) {
                pendingExportFiles.removeAll()
                pendingExportDestinationURL = nil
            }
        }
    }

    private func showImportSheet() {
        guard let window = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }) else {
            return
        }
        
        let contentView = ImportDialogContent(
            urls: urls,
            onCancel: { [self] in
                DispatchQueue.main.async {
                    self.closeImportSheet()
                }
            },
            onConfirm: { [self] in
                self.manager.upload(sourceURLs: self.urls)
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
        
        window.beginSheet(sheetWindow) { response in
            self.sheetController = nil
        }
        
        self.sheetController = NSWindowController(window: sheetWindow)
    }

    private func closeImportSheet() {
        guard let sheetWindow = sheetController?.window else { return }
        if let parentWindow = sheetWindow.sheetParent {
            parentWindow.endSheet(sheetWindow)
        } else {
            return
        }
    }

    private func handleImportRequest(_ droppedURLs: [URL]) {
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
        showImportSheet()
    }

    private func handleExportRequest(_ files: [MTPFile]) {
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

    private func hasExportConflicts(files: [MTPFile], destinationURL: URL) -> Bool {
        for file in files {
            let targetURL = destinationURL.appendingPathComponent(file.name)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                return true
            }
        }
        return false
    }

    private var fileList: some View {
        ZStack {
            FileListTableRepresentable(
                manager: manager,
                files: sortedFiles,
                selection: $selection,
                sortState: $sortState,
                fontSize: fileListFontSize,
                doubleClickToOpenFile: doubleClickToOpenFile,
                onDoubleClick: onDoubleClick,
                onNewFolder: {
                    newFolderName = "Untitled Folder"
                    isShowingNewFolderDialog = true
                },
                onOpenSelected: { file in
                    onDoubleClick(file)
                },
                onExportSelected: { selectedFiles in
                    handleExportRequest(selectedFiles)
                },
                onDeleteSelected: { _ in
                    NotificationCenter.default.post(name: NSNotification.Name("SwiftMTPDeleteAction"), object: nil)
                },
                onDropExternalFiles: { droppedURLs in
                    handleImportRequest(droppedURLs)
                },
                onRename: { file in
                    fileToRename = file
                    newFileName = file.name
                    isShowingRenameDialog = true
                },
                onAddToFavorites: onAddToFavorites,
                isPathFavorited: isPathFavorited
            )

            if sortedFiles.isEmpty {
                emptyView
                    .allowsHitTesting(false)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading files…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
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

private extension FileListView {
    var sortedFiles: [MTPFile] {
        manager.files.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let comparison = compare(lhs, rhs, by: sortState.column)
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            if sortState.ascending {
                return comparison == .orderedAscending
            }
            return comparison == .orderedDescending
        }
    }

    func compare(_ lhs: MTPFile, _ rhs: MTPFile, by column: FileListColumn) -> ComparisonResult {
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
}

private enum FileListColumn: String, CaseIterable {
    case name = "name"
    case dateModified = "dateModified"
    case size = "size"
    case kind = "kind"
}

private struct FileListSortState: Equatable {
    var column: FileListColumn
    var ascending: Bool
}

private struct FileListTableRepresentable: NSViewRepresentable {
    let manager: MTPManager
    let files: [MTPFile]
    @Binding var selection: Set<MTPFile.ID>
    @Binding var sortState: FileListSortState

    var fontSize: Int
    var doubleClickToOpenFile: Bool

    let onDoubleClick: (MTPFile) -> Void
    let onNewFolder: () -> Void
    let onOpenSelected: (MTPFile) -> Void
    let onExportSelected: ([MTPFile]) -> Void
    let onDeleteSelected: ([MTPFile]) -> Void
    let onDropExternalFiles: ([URL]) -> Void
    let onRename: (MTPFile) -> Void
    let onAddToFavorites: ((MTPFile) -> Void)?
    let isPathFavorited: ((String) -> Bool)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let tableView = ContextMenuTableView(frame: .zero)
        tableView.focusRingType = .default
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 4, height: 2)
        tableView.rowHeight = CGFloat(context.coordinator.parent.fontSize) * 2
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.selectionHighlightStyle = .regular
        tableView.usesAutomaticRowHeights = false
        tableView.allowsTypeSelect = true
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL]
        )
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([], forLocal: true)

        for spec in ColumnSpec.defaultSpecs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id.rawValue))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.minWidth
            column.maxWidth = spec.maxWidth
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id.rawValue, ascending: true)
            tableView.addTableColumn(column)
        }

        tableView.menuProvider = { [weak coordinator = context.coordinator] clickedRow in
            coordinator?.menu(for: clickedRow)
        }

        scrollView.documentView = tableView

        context.coordinator.tableView = tableView
        tableView.quickLookController = context.coordinator
        
        tableView.onSpaceBarPressed = { [weak coordinator = context.coordinator] in
            coordinator?.togglePreviewPanel()
        }
        tableView.onCopyAction = { [weak coordinator = context.coordinator] in
            coordinator?.handleCopy()
        }
        tableView.onPasteAction = { [weak coordinator = context.coordinator] in
            coordinator?.handlePaste()
        }
        tableView.canPaste = { [weak coordinator = context.coordinator] in
            coordinator?.canPaste() ?? false
        }
        tableView.onReturnPressed = { [weak coordinator = context.coordinator] in
            coordinator?.handleRename()
        }
        context.coordinator.applySortDescriptorIfNeeded()
        context.coordinator.applySelectionIfNeeded()

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? ContextMenuTableView else { return }

        context.coordinator.parent = self
        context.coordinator.tableView = tableView

        let newAlternating = !files.isEmpty
        if tableView.usesAlternatingRowBackgroundColors != newAlternating {
            tableView.usesAlternatingRowBackgroundColors = newAlternating
        }

        let targetRowHeight = CGFloat(fontSize) * 2
        if tableView.rowHeight != targetRowHeight {
            tableView.rowHeight = targetRowHeight
        }

        context.coordinator.applySortDescriptorIfNeeded()

        // Only reload the table when the underlying data actually changes,
        // not on every layout pass (e.g. sidebar animation frames).
        let fileIDs = files.map(\.id)
        if context.coordinator.previousFileIDs != fileIDs
            || context.coordinator.previousFontSize != fontSize {
            context.coordinator.previousFileIDs = fileIDs
            context.coordinator.previousFontSize = fontSize
            tableView.reloadData()
        }

        context.coordinator.applySelectionIfNeeded()

        DispatchQueue.main.async {
            if let window = tableView.window, window.firstResponder != tableView {
                // Don't steal focus from text fields (e.g. the search bar)
                if let responder = window.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return
                }
                window.makeFirstResponder(tableView)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var parent: FileListTableRepresentable
        weak var tableView: NSTableView?

        // Change-tracking to avoid redundant reloadData() during animations
        var previousFileIDs: [MTPFile.ID] = []
        var previousFontSize: Int = 0
        var didDisableClips = false

        private var isSyncingSelection = false
        
        // Batch promise drag state
        private var promiseDragFiles: [MTPFile] = []
        private var promiseBatchStarted = false
        private var promiseBatchError: Error? = nil
        private var promiseBatchSemaphore = DispatchSemaphore(value: 0)
        
        // Quick Look Overlay State
        private var currentQLFile: MTPFile?
        private var activeQLURL: URL?
        private var overlayController: NSHostingController<QuickLookOverlayView>?
        
        private static let sharedPromiseQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()

        private lazy var dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(parent: FileListTableRepresentable) {
            self.parent = parent
            super.init()
            
            NotificationCenter.default.addObserver(self, selector: #selector(handleOpenActionFromNotification), name: NSNotification.Name("SwiftMTPOpenFileAction"), object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleQuickLookActionFromNotification), name: NSNotification.Name("SwiftMTPToggleQuickLook"), object: nil)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleOpenActionFromNotification() {
            handleOpenSelected()
        }

        @objc private func handleQuickLookActionFromNotification() {
            togglePreviewPanel()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.files.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < parent.files.count else { return nil }
            guard let tableColumn else { return nil }
            let file = parent.files[row]
            guard let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

            switch column {
            case .name:
                return makeNameCell(for: file, tableView: tableView)
            case .dateModified:
                return makeTextCell(
                    identifier: "DateCell",
                    text: dateFormatter.string(from: file.dateModified),
                    alignment: .left,
                    font: .systemFont(ofSize: CGFloat(parent.fontSize - 1)),
                    tableView: tableView
                )
            case .size:
                return makeTextCell(
                    identifier: "SizeCell",
                    text: file.displaySize,
                    alignment: .right,
                    font: .monospacedDigitSystemFont(ofSize: CGFloat(parent.fontSize - 1), weight: .regular),
                    tableView: tableView
                )
            case .kind:
                return makeTextCell(
                    identifier: "KindCell",
                    text: file.kind,
                    alignment: .left,
                    font: .systemFont(ofSize: CGFloat(parent.fontSize - 1)),
                    tableView: tableView
                )
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0, row < parent.files.count else { return nil }
            let file = parent.files[row]
            let type: UTType = file.isDirectory ? .folder : (UTType(filenameExtension: file.extension_) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = file.id as NSString
            return provider
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            promiseDragFiles = rowIndexes.compactMap { idx -> MTPFile? in
                guard idx >= 0, idx < parent.files.count else { return nil }
                return parent.files[idx]
            }
            promiseBatchStarted = false
            promiseBatchError = nil
            promiseBatchSemaphore = DispatchSemaphore(value: 0)
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            promiseFile(for: filePromiseProvider)?.name ?? "Untitled"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            let destination = normalizedPromiseDestination(url)
            
            if !promiseBatchStarted {
                // First promise: trigger batch download of ALL dragged files
                promiseBatchStarted = true
                parent.manager.downloadPromiseBatch(files: promiseDragFiles, to: destination) { [weak self] error in
                    self?.promiseBatchError = error
                    self?.promiseBatchSemaphore.signal()
                }
                promiseBatchSemaphore.wait()
                completionHandler(promiseBatchError)
            } else {
                completionHandler(promiseBatchError)
            }
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            Self.sharedPromiseQueue
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            guard let tableView else { return }
            let selectedIDs = tableView.selectedRowIndexes.compactMap { row -> MTPFile.ID? in
                guard row >= 0, row < parent.files.count else { return nil }
                return parent.files[row].id
            }
            parent.selection = Set(selectedIDs)
            
            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
                updateQuickLookForSelection()
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first else { return }
            guard let key = descriptor.key, let column = FileListColumn(rawValue: key) else { return }
            let newState = FileListSortState(column: column, ascending: descriptor.ascending)
            if parent.sortState != newState {
                parent.sortState = newState
            }
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView !== tableView else { return [] }
            let urls = readFileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = readFileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            parent.onDropExternalFiles(urls)
            return true
        }

        func applySortDescriptorIfNeeded() {
            guard let tableView else { return }
            let current = tableView.sortDescriptors.first
            let target = NSSortDescriptor(key: parent.sortState.column.rawValue, ascending: parent.sortState.ascending)
            if current?.key == target.key && current?.ascending == target.ascending {
                return
            }
            tableView.sortDescriptors = [target]
        }

        func applySelectionIfNeeded() {
            guard let tableView else { return }
            var target = IndexSet()
            for (index, file) in parent.files.enumerated() where parent.selection.contains(file.id) {
                target.insert(index)
            }
            if tableView.selectedRowIndexes == target {
                return
            }
            isSyncingSelection = true
            tableView.selectRowIndexes(target, byExtendingSelection: false)
            isSyncingSelection = false
        }

        private var selectedContextFiles: [MTPFile] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { row in
                guard row >= 0, row < parent.files.count else { return nil }
                return parent.files[row]
            }
        }

        func menu(for clickedRow: Int) -> NSMenu {
            if let tableView {
                if clickedRow >= 0 {
                    if !tableView.selectedRowIndexes.contains(clickedRow) {
                        isSyncingSelection = true
                        tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                        isSyncingSelection = false
                        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
                    }
                } else {
                    isSyncingSelection = true
                    tableView.deselectAll(nil)
                    isSyncingSelection = false
                    tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
                }
            }

            let selectedFiles = selectedContextFiles
            let menu = NSMenu()

            if !selectedFiles.isEmpty {
                // Open only for a single selected folder
                if selectedFiles.count == 1, let _ = selectedFiles.first {
                    let openItem = NSMenuItem(title: String(localized: "Open"), action: #selector(handleOpenSelected), keyEquivalent: "")
                    // openItem.keyEquivalentModifierMask = [.command]
                    openItem.target = self
                    menu.addItem(openItem)

                    let qlItem = NSMenuItem(title: String(localized: "Quick Look"), action: #selector(handleQuickLookActionFromNotification), keyEquivalent: "")
                    qlItem.target = self
                    menu.addItem(qlItem)
                    
                    let renameItem = NSMenuItem(title: String(localized: "Rename"), action: #selector(handleRename), keyEquivalent: "")
                    renameItem.target = self
                    menu.addItem(renameItem)
                }

                let exportItem = NSMenuItem(title: String(localized: "Export"), action: #selector(handleExportSelected), keyEquivalent: "")
                exportItem.target = self
                menu.addItem(exportItem)

                let deleteItem = NSMenuItem(title: String(localized: "Delete"), action: #selector(handleDeleteSelected), keyEquivalent: "")
                deleteItem.target = self
                menu.addItem(deleteItem)

                // Add to Favorites – only for a single selected folder
                if selectedFiles.count == 1, let first = selectedFiles.first, first.isDirectory,
                   parent.onAddToFavorites != nil {
                    menu.addItem(NSMenuItem.separator())
                    let addFavItem = NSMenuItem(
                        title: String(localized: "Add to Favorites"),
                        action: #selector(handleAddToFavorites),
                        keyEquivalent: ""
                    )
                    // addFavItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
                    addFavItem.target = self
                    // Disable if already favorited
                    if let isFav = parent.isPathFavorited, isFav(first.path) {
                        addFavItem.action = nil
                        addFavItem.title = String(localized: "Already in Favorites")
                    }
                    menu.addItem(addFavItem)
                }
            }
            
            menu.addItem(NSMenuItem.separator())
            
            // New Folder always available
            let newFolder = NSMenuItem(title: String(localized: "New Folder"), action: #selector(handleNewFolder), keyEquivalent: "")
            newFolder.target = self
            menu.addItem(newFolder)

            return menu
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0, row < parent.files.count else { return }
            let file = parent.files[row]

            // If "double-click to open files" is on and this is not a directory, open it locally.
            if parent.doubleClickToOpenFile && !file.isDirectory {
                openFileFromCacheOrDownload(file)
            } else {
                parent.onDoubleClick(file)
            }
        }

        /// Open a device file: serve from local cache if available, otherwise silently
        /// download to the QuickLook temp dir first, then open with the default app.
        private func openFileFromCacheOrDownload(_ file: MTPFile) {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftMTP_QuickLook", isDirectory: true)
            let cachedURL = tempDir.appendingPathComponent(file.name)

            // Check whether the file is fully cached (exists and non-empty).
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

            // Not cached — ensure the temp directory exists, then download silently.
            try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            parent.manager.downloadAndPreview(file: file, to: tempDir) { error in
                DispatchQueue.main.async {
                    guard error == nil else { return }
                    NSWorkspace.shared.open(cachedURL)
                }
            }
        }

        @objc private func handleNewFolder() {
            parent.onNewFolder()
        }

        @objc func handleRename() {
            guard let first = selectedContextFiles.first else { return }
            parent.onRename(first)
        }

        @objc private func handleOpenSelected() {
            guard let first = selectedRows().first else { return }
            guard first >= 0, first < parent.files.count else { return }
            let file = parent.files[first]
            
            if !file.isDirectory {
                openFileFromCacheOrDownload(file)
            } else {
                parent.onOpenSelected(file)
            }
        }

        @objc private func handleExportSelected() {
            let selectedFiles = selectedContextFiles
            guard !selectedFiles.isEmpty else { return }
            parent.onExportSelected(selectedFiles)
        }

        @objc private func handleDeleteSelected() {
            let selectedFiles = selectedContextFiles
            guard !selectedFiles.isEmpty else { return }
            parent.onDeleteSelected(selectedFiles)
        }

        @objc private func handleAddToFavorites() {
            guard let first = selectedContextFiles.first, first.isDirectory else { return }
            parent.onAddToFavorites?(first)
        }
        
        func handleCopy() {
            // copy feature is not ready by far
            guard let tableView = tableView else { return }
            let selectedRows = tableView.selectedRowIndexes
            guard !selectedRows.isEmpty else { return }

            // Get Pasteboard Writers of all selected items
            let writers = selectedRows.compactMap { row in
                self.tableView(tableView, pasteboardWriterForRow: row)
            }

            if !writers.isEmpty {
                // clear and write to clipboard
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects(writers)
            }
        }

        /// Whether the system clipboard contains pasteable files.
        func canPaste() -> Bool {
            return !readFilesFromPasteboard().isEmpty
        }

        func handlePaste() {
            let pastedURLs = readFilesFromPasteboard()
            guard !pastedURLs.isEmpty else { return }
            
            // Handle paste with same logic as external drop
            parent.onDropExternalFiles(pastedURLs)
        }

        private func selectedRows() -> [Int] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.map { $0 }
        }

        private func makeNameCell(for file: MTPFile, tableView: NSTableView) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier("NameCell-\(parent.fontSize)")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let container = NSTableCellView()
                container.identifier = identifier

                let iconView = NSImageView()
                iconView.translatesAutoresizingMaskIntoConstraints = false
                iconView.imageScaling = .scaleProportionallyDown

                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: CGFloat(parent.fontSize))
                label.lineBreakMode = .byTruncatingMiddle
                label.maximumNumberOfLines = 1

                container.imageView = iconView
                container.textField = label
                container.addSubview(iconView)
                container.addSubview(label)
                
                let iconWidth = CGFloat(parent.fontSize) * 1.5
                let iconHeight = CGFloat(parent.fontSize) * 1.33

                NSLayoutConstraint.activate([
                    iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                    iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    iconView.widthAnchor.constraint(equalToConstant: iconWidth),
                    iconView.heightAnchor.constraint(equalToConstant: iconHeight),

                    label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                    label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])

                return container
            }()

            cell.imageView?.image = getThumbnailIcon(for: file)
            cell.textField?.stringValue = file.name
            cell.textField?.textColor = .labelColor
            return cell
        }

        private func makeTextCell(identifier: String, text: String, alignment: NSTextAlignment, font: NSFont, tableView: NSTableView) -> NSView {
            let nsIdentifier = NSUserInterfaceItemIdentifier("\(identifier)-\(parent.fontSize)")
            let cell = tableView.makeView(withIdentifier: nsIdentifier, owner: nil) as? NSTableCellView ?? {
                let container = NSTableCellView()
                container.identifier = nsIdentifier

                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.maximumNumberOfLines = 1
                label.lineBreakMode = .byTruncatingTail

                container.textField = label
                container.addSubview(label)

                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                    label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                return container
            }()

            cell.textField?.stringValue = text
            cell.textField?.alignment = alignment
            cell.textField?.font = font
            cell.textField?.textColor = .labelColor
            return cell
        }

        private func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
            return objects.map { $0 as URL }
        }
        
        private func readFilesFromPasteboard() -> [URL] {
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

        private func getThumbnailIcon(for file: MTPFile) -> NSImage {
            if file.isDirectory {
                return NSWorkspace.shared.icon(for: .folder)
            }
            
            let ext = file.extension_.lowercased()
            
            // Try to get icon using file extension with UTType
            if !ext.isEmpty {
                if let utType = UTType(filenameExtension: ext) {
                    if let icon = NSWorkspace.shared.icon(for: utType) as NSImage? {
                        return icon
                    }
                }
            }
            
            // Fallback to generic file icon
            return NSWorkspace.shared.icon(for: .data)
        }

        private func promiseFile(for provider: NSFilePromiseProvider) -> MTPFile? {
            guard let fileID = provider.userInfo as? NSString else { return nil }
            return parent.files.first { $0.id == fileID as String }
        }

        private func normalizedPromiseDestination(_ url: URL) -> URL {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
            // Some drag destinations provide the final promised-item URL instead of a writable directory.
            // For import we need the parent directory as destination.
            return url.deletingLastPathComponent()
        }

        private func iconTint(for file: MTPFile) -> NSColor {
            let ext = file.extension_.lowercased()
            switch ext {
            case "jpg", "jpeg", "png", "gif", "heic", "webp":
                return NSColor.systemBlue.withAlphaComponent(0.92)
            case "mp4", "mov", "avi", "mkv", "3gp":
                return NSColor.systemRed.withAlphaComponent(0.84)
            case "mp3", "aac", "flac", "wav", "m4a":
                return NSColor.systemPurple.withAlphaComponent(0.84)
            case "pdf":
                return NSColor.systemIndigo.withAlphaComponent(0.86)
            case "zip", "rar", "7z":
                return NSColor.systemOrange.withAlphaComponent(0.86)
            case "apk":
                return NSColor.systemGreen.withAlphaComponent(0.84)
            case "":
                return NSColor.controlAccentColor.withAlphaComponent(0.65)
            default:
                return NSColor.secondaryLabelColor.withAlphaComponent(0.85)
            }
        }
        
        // MARK: - Quick Look Logic
        
        func togglePreviewPanel() {
            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().orderOut(nil)
            } else {
                guard let file = selectedFileForQuickLook() else { return }
                currentQLFile = file
                tableView?.window?.makeFirstResponder(tableView)
                QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
            }
        }
        
        private func selectedFileForQuickLook() -> MTPFile? {
            guard let tableView else { return nil }
            let selectedRows = tableView.selectedRowIndexes
            guard selectedRows.count == 1, let row = selectedRows.first, row >= 0, row < parent.files.count else { return nil }
            return parent.files[row]
        }
        
        private func updateQuickLookForSelection() {
            guard let file = selectedFileForQuickLook() else { return }
            if currentQLFile?.id != file.id {
                currentQLFile = file
                QLPreviewPanel.shared().reloadData()
            }
        }
        
        private func preparePreviewItem(for file: MTPFile) -> URL? {
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
                    triggerSilentDownload(file: file, dest: tempDir)
                } else {
                    mountOverlay(state: .prompt(file))
                }
                
                return fileURL
            } catch {
                print("QuickLook prepare error: \(error)")
                return nil
            }
        }
        
        private func triggerSilentDownload(file: MTPFile, dest: URL) {
            parent.manager.downloadAndPreview(file: file, to: dest) { [weak self] error in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if self.currentQLFile?.id == file.id {
                        self.removeOverlay()
                        QLPreviewPanel.shared().refreshCurrentPreviewItem()
                    }
                }
            }
        }
        
        private static let overlayViewIdentifier = NSUserInterfaceItemIdentifier("SwiftMTP_QLOverlay")
        
        private func mountOverlay(state: QuickLookOverlayState) {
            guard let panel = QLPreviewPanel.shared() else { return }
            guard let contentView = panel.contentView else { return }
            
            // Remove ALL existing overlay views (tracked + any orphans)
            purgeOverlayViews(from: contentView)
            overlayController = nil
            
            let onLoad: () -> Void = { [weak self] in
                guard let self = self, let file = self.currentQLFile else { return }
                self.mountOverlay(state: .loading)
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMTP_QuickLook")
                self.triggerSilentDownload(file: file, dest: tempDir)
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
        
        private func removeOverlay() {
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
        
        // MARK: - QLPreviewPanelDataSource
        
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            return currentQLFile != nil ? 1 : 0
        }
        
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            guard let currentFile = currentQLFile else { return nil }
            return preparePreviewItem(for: currentFile) as QLPreviewItem?
        }
        
        // MARK: - QLPreviewPanelDelegate
        
        func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
            guard let tableView else { return .zero }
            let selectedRow = tableView.selectedRow
            guard selectedRow >= 0 else { return .zero }
            let rowRect = tableView.rect(ofRow: selectedRow)
            let windowRect = tableView.convert(rowRect, to: nil)
            return tableView.window?.convertToScreen(windowRect) ?? .zero
        }
        
        func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
            if event.type == .keyDown {
                if event.keyCode == 49 { 
                    panel.orderOut(nil)
                    return true
                } else if event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 {
                    tableView?.keyDown(with: event)
                    return true
                }
            }
            return false
        }
        
        func windowWillClose(_ notification: Notification) {
            if let panel = notification.object as? QLPreviewPanel, panel == QLPreviewPanel.shared() {
                removeOverlay()
                currentQLFile = nil
            }
        }
    }
}

private struct ColumnSpec {
    let id: FileListColumn
    let title: String
    let minWidth: CGFloat
    let width: CGFloat
    let maxWidth: CGFloat

    static let defaultSpecs: [ColumnSpec] = [
        ColumnSpec(id: .name, title: String(localized: "Name"), minWidth: 220, width: 300, maxWidth: 520),
        ColumnSpec(id: .dateModified, title: String(localized: "Date Modified"), minWidth: 150, width: 180, maxWidth: 240),
        ColumnSpec(id: .size, title: String(localized: "Size"), minWidth: 80, width: 100, maxWidth: 140),
        ColumnSpec(id: .kind, title: String(localized: "Kind"), minWidth: 120, width: 160, maxWidth: 220)
    ]
}

private final class ContextMenuTableView: NSTableView, NSMenuItemValidation {
    var menuProvider: ((Int) -> NSMenu?)?
    var onSpaceBarPressed: (() -> Void)?
    var onCopyAction: (() -> Void)?
    var onPasteAction: (() -> Void)?
    var canPaste: (() -> Bool)?
    var onReturnPressed: (() -> Void)?
    weak var quickLookController: (NSObject & QLPreviewPanelDataSource & QLPreviewPanelDelegate)?
    
    override var acceptsFirstResponder: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        return menuProvider?(row)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // spacebar
            onSpaceBarPressed?()
        case 36, 76: // return / numpad enter
            if numberOfSelectedRows == 1 {
                onReturnPressed?()
            }
        default:
            super.keyDown(with: event)
        }
    }
    
    @objc func copy(_ sender: Any?) {
        onCopyAction?()
    }

    // MARK: - Paste support via responder chain (Edit menu + Cmd+V)

    /// Standard paste: action — called by Edit > Paste menu item and Cmd+V shortcut
    @objc func paste(_ sender: Any?) {
        onPasteAction?()
    }

    /// Delegates validation to the Coordinator via the canPaste closure.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return numberOfSelectedRows > 0
        }
        if menuItem.action == #selector(paste(_:)) {
            return canPaste?() ?? false
        }
        return true
    }
    
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return quickLookController != nil
    }
    
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = quickLookController
        panel.dataSource = quickLookController
    }
    
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = nil
        panel.dataSource = nil
    }
}

// MARK: - ImportDialogContent (Sheet content)

private struct ImportDialogContent: View {
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
