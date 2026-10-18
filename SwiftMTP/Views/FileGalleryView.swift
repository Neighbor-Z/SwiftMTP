import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers
import Quartz
import QuickLookUI

// MARK: - Gallery filmstrip constants

private let galleryFilmstripIconSide: CGFloat = 52
private let galleryFilmstripItemSize = NSSize(width: 76, height: 90)
private let galleryFilmstripLabelFont: CGFloat = 11
private let galleryPreviewIconSize: CGFloat = 512

// MARK: - FileGalleryView (Finder-style Gallery Mode)

struct FileGalleryView: View {
    @ObservedObject var manager: MTPManager
    @Binding var selection: Set<MTPFile.ID>
    var onDoubleClick: (MTPFile) -> Void
    var onAddToFavorites: ((MTPFile) -> Void)?
    var isPathFavorited: ((String) -> Bool)?

    @AppStorage("doubleClickToOpenFile") private var doubleClickToOpenFile: Bool = true

    var safeAreaInsets: EdgeInsets = EdgeInsets()

    @StateObject private var alertState = FileViewAlertState()

    @State private var sortState = FileSortState(column: .name, ascending: true)

    // MARK: Inline gallery preview state
    @State private var inlinePreviewURL: URL?
    @State private var inlinePreviewLoading: Bool = false
    @State private var inlinePreviewFileID: MTPFile.ID?

    private var primarySelectedFile: MTPFile? {
        guard selection.count == 1, let firstID = selection.first else { return nil }
        return sortedFiles.first { $0.id == firstID }
    }

    // MARK: - Media preview helpers

    /// All extensions whose files will be downloaded and shown via QLPreviewView.
    private static let previewableExtensions: Set<String> = [
        // photos
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif",
        "webp", "ico", "svg",
        // raw
        "raw", "arw", "cr2", "cr3", "nef", "orf", "rw2", "dng", "raf", "pef",
        // video
        "mp4", "mov", "m4v",
        // documents
        "pdf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key",
        "txt", "rtf", "rtfd",
        "html", "htm", "xml", "json", "md"
    ]

    private func isPreviewableMedia(_ file: MTPFile) -> Bool {
        guard !file.isDirectory else { return false }
        return Self.previewableExtensions.contains(file.extension_.lowercased())
    }

