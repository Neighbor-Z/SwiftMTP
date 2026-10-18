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

    var safeAreaInsets: EdgeInsets = EdgeInsets()

    @StateObject private var alertState = FileViewAlertState()

    @State private var sortState = FileSortState(column: .name, ascending: true)

    var body: some View {
        Group {
            if !manager.connectionState.isConnected {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.isLoading {
                HStack(spacing: 0) {
                    if #available(macOS 26.0, *) {
                        Spacer()
                            .frame(width: safeAreaInsets.leading)
                    }
                    FileLoadingView()
                }
            } else {
                fileList
            }
        }
        .fileViewAlerts(alertState: alertState, manager: manager)
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
                safeAreaInsets: safeAreaInsets,
                onDoubleClick: onDoubleClick,
                onNewFolder: {
                    alertState.newFolderName = "Untitled Folder"
                    alertState.isShowingNewFolderDialog = true
                },
                onOpenSelected: { file in
                    onDoubleClick(file)
                },
                onExportSelected: { selectedFiles in
                    alertState.handleExportRequest(selectedFiles, manager: manager)
                },
                onDeleteSelected: { _ in
                    NotificationCenter.default.post(name: NSNotification.Name("SwiftMTPDeleteAction"), object: nil)
                },
                onDropExternalFiles: { droppedURLs in
                    alertState.handleImportRequest(droppedURLs, manager: manager)
                },
                onRename: { file in
                    alertState.fileToRename = file
                    alertState.newFileName = file.name
                    alertState.isShowingRenameDialog = true
                },
                onAddToFavorites: onAddToFavorites,
                isPathFavorited: isPathFavorited
            )

            if sortedFiles.isEmpty {
                HStack(spacing: 0) {
                    if #available(macOS 26.0, *) {
                        Spacer()
                            .frame(width: safeAreaInsets.leading)
                    }
                    FileEmptyView()
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

private extension FileListView {
    var sortedFiles: [MTPFile] {
        manager.files.fileSorted(by: sortState)
    }
}

// private enum FileListColumn: String, CaseIterable {
//     case name = "name"
//     case dateModified = "dateModified"
//     case size = "size"
//     case kind = "kind"
// }

// private struct FileListSortState: Equatable {
//     var column: FileListColumn
//     var ascending: Bool
// }

private struct FileListTableRepresentable: NSViewRepresentable {
    let manager: MTPManager
    let files: [MTPFile]
    @Binding var selection: Set<MTPFile.ID>
    @Binding var sortState: FileSortState

    var fontSize: Int
    var doubleClickToOpenFile: Bool
    var safeAreaInsets: EdgeInsets = EdgeInsets()

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

        for spec in FileListColumnSpec.defaultSpecs {
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

        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = false

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

        if !context.coordinator.didDisableClips {
            disableScrollViewClips(nsView)
            context.coordinator.didDisableClips = true
        }

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
        
        // Quick Look
        let qlHelper = QuickLookHelper()
        
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
            guard let column = FileSortColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }

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
            FilePromiseHelper.promiseFile(for: filePromiseProvider, in: parent.files)?.name ?? "Untitled"
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            let destination = FilePromiseHelper.normalizedPromiseDestination(url)
            
            if !promiseBatchStarted {
                // First promise: trigger batch download of ALL dragged files
                promiseBatchStarted = true
                parent.manager.downloadPromiseBatch(files: promiseDragFiles, to: destination) { [weak self] error in
                    self?.promiseBatchError = error
                    self?.promiseBatchSemaphore.signal()
                }
                // Block on sharedPromiseQueue (NOT main thread) until batch completes
                promiseBatchSemaphore.wait()
                completionHandler(promiseBatchError)
            } else {
                // Subsequent promises: batch already completed (serial queue),
                // file is already at destination. Return immediately.
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
                qlHelper.updateQuickLookForSelection(selectedFile: selectedFileForQuickLook())
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first else { return }
            guard let key = descriptor.key, let column = FileSortColumn(rawValue: key) else { return }
            let newState = FileSortState(column: column, ascending: descriptor.ascending)
            if parent.sortState != newState {
                parent.sortState = newState
            }
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView !== tableView else { return [] }
            let urls = PasteboardHelper.readFileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = PasteboardHelper.readFileURLs(from: info.draggingPasteboard)
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
                openMTPFileFromCacheOrDownload(file, using: parent.manager)
            } else {
                parent.onDoubleClick(file)
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
                openMTPFileFromCacheOrDownload(file, using: parent.manager)
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
            return !PasteboardHelper.readFilesFromPasteboard().isEmpty
        }

        func handlePaste() {
            let pastedURLs = PasteboardHelper.readFilesFromPasteboard()
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

            cell.imageView?.image = fileThumbnailIcon(for: file)
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

        // MARK: - Helpers

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
            qlHelper.togglePreviewPanel(
                selectedFile: selectedFileForQuickLook(),
                makeFirstResponder: { [weak self] in
                    self?.tableView?.window?.makeFirstResponder(self?.tableView)
                }
            )
        }
        
        private func selectedFileForQuickLook() -> MTPFile? {
            guard let tableView else { return nil }
            let selectedRows = tableView.selectedRowIndexes
            guard selectedRows.count == 1, let row = selectedRows.first, row >= 0, row < parent.files.count else { return nil }
            return parent.files[row]
        }
        
        // MARK: - QLPreviewPanelDataSource
        
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            qlHelper.numberOfPreviewItems
        }
        
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            qlHelper.previewItem(using: parent.manager)
        }
        
        // MARK: - QLPreviewPanelDelegate
        
        func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
            guard let tableView else { return .zero }
            let selectedRow = tableView.selectedRow
            guard selectedRow >= 0 else { return .zero }

            // Find the name column and its cell view to get the icon frame
            let nameColumnID = NSUserInterfaceItemIdentifier(FileSortColumn.name.rawValue)
            if let nameColumnIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == nameColumnID }),
               let cellView = tableView.view(atColumn: nameColumnIndex, row: selectedRow, makeIfNecessary: false) as? NSTableCellView,
               let iconView = cellView.imageView {
                // Convert the icon's bounds to the tableView's coordinate system, then to screen
                let iconRectInTable = iconView.convert(iconView.bounds, to: tableView)
                let windowRect = tableView.convert(iconRectInTable, to: nil)
                return tableView.window?.convertToScreen(windowRect) ?? .zero
            }

            // Fallback: use the entire row rect
            let rowRect = tableView.rect(ofRow: selectedRow)
            let windowRect = tableView.convert(rowRect, to: nil)
            return tableView.window?.convertToScreen(windowRect) ?? .zero
        }
        
        func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
            qlHelper.handleKeyEvent(event, panel: panel, forwardTo: tableView)
        }
        
        func windowWillClose(_ notification: Notification) {
            qlHelper.handleWindowWillClose(notification)
        }
    }
}

private struct FileListColumnSpec {
    let id: FileSortColumn
    let title: String
    let minWidth: CGFloat
    let width: CGFloat
    let maxWidth: CGFloat

    static let defaultSpecs: [FileListColumnSpec] = [
        FileListColumnSpec(id: .name, title: String(localized: "Name"), minWidth: 220, width: 300, maxWidth: 520),
        FileListColumnSpec(id: .dateModified, title: String(localized: "Date Modified"), minWidth: 150, width: 180, maxWidth: 240),
        FileListColumnSpec(id: .size, title: String(localized: "Size"), minWidth: 80, width: 100, maxWidth: 140),
        FileListColumnSpec(id: .kind, title: String(localized: "Kind"), minWidth: 80, width: 100, maxWidth: 220)
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

