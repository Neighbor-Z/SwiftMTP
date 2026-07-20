import SwiftUI
import Foundation
import AppKit

struct MainView: View {
    @StateObject private var manager = MTPManager()
    @StateObject private var favoritesManager = FavoritesManager()
    @State private var selection: Set<MTPFile.ID> = []
    @State private var isShowingNewFolderDialog = false
    @State private var isShowingRenameDialog = false
    @State private var newFolderName = ""
    @State private var newFileName = ""
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingDeviceInfo = false
    @State private var isShowingReplaceAlert = false
    @State private var searchQuery: String = ""
    @State private var unfilteredFiles: [MTPFile]? = nil
    @State private var pendingImportURLs: [URL] = []
    @State private var isShowingExportReplaceAlert = false
    @State private var pendingExportDestinationURL: URL?
    @State private var pendingExportFiles: [MTPFile] = []
    @State private var isShowingFolderNotFound = false
    @State private var selectedFavoriteID: UUID? = nil
    @State private var isShowingGoToFolderDialog = false
    @State private var customFolderPath = ""
    @State private var isShowingAISearch = false
    @StateObject private var aiNLSearch = AINaturalLanguageSearchManager()
    
    // AI Analysis State (Persists until app exit)
    @State private var aiHelpResult: String?
    @State private var isAIProcessing = false

    var selectedFiles: [MTPFile] {
        manager.sortedFiles.filter { selection.contains($0.id) }
    }

    var deleteDialogTitle: String {
        if selectedFiles.count == 1, let first = selectedFiles.first {
            let template = String(localized: "Delete \"%@\"?")
            return String(format: template, first.name)
        }
        let count = selectedFiles.count
        if count == 1 {
            let template = String(localized: "Delete %d item?")
            return String(format: template, count)
        } else {
            let template = String(localized: "Delete %d items?")
            return String(format: template, count)
        }
    }

