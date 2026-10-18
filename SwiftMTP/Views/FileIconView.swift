import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz
import QuickLookUI

// MARK: - Icon Size Model

enum FileIconSize: String, CaseIterable {
    case small
    case medium
    case large

    var iconSide: CGFloat {
        switch self {
        case .small:  return 48
        case .medium: return 64
        case .large:  return 128
        }
    }

    var itemSize: NSSize {
        switch self {
        case .small:  return NSSize(width: 76,  height: 90)
        case .medium: return NSSize(width: 95, height: 110)
        case .large:  return NSSize(width: 148, height: 170)
        }
    }

    var labelFontSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 12
        case .large:  return 13
        }
    }
}

// MARK: - FileIconView

struct FileIconView: View {
    @ObservedObject var manager: MTPManager
    @Binding var selection: Set<MTPFile.ID>
    var onDoubleClick: (MTPFile) -> Void
    var onAddToFavorites: ((MTPFile) -> Void)?
    var isPathFavorited: ((String) -> Bool)?

    @AppStorage("fileIconSize") private var fileIconSizeRaw: String = FileIconSize.medium.rawValue
    @AppStorage("doubleClickToOpenFile") private var doubleClickToOpenFile: Bool = true

    var safeAreaInsets: EdgeInsets = EdgeInsets()

    @StateObject private var alertState = FileViewAlertState()

    @State private var sortState = FileSortState(column: .name, ascending: true)