    private func loadInlinePreview(for file: MTPFile) {
        guard !inlinePreviewLoading else { return }
        guard inlinePreviewFileID != file.id || inlinePreviewURL == nil else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMTP_QuickLook", isDirectory: true)
        let destURL = tempDir.appendingPathComponent(file.name)

        // Already cached with real content?
        if FileManager.default.fileExists(atPath: destURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let sz = attrs[.size] as? Int64, sz > 0 {
            inlinePreviewFileID = file.id
            inlinePreviewURL = destURL
            return
        }

        // Download then surface the URL
        inlinePreviewLoading = true
        inlinePreviewFileID = file.id
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager.downloadAndPreview(file: file, to: tempDir) { error in
            DispatchQueue.main.async {
                self.inlinePreviewLoading = false
                guard error == nil, self.inlinePreviewFileID == file.id else { return }
                self.inlinePreviewURL = destURL
            }
        }
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
                galleryContent
            }
        }
        .fileViewAlerts(alertState: alertState, manager: manager)
    }

    private var galleryContent: some View {
        ZStack {
            VStack(spacing: 0) {
                // MARK: Large preview area
                HStack(spacing: 0) {
                    if #available(macOS 26.0, *) {
                        Spacer()
                            .frame(width: safeAreaInsets.leading)
                    }
                    galleryPreviewArea
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                Divider()

                // MARK: Horizontal filmstrip
                GalleryFilmstripRepresentable(
                    manager: manager,
                    files: sortedFiles,
                    selection: $selection,
                    sortState: $sortState,
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
                .frame(height: 100)

                Divider()

                // MARK: Info bar
                galleryInfoBar
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
    private var galleryPreviewArea: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            if let file = primarySelectedFile {
                if isPreviewableMedia(file) {
                    if let previewURL = inlinePreviewURL, inlinePreviewFileID == file.id {
                        // Pure AppKit container – SwiftUI has no involvement in event routing.
                        // This restores zoom/scroll for images/PDFs and controls for video.
                        GalleryPreviewRepresentable(url: previewURL)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.15), value: previewURL)
                    } else if inlinePreviewLoading && inlinePreviewFileID == file.id {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else if file.size > 10 * 1024 * 1024 {
                        VStack(spacing: 12) {
                            Image(nsImage: getPreviewIcon(for: file))
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 128)
                            Button("Load Preview") {
                                loadInlinePreview(for: file)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(30)
                    } else {
                        ProgressView()
                            .scaleEffect(0.8)
                            .onAppear { loadInlinePreview(for: file) }
                    }
                } else {
                    // --- Non-previewable: icon ---
                    Image(nsImage: getPreviewIcon(for: file))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(40)
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: selection)
                }
            }
        }
        .onChange(of: selection) { _ in
            inlinePreviewURL = nil
            inlinePreviewLoading = false
            if let file = primarySelectedFile,
               isPreviewableMedia(file),
               file.size <= 10 * 1024 * 1024 {
                loadInlinePreview(for: file)
            }
        }
    }

    @ViewBuilder
    private var galleryInfoBar: some View {
        if let file = primarySelectedFile {
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

    private func getPreviewIcon(for file: MTPFile) -> NSImage {
        let sz = NSSize(width: galleryPreviewIconSize, height: galleryPreviewIconSize)
        if file.isDirectory {
            let icon = NSWorkspace.shared.icon(for: .folder)
            icon.size = sz
            return icon
        }
        let ext = file.extension_.lowercased()
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext),
           let icon = NSWorkspace.shared.icon(for: utType) as NSImage? {
            icon.size = sz
            return icon
        }
        let generic = NSWorkspace.shared.icon(for: .data)
        generic.size = sz
        return generic
    }

}

private extension FileGalleryView {
    var sortedFiles: [MTPFile] {
        manager.files.fileSorted(by: sortState)
    }
}



// MARK: - GalleryFilmstripRepresentable

private struct GalleryFilmstripRepresentable: NSViewRepresentable {
    let manager: MTPManager
    let files: [MTPFile]
    @Binding var selection: Set<MTPFile.ID>
    @Binding var sortState: FileSortState

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
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.autohidesScrollers = true

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = galleryFilmstripItemSize
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let collectionView = GalleryCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.register(
            GalleryFilmstripItem.self,
            forItemWithIdentifier: GalleryFilmstripItem.identifier
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
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let collectionView = nsView.documentView as? GalleryCollectionView else { return }
        context.coordinator.parent = self
        context.coordinator.collectionView = collectionView

        // Only reload when the underlying data actually changes,
        // not on every layout pass (e.g. sidebar animation frames).
        let fileIDs = files.map(\.id)
        if context.coordinator.previousFileIDs != fileIDs {
            context.coordinator.previousFileIDs = fileIDs
            collectionView.reloadData()
        }

        context.coordinator.applySelectionIfNeeded()

        if !context.coordinator.didDisableClips {
            disableScrollViewClips(nsView)
            context.coordinator.didDisableClips = true
        }
    }

    final class Coordinator: NSObject,
                             NSCollectionViewDataSource,
                             NSCollectionViewDelegate,
                             NSCollectionViewDelegateFlowLayout,
                             NSFilePromiseProviderDelegate,
                             QLPreviewPanelDataSource,
                             QLPreviewPanelDelegate {
        var parent: GalleryFilmstripRepresentable
        weak var collectionView: GalleryCollectionView?

        // Change-tracking to avoid redundant reloadData() during animations
        var previousFileIDs: [MTPFile.ID] = []
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
            queue.qualityOfService = .utility
            return queue
        }()

        private lazy var dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(parent: GalleryFilmstripRepresentable) {
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
            let item = collectionView.makeItem(withIdentifier: GalleryFilmstripItem.identifier, for: indexPath)
            guard indexPath.item >= 0, indexPath.item < parent.files.count else { return item }
            let file = parent.files[indexPath.item]
            if let iconItem = item as? GalleryFilmstripItem {
                iconItem.configure(with: file, icon: fileThumbnailIcon(for: file, size: galleryFilmstripIconSide))
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
            let clickedIndexPath = (collectionView as? GalleryCollectionView)?.selectableIndexPath(at: pointInView)

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

// MARK: - GalleryFilmstripItem

private final class GalleryFilmstripItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryFilmstripItem")

    private let borderView = RoundedFillView()   // gray highlight behind icon
    private let labelBgView = RoundedFillView()  // blue rounded rect behind label
    private let thumbnail = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

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
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.drawsBackground = false
        nameLabel.textColor = .labelColor
        nameLabel.font = .systemFont(ofSize: galleryFilmstripLabelFont)
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        borderView.translatesAutoresizingMaskIntoConstraints = false
        labelBgView.translatesAutoresizingMaskIntoConstraints = false
        labelBgView.cornerRadius = 3

        root.addSubview(borderView)
        root.addSubview(thumbnail)
        root.addSubview(labelBgView)
        root.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumbnail.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: galleryFilmstripIconSide),
            thumbnail.heightAnchor.constraint(equalToConstant: galleryFilmstripIconSide),

            borderView.centerXAnchor.constraint(equalTo: thumbnail.centerXAnchor),
            borderView.centerYAnchor.constraint(equalTo: thumbnail.centerYAnchor),
            borderView.widthAnchor.constraint(equalTo: thumbnail.widthAnchor, constant: 8),
            borderView.heightAnchor.constraint(equalTo: thumbnail.heightAnchor, constant: 8),

            nameLabel.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 8),
            nameLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -4),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -3),

            // blue rounded rect sits 2pt inside the label bounds
            labelBgView.centerXAnchor.constraint(equalTo: nameLabel.centerXAnchor),
            labelBgView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            labelBgView.widthAnchor.constraint(equalTo: nameLabel.widthAnchor, constant: 6),
            labelBgView.heightAnchor.constraint(equalTo: nameLabel.heightAnchor, constant: 2)
        ])

        self.view = root
        self.imageView = thumbnail
        self.textField = nameLabel
    }

    func configure(with file: MTPFile, icon: NSImage) {
        thumbnail.image = icon
        nameLabel.stringValue = file.name
        nameLabel.preferredMaxLayoutWidth = max(0, galleryFilmstripItemSize.width - 8)
        updateSelectionAppearance()
    }

    func containsSelectableContent(at point: NSPoint) -> Bool {
        thumbnail.frame.contains(point) || nameLabel.frame.contains(point)
    }

    private func updateSelectionAppearance() {
        if isSelected {
            // Finder-style: gray rounded rect on icon, blue rounded rect behind label
            borderView.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.18)
            labelBgView.fillColor = .controlAccentColor
            nameLabel.textColor = .white
        } else {
            borderView.fillColor = .clear
            labelBgView.fillColor = .clear
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



// MARK: - GalleryCollectionView

private final class GalleryCollectionView: NSCollectionView, NSMenuItemValidation {
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
        guard let item = item(at: indexPath) as? GalleryFilmstripItem else { return indexPath }

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

// MARK: - GalleryPreviewContainer + GalleryPreviewRepresentable
//
// Video files must NOT go through QLPreviewView – QL tries to render video via a
// remote XPC process (QLUIServiceBaseDisplayBundle) which fails in sandboxed apps,
// producing black frames and no controls. AVPlayerView is the correct AppKit-native
// video player and has no such restriction.
//
// For images/PDFs/documents QLPreviewView is used directly, promoted to first
// responder so scroll/zoom events reach its internal NSScrollView unobstructed.

private final class GalleryPreviewContainer: NSView {

    // MARK: State
    private var qlView: QLPreviewView?
    private var playerView: AVPlayerView?
    private var loadedURL: URL?

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v"
    ]

    // Let subviews handle all events.
    override var acceptsFirstResponder: Bool { false }

    // MARK: Public interface

    func load(url: URL) {
        guard url != loadedURL else { return }
        loadedURL = url
        tearDown()
        if Self.videoExtensions.contains(url.pathExtension.lowercased()) {
            loadVideo(url: url)
        } else {
            loadQL(url: url)
        }
    }

    func clear() {
        loadedURL = nil
        tearDown()
    }

    // MARK: Private – video path (AVPlayerView)

    private func loadVideo(url: URL) {
        let pv = AVPlayerView()
        pv.controlsStyle = .default
        pv.showsFullScreenToggleButton = true
        pv.videoGravity = .resizeAspect
        pv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pv)

        // Pin edge-to-edge; .resizeAspect handles letterboxing internally.
        let leading = pv.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = pv.trailingAnchor.constraint(equalTo: trailingAnchor)
        let top = pv.topAnchor.constraint(equalTo: topAnchor)
        let bottom = pv.bottomAnchor.constraint(equalTo: bottomAnchor)
        
        // Lower priority to prevent constraint conflicts (e.g. width == 0)
        // when SwiftUI temporarily collapses the view during layout.
        leading.priority = .defaultHigh
        trailing.priority = .defaultHigh
        top.priority = .defaultHigh
        bottom.priority = .defaultHigh
        
        NSLayoutConstraint.activate([leading, trailing, top, bottom])

        let player = AVPlayer(url: url)
        pv.player = player
        playerView = pv

        player.play()
        promote(pv)
    }

    // MARK: Private – non-video path (QLPreviewView)

    private func loadQL(url: URL) {
        guard let ql = QLPreviewView(frame: bounds, style: .normal) else { return }
        ql.autostarts = true
        ql.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ql)
        NSLayoutConstraint.activate([
            ql.leadingAnchor.constraint(equalTo: leadingAnchor),
            ql.trailingAnchor.constraint(equalTo: trailingAnchor),
            ql.topAnchor.constraint(equalTo: topAnchor),
            ql.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        ql.previewItem = url as QLPreviewItem
        qlView = ql
        promote(ql)
    }

    // MARK: Private – helpers

    private func tearDown() {
        qlView?.previewItem = nil
        qlView?.removeFromSuperview()
        qlView = nil
        playerView?.player?.pause()
        playerView?.player = nil
        playerView?.removeFromSuperview()
        playerView = nil
    }

    /// Give the active preview view first-responder status so AppKit delivers
    /// scroll/magnification/keyboard events directly to it.
    private func promote(_ view: NSView) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let view else { return }
            self?.window?.makeFirstResponder(view)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let ql = qlView   { promote(ql) }
        if let pv = playerView { promote(pv) }
    }
}

/// Thin NSViewRepresentable – SwiftUI only does layout; all events handled in AppKit.
private struct GalleryPreviewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> GalleryPreviewContainer {
        let container = GalleryPreviewContainer()
        container.load(url: url)
        return container
    }

    func updateNSView(_ container: GalleryPreviewContainer, context: Context) {
        container.load(url: url)
    }

    static func dismantleNSView(_ container: GalleryPreviewContainer, coordinator: ()) {
        container.clear()
    }
}