    var body: some View {
        ZStack {
            contentView
            if isShowingDeviceInfo, let device = manager.connectionState.device {
                DeviceInfoOverlay(
                    device: device,
                    selectedStorage: manager.selectedStorage,
                    aiHelpResult: $aiHelpResult,
                    isAIProcessing: $isAIProcessing,
                    onDismiss: { isShowingDeviceInfo = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: manager.transferProgress != nil)
        .animation(.easeInOut(duration: 0.18), value: manager.isTransferActive)
        .animation(.easeInOut(duration: 0.18), value: isShowingDeviceInfo)
        .sheet(
            isPresented: Binding(
                get: { manager.isTransferActive },
                set: { _ in }
            )
        ) {
            TransferOverlay(
                stats: manager.transferStats,
                isPreparing: manager.isTransferActive && manager.transferStats == nil,
                onCancel: { manager.cancelTransfer() }
            )
            .interactiveDismissDisabled(true)
        }
        .popover(isPresented: $isShowingAISearch) {
            ScrollView {
                AISearchSuggestionView(
                    aiNLSearch: aiNLSearch,
                    searchQuery: searchQuery,
                    context: manager.lastDirectoryJson,
                    onResult: handleAINLSearchResult
                )
            }
            .frame(width: 300, height: 80)
            .padding()
        }
        .toolbar { toolbarContent }
        .onChange(of: manager.connectionState) { newState in
            if case .disconnected = newState {
                selection = []
            }
        }
        .onChange(of: searchQuery) { query in
            if query.isEmpty {
                if let original = unfilteredFiles {
                    manager.files = original
                    unfilteredFiles = nil
                }
            } else {
                if unfilteredFiles == nil {
                    unfilteredFiles = manager.files
                }
                manager.files = unfilteredFiles!.filter { $0.name.localizedCaseInsensitiveContains(query) }
            }
        }
        .onChange(of: manager.currentPath) { _ in
            selection = []
            searchQuery = ""
            unfilteredFiles = nil
        }
        .alert("New Folder", isPresented: $isShowingNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {} //newFolderName = "" if "" is applied sometimes the textfield cannot get the folder name
            Button("Create") {
                if !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                    manager.createFolder(named: newFolderName.trimmingCharacters(in: .whitespaces))
                }
                newFolderName = ""
            }
        } message: {
            Text("Enter a name for the new folder.")
        }
        .alert(String(localized: "Rename"), isPresented: $isShowingRenameDialog) {
            TextField(String(localized: "New Name"), text: $newFileName)
            Button(String(localized: "Cancel"), role: .cancel) {
                // newFileName = "" // if "" is applied sometimes the textfield cannot get the existing file name
            }
            Button(String(localized: "Rename")) {
                if let file = selectedFiles.first, !newFileName.trimmingCharacters(in: .whitespaces).isEmpty {
                    manager.renameFile(file, to: newFileName.trimmingCharacters(in: .whitespaces))
                }
                 newFileName = ""
            }
        } message: {
            if let file = selectedFiles.first {
                Text(String(format: String(localized: "Enter a new name for \"%@\"."), file.name))
            }
        }
        .alert(String(localized: "Replace and merge the existing items?"), isPresented: $isShowingReplaceAlert) {
            Button(String(localized: "Replace")) {
                guard !pendingImportURLs.isEmpty else { return }
                manager.upload(sourceURLs: pendingImportURLs)
                pendingImportURLs.removeAll()
            }
            Button("Cancel", role: .cancel) {
                pendingImportURLs.removeAll()
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
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                manager.deleteFiles(selectedFiles)
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .alert(String(localized: "Folder Not Found"), isPresented: $isShowingFolderNotFound) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text("The folder does not exist on this device.")
        }
        .alert(String(localized: "Go to Folder"), isPresented: $isShowingGoToFolderDialog) {
            TextField(String(localized: "/path/to/folder"), text: $customFolderPath)
            Button(String(localized: "Cancel"), role: .cancel) { customFolderPath = "" }
            Button(String(localized: "Go")) {
                let path = customFolderPath.trimmingCharacters(in: .whitespaces)
                if !path.isEmpty {
                    navigateAndHandleError(to: path)
                }
                customFolderPath = ""
            }
        } message: {
            Text(String(localized: "Enter the absolute path on the device."))
        }
        .alert(String(localized: "Item Exists"), isPresented: $manager.isShowingNameConflictAlert) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "A file or folder with the same name already exists."))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwiftMTPImportAction"))) { notification in
            if let urls = notification.userInfo?["urls"] as? [URL] {
                handleImport(urls)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwiftMTPExportAction"))) { notification in
            if let destinationURL = notification.userInfo?["destinationURL"] as? URL {
                handleExport(destinationURL: destinationURL, files: selectedFiles)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwiftMTPDeleteAction"))) { _ in
            if !selectedFiles.isEmpty {
                isShowingDeleteConfirmation = true
            }
        }
        .focusedSceneValue(\.isConnected, manager.connectionState.isConnected)
        .focusedSceneValue(\.canGoBack, manager.canGoBack)
        .focusedSceneValue(\.isTransferActive, manager.isTransferActive)
        .focusedSceneValue(\.isSelectedFilesEmpty, selectedFiles.isEmpty)
        .focusedSceneValue(\.isSingleItemSelected, selectedFiles.count == 1)
        .focusedSceneValue(\.isSingleFileSelected, selectedFiles.count == 1 && !selectedFiles[0].isDirectory)
        .focusedSceneValue(\.navigateToPathAction, { manager.navigateToPath($0) })
        .focusedSceneValue(\.navigateBackAction, { manager.navigateBack() })
        .focusedSceneValue(\.showFolderPromptAction, { isShowingGoToFolderDialog = true })
        .focusedSceneValue(\.showDeviceInfoAction, { isShowingDeviceInfo = true })
        .focusedSceneValue(\.showNewFolderAction, { isShowingNewFolderDialog = true })
        .focusedSceneValue(\.showRenameAction, {
            if let first = selectedFiles.first {
                newFileName = first.name
                isShowingRenameDialog = true
            }
        })
        .focusedSceneValue(\.showDeleteConfirmationAction, { isShowingDeleteConfirmation = true })
        .focusedSceneValue(\.connectDeviceAction, { manager.connectDevice() })
        .focusedSceneValue(\.disconnectDeviceAction, { manager.disconnectDevice(); manager.selectedStorage = nil })
        .focusedSceneValue(\.openFileAction, {
            NotificationCenter.default.post(name: NSNotification.Name("SwiftMTPOpenFileAction"), object: nil)
        })
        .focusedSceneValue(\.quickLookAction, {
            NotificationCenter.default.post(name: NSNotification.Name("SwiftMTPToggleQuickLook"), object: nil)
        })
    }

    private var contentView: some View {
        Group {
            if #available(macOS 13.0, *) {
                NavigationSplitView {
                    SidebarView(
                        manager: manager,
                        selectedStorage: $manager.selectedStorage,
                        selectedFavoriteID: $selectedFavoriteID,
                        favoritesManager: favoritesManager,
                        onFavoriteSelected: { item in
                            handleFavoriteTap(item)
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
                } detail: {
                    fileBrowserView
                        .searchable(text: $searchQuery, placement: .toolbar, prompt: Text("Search")) {
                            Button {
                                isShowingAISearch = true
                            } label: {
                                Label("Search with AI", systemImage: "sparkles")
                            }
                            .disabled(aiNLSearch.isProcessing)
                        }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if manager.connectionState.isConnected {
                                pathBar
                            }
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            statusBar
                        }
                }
            } else {
                NavigationView {
                    SidebarView(
                        manager: manager,
                        selectedStorage: $manager.selectedStorage,
                        selectedFavoriteID: $selectedFavoriteID,
                        favoritesManager: favoritesManager,
                        onFavoriteSelected: { item in
                            handleFavoriteTap(item)
                        }
                    )
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
                    
                    VStack(spacing: 0) {
                        if manager.connectionState.isConnected {
                            pathBar
                        }
                        fileBrowserView
                            .searchable(text: $searchQuery, placement: .toolbar, prompt: Text("Search")) {
                                Button {
                                    isShowingAISearch = true
                                } label: {
                                    Label("Search with AI", systemImage: "sparkles")
                                }
                                .disabled(aiNLSearch.isProcessing)
                            }
                        statusBar
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var fileBrowserView: some View {
        FileListView(
            manager: manager,
            selection: $selection,
            onDoubleClick: { file in
                if file.isDirectory { manager.navigate(to: file) }
            },
            onAddToFavorites: { file in
                let fullPath = file.path
                favoritesManager.addFavorite(name: file.name, path: fullPath)
            },
            isPathFavorited: { path in
                favoritesManager.contains(path: path)
            }
        )
    }

    // MARK: – Path Bar
    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                manager.navigateBack()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Enclosing Folder")
            .onHover { isHovering in
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .disabled(!manager.canGoBack)

            PathBarView(navigationStack: manager.navigationStack) { index in
                manager.navigate(toIndex: index)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Group {
                if #available(macOS 13.0, *) {
                    Color.clear.background(.bar)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: – Status Bar
    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let stats = manager.silentTransferStats {
                    HStack(spacing: 8) {
                        ProgressView(value: stats.progressPercentage)
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                        Text(stats.speedString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(stats.remainingTimeString)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(stats.progressPercentage.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(
            Group {
                if #available(macOS 13.0, *) {
                    Color.clear.background(.bar)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
        )
    }

    private var statusText: String {
        if let _ = manager.silentTransferStats {
            return String(localized: "Preparing preview...")
        }
        if manager.isTransferActive {
            let stats = manager.transferStats
            let filesProgressString = stats?.filesProgressString ?? ""
            return String(localized: "Transferring…") + " " + filesProgressString
        }
        if manager.isLoading { return String(localized: "Loading…") }
        if case let .error(message) = manager.connectionState { return message }

        if !selection.isEmpty {
            let count = selection.count
            if count == 1 {
                let template = String(localized: "%d item selected")
                return String(format: template, count)
            } else {
                let template = String(localized: "%d items selected")
                return String(format: template, count)
            }
        }

        let count = manager.sortedFiles.count
        if count == 1 {
            let template = String(localized: "%d item")
            return String(format: template, count)
        } else {
            let template = String(localized: "%d items")
            return String(format: template, count)
        }
    }

    // MARK: – Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Left: connection button
        ToolbarItemGroup(placement: .navigation) {
            if #unavailable(macOS 13.0) {
                Button {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                } label: {
                    Label(String(localized: "Toggle Sidebar"), systemImage: "sidebar.leading")
                }
                .help(String(localized: "Toggle Sidebar"))
            }

            if manager.connectionState.isConnected {
                Button {
                    manager.disconnectDevice()
                    manager.selectedStorage = nil
                } label: {
                    Label("Disconnect", systemImage: "cable.connector.slash")
                }
                .help("Disconnect Device")
            } else {
                Button {
                    manager.connectDevice()
                } label: {
                    Label("Connect Device", systemImage: "cable.connector")
                }
                .help(String(localized: "Connect Device"))
            }
        }

        // Right: file actions
        ToolbarItemGroup(placement: .primaryAction) {
            // Import
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.prompt = String(localized: "Import")
                if panel.runModal() == .OK {
                    handleImport(panel.urls)
                }
            } label: {
                if #available(macOS 13.0, *) {
                    Label(String(localized: "Import"), systemImage: "iphone.and.arrow.forward.inward")
                } else {
                    Label(String(localized: "Import"), systemImage: "arrow.down.to.line")
                }
            }
            .help(String(localized: "Import files from Mac to device"))
            .disabled(!manager.connectionState.isConnected || manager.isTransferActive)
            
            // Export
            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.prompt = String(localized: "Export Here")
                if panel.runModal() == .OK, let url = panel.url {
                    handleExport(destinationURL: url, files: selectedFiles)
                }
            } label: {
                if #available(macOS 13.0, *) {
                    Label(String(localized: "Export"), systemImage: "iphone.and.arrow.forward.outward")
                } else {
                    Label(String(localized: "Export"), systemImage: "arrow.up.to.line")
                }
            }
            .help(String(localized: "Export selected files to Mac"))
            .disabled(selectedFiles.isEmpty || !manager.connectionState.isConnected || manager.isTransferActive)

            Spacer(minLength: 12)

            // New Folder
            Button {
                isShowingNewFolderDialog = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help(String(localized: "Create new folder"))
            .disabled(!manager.connectionState.isConnected || manager.isTransferActive)
            
            // Rename
            Button {
                if let first = selectedFiles.first {
                    newFileName = first.name
                    isShowingRenameDialog = true
                }
            } label: {
                Label("Rename", systemImage: "character.cursor.ibeam")
            }
            .help(String(localized: "Rename"))
            .disabled(!manager.connectionState.isConnected || manager.isTransferActive || selectedFiles.count != 1)

            // Delete
            Button {
                isShowingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help(String(localized: "Delete selected items"))
            .disabled(selectedFiles.isEmpty || !manager.connectionState.isConnected || manager.isTransferActive)

            Spacer(minLength: 12)

            // Device Info
            Button {
                isShowingDeviceInfo = true
            } label: {
                Label(String(localized: "Device Info"), systemImage: "info.circle")
            }
            .help(String(localized: "Show device information"))
            .disabled(!manager.connectionState.isConnected || manager.isTransferActive)
        }
    }

    private func handleImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if manager.hasConflictingItems(for: urls) {
            pendingImportURLs = urls
            isShowingReplaceAlert = true
            return
        }
        manager.upload(sourceURLs: urls)
    }

    private func handleExport(destinationURL: URL, files: [MTPFile]) {
        guard !files.isEmpty else { return }
        if hasExportConflicts(files: files, destinationURL: destinationURL) {
            pendingExportFiles = files
            pendingExportDestinationURL = destinationURL
            isShowingExportReplaceAlert = true
            return
        }
        manager.download(files: files, destinationURL: destinationURL)
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

    /// Navigates to a specific path. If the folder doesn't exist on the device,
    /// the walk callback will return an error which triggers connectionState → .error.
    /// We detect this pattern and show the "Folder Not Found" alert instead.
    private func navigateAndHandleError(to path: String) {
        guard manager.connectionState.isConnected else { return }
        guard manager.selectedStorage != nil else { return }

        // Remember the original state so we can restore it if navigation fails
        let previousPath = manager.currentPath

        manager.navigateToPath(path)

        // After a short delay, check if loading resulted in an error
        // (e.g. the path doesn't exist on the device)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let hasError = manager.errorMessage != nil || (manager.connectionState.device == nil)
            var isErrorState = false
            if case .error = manager.connectionState {
                isErrorState = true
            }
            if hasError || isErrorState {
                // The walk failed — likely the folder doesn't exist.
                // The MTP session gets broken upon accessing a missing directory.
                // We must reconnect the device and navigate to the previous secure path.
                manager.reconnectAndRestore(to: previousPath)
                manager.errorMessage = nil
                isShowingFolderNotFound = true
            }
        }
    }

    private func handleFavoriteTap(_ item: FavoriteItem) {
        navigateAndHandleError(to: item.path)
    }

    // MARK: – AI Natural Language Search Result Handler

    /// Handles the result from the inline AI natural language search.
    /// On success, filters the file list to only show matched names.
    /// On error, the AINLSearchManager already sets `errorMessage` for display.
    private func handleAINLSearchResult(_ result: AINLSearchResult) {
        switch result {
        case .matchedNames(let names):
            let nameSet = Set(names)
            if unfilteredFiles == nil {
                unfilteredFiles = manager.files
            }
            manager.files = unfilteredFiles!.filter { nameSet.contains($0.name) }
        case .error:
            // Error is already displayed via aiNLSearch.errorMessage
            break
        }
    }
}

// MARK: – Device Info Overlay
private struct DeviceInfoOverlay: View {
    let device: MTPDevice
    let selectedStorage: MTPStorage?
    @Binding var aiHelpResult: String?
    @Binding var isAIProcessing: Bool
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "smartphone")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Device Information")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 20)

                // Info rows
                VStack(alignment: .leading, spacing: 0) {
                    InfoRow(label: String(localized: "Manufacturer"), value: device.manufacturer.isEmpty ? "-" : device.manufacturer)
                    InfoRow(label: String(localized: "Device Model"), value: device.name)
                    InfoRow(label: String(localized: "Protocol"), value: device.usbLinkDescription)
                    if let storage = selectedStorage {
                        InfoRow(label: String(localized: "Storage"), value: storage.name)
                        InfoRow(label: String(localized: "Free Space"), value: storage.displayFreeSpace)
                        InfoRow(label: String(localized: "Total Space"), value: storage.displayTotalSpace)
                    }
                }
                .padding(.vertical, 6)
                
                if let result = aiHelpResult {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.purple)
                            Text("AI Analysis")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        Text(result)
                            .font(.system(size: 12))
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text("*AI can make mistakes. Please double check the facts.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.purple.opacity(0.05))
                    .cornerRadius(8)
                    .frame(width: 320)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

                Divider()
                    .padding(.horizontal, 20)

                // Footer button
                HStack {
                    Spacer()
                    Button(String(localized: "Close")) {
                        onDismiss()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button {
                        isAIProcessing = true
                        Task {
                            let aiManager = AIManager()
                            let query = "Manufacturer: \(device.manufacturer), Model: \(device.name), Current Protocol: \(device.usbLinkDescription)"
                            let result = await aiManager.sendOneOffRequest(query: query)
                            await MainActor.run {
                                withAnimation {
                                    aiHelpResult = result
                                    isAIProcessing = false
                                }
                            }
                        }
                    } label: {
                        if isAIProcessing {
                            ProgressView().controlSize(.small)
                                .frame(width: 50)
                        } else {
                            Text(String(localized: "AI Analysis"))
                        }
                    }
                    .disabled(isAIProcessing)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(radius: 16, y: 4)
            )
        }
    }
}

// MARK: - AI Search Suggestion View

struct AISearchSuggestionView: View {
    @ObservedObject var aiNLSearch: AINaturalLanguageSearchManager
    let searchQuery: String
    let context: String
    let onResult: (AINLSearchResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if aiNLSearch.isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if aiNLSearch.isSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Done")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = aiNLSearch.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear {
            aiNLSearch.search(
                query: searchQuery,
                context: context,
                completion: onResult
            )
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct TransferOverlay: View {
    let stats: TransferStatistics?
    let isPreparing: Bool
    var onCancel: (() -> Void)? = nil

    private var currentFileName: String {
        if isPreparing {
            return String(localized: "Preparing transfer…")
        }
        return stats?.currentFileName ?? ""
    }

    private var filesProgressText: String {
        isPreparing ? " " : (stats?.filesProgressString ?? "")
    }

    private var speedText: String {
        isPreparing ? " " : (stats?.speedString ?? "")
    }

    private var totalSentText: String {
        isPreparing ? "" : "\(stats?.totalSentSizeString ?? "")/\(stats?.totalSizeString ?? "") - "
    }

    private var remainingTimeText: String {
        if isPreparing {
            return " \(String(localized: "--"))"
        }
        return " \(stats?.remainingTimeString ?? "")"
    }

    private var progressText: String {
        if isPreparing {
            return "\(0.formatted(.percent))"
        }
        return (stats?.progressPercentage ?? 0).formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(currentFileName)
                .font(.system(size: 13, weight: .medium))
                
            HStack(spacing: 8) {
                Group {
                    if isPreparing {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView(value: stats?.progressPercentage ?? 0)
                            .progressViewStyle(.linear)
                    }
                }
                .frame(width: 336)
                
                if let onCancel {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Cancel Transfer"))
                }
            }
            
            HStack(spacing: 8) {
                Text(filesProgressText)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(speedText)
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .frame(width: 360)

            HStack(spacing: 0) {            
                Text(totalSentText)
                    .font(.system(size: 11))
                Text("Remaining:", tableName: "Localizable")
                    .font(.system(size: 10, weight: .semibold))
                Text(remainingTimeText)
                    .font(.system(size: 10))
                Spacer()
                Text(progressText)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(alignment: .trailing)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 360)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

#Preview("中文") {
    MainView()
        .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("English") {
    MainView()
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("日本語") {
    MainView()
        .environment(\.locale, Locale(identifier: "ja"))
}

#Preview("Espanal") {
    MainView()
        .environment(\.locale, Locale(identifier: "es"))
}

#Preview("TransferOverlay") {
    let mockProgress30: TransferStatistics = {
        let mockData = TransferProgressData(
            fullPath: "/storage/emulated/0/DCIM/Camera/VID_20250330_123456.mp4",
            name: "VID_20250330_123456.mp4",
            elapsedTime: 45_000,        // 45 seconds
            speed: 12.5,                // 12.5 MB/s
            totalFiles: 150,
            totalDirectories: 10,
            filesSent: 45,
            filesSentProgress: 30.0,
            activeFileSize: TransferSizeInfo(total: 524_288_000, sent: 157_286_400, progress: 30.0),
            bulkFileSize: TransferSizeInfo(total: 1_073_741_824, sent: 322_122_547, progress: 30.0),
            status: "transferring"
        )
        return TransferStatistics(progressData: mockData)
    }()
    TransferOverlay(stats: mockProgress30, isPreparing: false, onCancel: {})
}

#Preview("QuickLook Overlay - Prompt") {
    QuickLookOverlayView(
        state: .prompt(MTPFile.mock[6]),
        onLoadPreview: {}
    )
}

#Preview("QuickLook Overlay - Loading") {
    QuickLookOverlayView(
        state: .loading,
        onLoadPreview: {}
    )
}

#Preview("AI Disclaimer") {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        AIDisclaimerView(
            onAccept: {},
            onCancel: {}
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 10)
    }
}

#Preview("AI Features Intro") {
    ZStack {
        Color.gray.opacity(0.2).ignoresSafeArea()
        AIFeaturesIntroView()
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(12)
            .shadow(radius: 10)
    }
}