    private var iconSize: FileIconSize {
        FileIconSize(rawValue: fileIconSizeRaw) ?? .medium
    }

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
                iconGrid
            }
        }
        .fileViewAlerts(alertState: alertState, manager: manager)
    }

    private var iconGrid: some View {
        ZStack {
            VStack(spacing: 0,){
                FileIconCollectionRepresentable(
                    manager: manager,
                    files: sortedFiles,
                    selection: $selection,
                    sortState: $sortState,
                    iconSize: iconSize,
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
                
                Divider()

                // MARK: Info bar
                iconInfoBar
                    .frame(height: 20)
            }

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
        .background(Color(nsColor: .textBackgroundColor))
    }
    
    @ViewBuilder
    private var iconInfoBar: some View {
        if let file = selectedFile {
            HStack(spacing: 16) {
                if #available(macOS 26.0, *) {
                    Spacer()
                        .frame(width: safeAreaInsets.leading)
                }
                
                Text(file.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !file.isDirectory {
                    Text(file.displaySize)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(file.kind)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(verbatim: {
                    let df = DateFormatter()
                    df.dateStyle = .medium
                    df.timeStyle = .short
                    return df.string(from: file.dateModified)
                }())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

private extension FileIconView {
    var sortedFiles: [MTPFile] {
        manager.files.fileSorted(by: sortState)
    }

    var selectedFile: MTPFile? {
        guard selection.count == 1 else { return nil }
        return sortedFiles.first { selection.contains($0.id) }
    }
}

// MARK: - FileIconCollectionRepresentable

private struct FileIconCollectionRepresentable: NSViewRepresentable {
    let manager: MTPManager
    let files: [MTPFile]
    @Binding var selection: Set<MTPFile.ID>
    @Binding var sortState: FileSortState

    var iconSize: FileIconSize
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
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.autohidesScrollers = true

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = iconSize.itemSize
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

        let collectionView = ContextMenuCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.register(
            FileIconItem.self,
            forItemWithIdentifier: FileIconItem.identifier
        )
        collectionView.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL]
        )
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.setDraggingSourceOperationMask([], forLocal: true)

        collectionView.menuProvider = { [weak coordinator = context.coordinator] event in
            coordinator?.menu(for: event, in: collectionView)
        }
        collectionView.onSpaceBarPressed = { [weak coordinator = context.coordinator] in
            coordinator?.togglePreviewPanel()
        }
        collectionView.onCopyAction = { [weak coordinator = context.coordinator] in
            coordinator?.handleCopy()
        }
        collectionView.onPasteAction = { [weak coordinator = context.coordinator] in
            coordinator?.handlePaste()
        }
        collectionView.canPaste = { [weak coordinator = context.coordinator] in
            coordinator?.canPaste() ?? false
        }
        collectionView.onDoubleClickAtPoint = { [weak coordinator = context.coordinator] point in
            coordinator?.handleDoubleClick(at: point)
        }
        collectionView.onReturnPressed = { [weak coordinator = context.coordinator] in
            coordinator?.handleRename()
        }

        scrollView.documentView = collectionView
        context.coordinator.collectionView = collectionView
        collectionView.quickLookController = context.coordinator
        context.coordinator.applySelectionIfNeeded()

        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = false

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let collectionView = nsView.documentView as? ContextMenuCollectionView else { return }
        context.coordinator.parent = self
        context.coordinator.collectionView = collectionView

        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            if layout.itemSize != iconSize.itemSize {
                layout.itemSize = iconSize.itemSize
                layout.invalidateLayout()
            }
        }

        // Only reload when the underlying data actually changes,
        // not on every layout pass (e.g. sidebar animation frames).
        let fileIDs = files.map(\.id)
        if context.coordinator.previousFileIDs != fileIDs
            || context.coordinator.previousIconSize != iconSize {
            context.coordinator.previousFileIDs = fileIDs
            context.coordinator.previousIconSize = iconSize
            collectionView.reloadData()
        }

        context.coordinator.applySelectionIfNeeded()

        if !context.coordinator.didDisableClips {
            disableScrollViewClips(nsView)
            context.coordinator.didDisableClips = true
        }

        DispatchQueue.main.async {
            if let window = collectionView.window, window.firstResponder !== collectionView {
                // Don't steal focus from text fields (e.g. the search bar)
                if let responder = window.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return
                }
                window.makeFirstResponder(collectionView)
            }
        }
    }

    final class Coordinator: NSObject,
                             NSCollectionViewDataSource,
                             NSCollectionViewDelegate,
                             NSCollectionViewDelegateFlowLayout,
                             NSFilePromiseProviderDelegate,
                             QLPreviewPanelDataSource,
                             QLPreviewPanelDelegate {
        var parent: FileIconCollectionRepresentable
        weak var collectionView: ContextMenuCollectionView?

        // Change-tracking to avoid redundant reloadData() during animations
        var previousFileIDs: [MTPFile.ID] = []
        var previousIconSize: FileIconSize = .medium
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

        init(parent: FileIconCollectionRepresentable) {
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

        // MARK: - Data Source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.files.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileIconItem.identifier, for: indexPath)
            guard indexPath.item >= 0, indexPath.item < parent.files.count else { return item }
            let file = parent.files[indexPath.item]
            if let iconItem = item as? FileIconItem {
                iconItem.configure(with: file, iconSize: parent.iconSize, icon: fileThumbnailIcon(for: file, size: parent.iconSize.iconSide))
            }
            return item
        }

        // MARK: - Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToParent()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            syncSelectionToParent()
        }

        private func syncSelectionToParent() {
            guard !isSyncingSelection else { return }
            guard let collectionView else { return }
            let selectedIDs = collectionView.selectionIndexPaths.compactMap { idx -> MTPFile.ID? in
                guard idx.item >= 0, idx.item < parent.files.count else { return nil }
                return parent.files[idx.item].id
            }
            parent.selection = Set(selectedIDs)

            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
                qlHelper.updateQuickLookForSelection(selectedFile: selectedFileForQuickLook())
            }
        }

        func applySelectionIfNeeded() {
            guard let collectionView else { return }
            var target: Set<IndexPath> = []
            for (index, file) in parent.files.enumerated() where parent.selection.contains(file.id) {
                target.insert(IndexPath(item: index, section: 0))
            }
            if collectionView.selectionIndexPaths == target {
                return
            }
            isSyncingSelection = true
            collectionView.deselectItems(at: collectionView.selectionIndexPaths)
            collectionView.selectItems(at: target, scrollPosition: [])
            isSyncingSelection = false
        }

        private var selectedContextFiles: [MTPFile] {
            guard let collectionView else { return [] }
            return collectionView.selectionIndexPaths
                .sorted()
                .compactMap { idx -> MTPFile? in
                    guard idx.item >= 0, idx.item < parent.files.count else { return nil }
                    return parent.files[idx.item]
                }
        }

        // MARK: - Drag-out (NSFilePromiseProvider)

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard indexPath.item >= 0, indexPath.item < parent.files.count else { return nil }
            let file = parent.files[indexPath.item]
            let type: UTType = file.isDirectory ? .folder : (UTType(filenameExtension: file.extension_) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = file.id as NSString
            return provider
        }

        func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
            promiseDragFiles = indexPaths.sorted().compactMap { idx -> MTPFile? in
                guard idx.item >= 0, idx.item < parent.files.count else { return nil }
                return parent.files[idx.item]
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

        // MARK: - Drag-in (external file URLs)

        func collectionView(_ collectionView: NSCollectionView, validateDrop info: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard info.draggingSource as? NSCollectionView !== collectionView else { return [] }
            let urls = PasteboardHelper.readFileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return [] }
            proposedDropOperation.pointee = .before
            return .copy
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop info: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            let urls = PasteboardHelper.readFileURLs(from: info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            parent.onDropExternalFiles(urls)
            return true
        }

        // MARK: - Double click / Open / Rename / Export / Favorites

        func handleDoubleClick(at point: NSPoint) {
            guard let collectionView else { return }
            guard let indexPath = collectionView.selectableIndexPath(at: point) else { return }
            guard indexPath.item >= 0, indexPath.item < parent.files.count else { return }
            let file = parent.files[indexPath.item]

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
        
        @objc func handleOpenSelected() {
            guard let first = selectedContextFiles.first else { return }
            if !first.isDirectory {
                openMTPFileFromCacheOrDownload(first, using: parent.manager)
            } else {
                parent.onOpenSelected(first)
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

        // MARK: - Sort By menu actions

        @objc private func handleSortByName()        { setSortColumn(.name) }
        @objc private func handleSortByDateModified(){ setSortColumn(.dateModified) }
        @objc private func handleSortBySize()        { setSortColumn(.size) }
        @objc private func handleSortByKind()        { setSortColumn(.kind) }
        @objc private func handleSortAscending()     { setSortAscending(true) }
        @objc private func handleSortDescending()    { setSortAscending(false) }

        private func setSortColumn(_ column: FileSortColumn) {
            var newState = parent.sortState
            if newState.column == column {
                newState.ascending.toggle()
            } else {
                newState.column = column
                newState.ascending = true
            }
            parent.sortState = newState
        }

        private func setSortAscending(_ ascending: Bool) {
            var newState = parent.sortState
            newState.ascending = ascending
            parent.sortState = newState
        }

        // MARK: - Copy / Paste

        func handleCopy() {
            guard let collectionView = collectionView else { return }
            let selected = collectionView.selectionIndexPaths
            guard !selected.isEmpty else { return }
            let writers = selected.compactMap { idx in
                self.collectionView(collectionView, pasteboardWriterForItemAt: idx)
            }
            if !writers.isEmpty {
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

        // MARK: - Context menu

        func menu(for event: NSEvent, in collectionView: NSCollectionView) -> NSMenu {
            let pointInView = collectionView.convert(event.locationInWindow, from: nil)
            let clickedIndexPath = (collectionView as? ContextMenuCollectionView)?.selectableIndexPath(at: pointInView)

            if let clickedIndexPath {
                if !collectionView.selectionIndexPaths.contains(clickedIndexPath) {
                    isSyncingSelection = true
                    collectionView.deselectItems(at: collectionView.selectionIndexPaths)
                    collectionView.selectItems(at: [clickedIndexPath], scrollPosition: [])
                    isSyncingSelection = false
                    syncSelectionToParent()
                }
            } else {
                isSyncingSelection = true
                collectionView.deselectItems(at: collectionView.selectionIndexPaths)
                isSyncingSelection = false
                syncSelectionToParent()
            }

            let selectedFiles = selectedContextFiles
            let menu = NSMenu()

            if !selectedFiles.isEmpty {
                if selectedFiles.count == 1 {
                    let openItem = NSMenuItem(title: String(localized: "Open"), action: #selector(handleOpenSelected), keyEquivalent: "")
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

                if selectedFiles.count == 1, let first = selectedFiles.first, first.isDirectory,
                   parent.onAddToFavorites != nil {
                    menu.addItem(NSMenuItem.separator())
                    let addFavItem = NSMenuItem(
                        title: String(localized: "Add to Favorites"),
                        action: #selector(handleAddToFavorites),
                        keyEquivalent: ""
                    )
                    addFavItem.target = self
                    if let isFav = parent.isPathFavorited, isFav(first.path) {
                        addFavItem.action = nil
                        addFavItem.title = String(localized: "Already in Favorites")
                    }
                    menu.addItem(addFavItem)
                }
            }

            menu.addItem(NSMenuItem.separator())

            let newFolder = NSMenuItem(title: String(localized: "New Folder"), action: #selector(handleNewFolder), keyEquivalent: "")
            newFolder.target = self
            menu.addItem(newFolder)

            // Sort By submenu (icon-mode-only sort entry point)
            menu.addItem(NSMenuItem.separator())
            let sortRoot = NSMenuItem(title: String(localized: "Sort By"), action: nil, keyEquivalent: "")
            let sortSubmenu = NSMenu()
            let columnEntries: [(FileSortColumn, Selector)] = [
                (.name,         #selector(handleSortByName)),
                (.dateModified, #selector(handleSortByDateModified)),
                (.size,         #selector(handleSortBySize)),
                (.kind,         #selector(handleSortByKind))
            ]
            for (col, action) in columnEntries {
                let item = NSMenuItem(title: col.localizedTitle, action: action, keyEquivalent: "")
                item.target = self
                if parent.sortState.column == col {
                    item.state = .on
                }
                sortSubmenu.addItem(item)
            }
            sortSubmenu.addItem(NSMenuItem.separator())
            let ascItem = NSMenuItem(title: String(localized: "Ascending"), action: #selector(handleSortAscending), keyEquivalent: "")
            ascItem.target = self
            ascItem.state = parent.sortState.ascending ? .on : .off
            sortSubmenu.addItem(ascItem)
            let descItem = NSMenuItem(title: String(localized: "Descending"), action: #selector(handleSortDescending), keyEquivalent: "")
            descItem.target = self
            descItem.state = parent.sortState.ascending ? .off : .on
            sortSubmenu.addItem(descItem)
            sortRoot.submenu = sortSubmenu
            menu.addItem(sortRoot)

            return menu
        }

        // MARK: - Quick Look Logic
        
        func togglePreviewPanel() {
            qlHelper.togglePreviewPanel(
                selectedFile: selectedFileForQuickLook(),
                makeFirstResponder: { [weak self] in
                    self?.collectionView?.window?.makeFirstResponder(self?.collectionView)
                }
            )
        }
        
        private func selectedFileForQuickLook() -> MTPFile? {
            guard let collectionView else { return nil }
            let selected = collectionView.selectionIndexPaths
            guard selected.count == 1, let idx = selected.first, idx.item >= 0, idx.item < parent.files.count else { return nil }
            return parent.files[idx.item]
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
            guard let collectionView else { return .zero }
            guard let idx = collectionView.selectionIndexPaths.first else { return .zero }
            guard let attrs = collectionView.layoutAttributesForItem(at: idx) else { return .zero }
            let frameInWindow = collectionView.convert(attrs.frame, to: nil)
            return collectionView.window?.convertToScreen(frameInWindow) ?? .zero
        }
        
        func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
            qlHelper.handleKeyEvent(event, panel: panel, forwardTo: collectionView)
        }
        
        func windowWillClose(_ notification: Notification) {
            qlHelper.handleWindowWillClose(notification)
        }
    }
}

// MARK: - FileIconItem

private final class FileIconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileIconItem")

    private let iconHighlight = RoundedFillView()
    private let labelHighlight = RoundedFillView()
    private let thumbnail = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.isEditable = false
        thumbnail.animates = false

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 2
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.drawsBackground = false
        nameLabel.backgroundColor = .clear
        nameLabel.textColor = .labelColor
        nameLabel.cell?.usesSingleLineMode = false
        nameLabel.cell?.wraps = true
        nameLabel.cell?.isScrollable = false
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconHighlight.translatesAutoresizingMaskIntoConstraints = false
        iconHighlight.cornerRadius = 6
        labelHighlight.translatesAutoresizingMaskIntoConstraints = false
        labelHighlight.cornerRadius = 4

        root.addSubview(iconHighlight)
        root.addSubview(thumbnail)
        root.addSubview(labelHighlight)
        root.addSubview(nameLabel)

        let iconW = thumbnail.widthAnchor.constraint(equalToConstant: 72)
        let iconH = thumbnail.heightAnchor.constraint(equalToConstant: 72)
        iconWidthConstraint = iconW
        iconHeightConstraint = iconH

        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumbnail.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            iconW,
            iconH,

            iconHighlight.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            iconHighlight.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            iconHighlight.widthAnchor.constraint(equalTo: thumbnail.widthAnchor, constant: 8),
            iconHighlight.heightAnchor.constraint(equalTo: thumbnail.heightAnchor, constant: 8),

            nameLabel.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 8),
            nameLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -8),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -2),

            labelHighlight.centerXAnchor.constraint(equalTo: nameLabel.centerXAnchor),
            labelHighlight.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            labelHighlight.widthAnchor.constraint(equalTo: nameLabel.widthAnchor, constant: 6),
            labelHighlight.heightAnchor.constraint(equalTo: nameLabel.heightAnchor, constant: 2)
        ])

        self.view = root
        self.imageView = thumbnail
        self.textField = nameLabel
    }

    func configure(with file: MTPFile, iconSize: FileIconSize, icon: NSImage) {
        thumbnail.image = icon
        nameLabel.stringValue = file.name
        nameLabel.font = .systemFont(ofSize: iconSize.labelFontSize)
        nameLabel.preferredMaxLayoutWidth = max(0, iconSize.itemSize.width - 8)
        iconWidthConstraint?.constant = iconSize.iconSide
        iconHeightConstraint?.constant = iconSize.iconSide
        updateSelectionAppearance()
    }

    func containsSelectableContent(at point: NSPoint) -> Bool {
        thumbnail.frame.contains(point) || nameLabel.frame.contains(point)
    }

    private func updateSelectionAppearance() {
        if isSelected {
            iconHighlight.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.20)
            labelHighlight.fillColor = NSColor.controlAccentColor
            nameLabel.textColor = .white
        } else {
            iconHighlight.fillColor = .clear
            labelHighlight.fillColor = .clear
            nameLabel.textColor = .labelColor
        }
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.image = nil
        nameLabel.stringValue = ""
        updateSelectionAppearance()
    }
}




private final class ContextMenuCollectionView: NSCollectionView, NSMenuItemValidation {
    var menuProvider: ((NSEvent) -> NSMenu?)?
    var onSpaceBarPressed: (() -> Void)?
    var onCopyAction: (() -> Void)?
    var onPasteAction: (() -> Void)?
    var canPaste: (() -> Bool)?
    var onDoubleClickAtPoint: ((NSPoint) -> Void)?
    var onReturnPressed: (() -> Void)?
    weak var quickLookController: (NSObject & QLPreviewPanelDataSource & QLPreviewPanelDelegate)?

    override var acceptsFirstResponder: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        return menuProvider?(event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // spacebar
            onSpaceBarPressed?()
        case 36, 76: // return / numpad enter
            if selectionIndexPaths.count == 1 {
                onReturnPressed?()
            }
        default:
            super.keyDown(with: event)
        }
    }

    func selectableIndexPath(at point: NSPoint) -> IndexPath? {
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        guard let item = item(at: indexPath) as? FileIconItem else { return indexPath }

        let pointInItem = item.view.convert(point, from: self)
        return item.containsSelectableContent(at: pointInItem) ? indexPath : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount == 2 {
            if selectableIndexPath(at: point) != nil {
                onDoubleClickAtPoint?(point)
            } else if indexPathForItem(at: point) != nil {
                handleBackgroundStyleClick(for: event)
            } else {
                super.mouseDown(with: event)
            }
            return
        }

        if indexPathForItem(at: point) != nil, selectableIndexPath(at: point) == nil {
            handleBackgroundStyleClick(for: event)
            return
        }

        super.mouseDown(with: event)
    }

    private func handleBackgroundStyleClick(for event: NSEvent) {
        window?.makeFirstResponder(self)
        let selectionModifiers = event.modifierFlags.intersection([.shift, .command])
        if selectionModifiers.isEmpty {
            deselectAll(nil)
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
            return !selectionIndexPaths.isEmpty
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

