import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ShareDestinationPickerView

/// Sheet shown when files are sent from Finder via Quick Action / Services.
/// Provides: device waiting state → device & storage selection → column-view directory browser → file list → confirm.
/// Reuses MTPManager's existing `loadFiles` for directory browsing and `upload` for transfers.
struct ShareDestinationPickerView: View {
    @ObservedObject var manager: MTPManager
    let pendingURLs: [URL]
    let onConfirm: (_ urls: [URL], _ destinationPath: String) -> Void
    let onCancel: () -> Void
    
    @State private var selectedPath: String = "/"
    /// Each element holds the files for one column level.
    @State private var columnDirectories: [[MTPFile]] = []
    @State private var columnSelections: [String?] = []
    /// Tracks which column index we're currently loading for.
    /// Also serves as a concurrency guard — only one walk at a time.
    @State private var pendingColumnLoad: Int? = nil
    /// Prevents multiple initial loads from onAppear + onChange race.
    @State private var hasInitiallyLoaded = false
    /// Saves the main view's navigation state so we can restore it on dismiss.
    @State private var savedNavigationStack: [String] = []
    
    @State private var activeColumnIndex: Int = 0
    @FocusState private var isBrowserFocused: Bool
    
    private var isDeviceReady: Bool {
        manager.connectionState.isConnected && manager.selectedStorage != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            headerView
            
            Divider()
            
            if !isDeviceReady {
                waitingForDeviceView
            } else {
                // Device & Storage selection
                deviceStorageSection
                
                Divider()
                
                // Column-style directory browser
                columnBrowserSection
                
                Divider()
                
                // Pending items list
                pendingItemsSection
            }
            
            Divider()
            
            // Action buttons
            footerButtons
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            savedNavigationStack = manager.navigationStack
            if isDeviceReady && !hasInitiallyLoaded {
                initializeRootColumn()
            }
        }
        .onChange(of: isDeviceReady) { _ in
            resetColumns()
            hasInitiallyLoaded = false
            // A new connection owns a new navigation context. Never restore
            // a directory from the previous device when dismissing the sheet.
            savedNavigationStack = ["/"]
            if isDeviceReady {
                // MTPManager already starts the initial walk on connection.
                initializeRootColumn()
            }
        }
        // === Dual observation to capture walk results robustly ===
        // 1) When files change (successful walk with new data)
        .onChange(of: manager.files) { _ in
            captureWalkResultIfPending()
        }
        // 2) When loading finishes (covers error paths and same-data walks)
        .onChange(of: manager.isLoading) { isLoading in
            if !isLoading {
                if isDeviceReady && !hasInitiallyLoaded {
                    initializeRootColumn()
                } else {
                    captureWalkResultIfPending()
                }
            }
        }
    }
    
    // MARK: - Walk Result Capture
    
    /// Called from both onChange(of: files) and onChange(of: isLoading) to robustly
    /// capture walk results regardless of how handleDone completes.
    private func captureWalkResultIfPending() {
        guard let columnIndex = pendingColumnLoad else { return }
        // Don't capture while still loading — wait for the walk to fully complete.
        guard isDeviceReady, hasInitiallyLoaded, !manager.isLoading else { return }
        
        let loadedFiles = manager.sortedFiles
        pendingColumnLoad = nil
        
        // Ensure we have space in the arrays
        while columnDirectories.count <= columnIndex {
            columnDirectories.append([])
            columnSelections.append(nil)
        }
        columnDirectories[columnIndex] = loadedFiles
    }
    
    // MARK: - Initialization
    
    private func resetColumns() {
        columnDirectories = []
        columnSelections = []
        selectedPath = "/"
        activeColumnIndex = 0
        pendingColumnLoad = nil
    }

    /// Reuse the manager's root walk, including in-flight and empty results.
    private func initializeRootColumn() {
        guard isDeviceReady, !hasInitiallyLoaded else { return }
        if manager.currentPath == "/" {
            hasInitiallyLoaded = true
            pendingColumnLoad = 0
            captureWalkResultIfPending()
        } else if !manager.isLoading {
            // Wait for any existing subdirectory walk before requesting root.
            hasInitiallyLoaded = true
            loadColumn(path: "/", forColumnIndex: 0)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transfer")
                    .font(.system(size: 14, weight: .semibold))
                if pendingURLs.count == 1 {
                    Text(String(format: String(localized: "%d item"), 1))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: String(localized: "%d items"), pendingURLs.count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    // MARK: - Waiting State
    
    private var waitingForDeviceView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Waiting for device connection…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Connect an MTP device via USB cable \n and ensure it is in file transfer mode.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Device & Storage Picker
    
    private var deviceStorageSection: some View {
        HStack(spacing: 16) {
            // Device
            HStack(spacing: 6) {
                Image(systemName: "smartphone")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if manager.availableDevices.count > 1 {
                    Picker("", selection: Binding(
                        // Match the USB identifiers used by the available-device tags.
                        get: { manager.deviceId },
                        set: { newId in
                            if newId != manager.deviceId {
                                manager.switchDevice(to: newId)
                            }
                        }
                    )) {
                        ForEach(manager.availableDevices, id: \.id) { device in
                            Text(device.displayName).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                } else if let device = manager.connectionState.device {
                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("No Device")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
                .frame(height: 20)
            
            // Storage Picker
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let device = manager.connectionState.device, device.storages.count > 1 {
                    Picker("", selection: Binding(
                        get: { manager.selectedStorage?.id ?? "" },
                        set: { newId in
                            guard newId != manager.selectedStorage?.id,
                                  !manager.isLoading, pendingColumnLoad == nil,
                                  let storage = device.storages.first(where: { $0.id == newId }) else { return }
                            // Only a user-initiated storage change needs a new walk.
                            resetColumns()
                            manager.selectedStorage = storage
                            manager.navigationStack = ["/"]
                            savedNavigationStack = ["/"]
                            hasInitiallyLoaded = true
                            loadColumn(path: "/", forColumnIndex: 0)
                        }
                    )) {
                        ForEach(device.storages) { storage in
                            Text(storage.name).tag(storage.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                } else if let storage = manager.selectedStorage {
                    Text(storage.name)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            
            Spacer()
            
            // Current destination path
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(selectedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(manager.isLoading || pendingColumnLoad != nil || !hasInitiallyLoaded)
    }
    
    // MARK: - Column Browser (Finder-like)
    
    private var columnBrowserSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose destination on device:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(columnDirectories.indices), id: \.self) { columnIndex in
                            columnView(at: columnIndex)
                                .id(columnIndex)
                        }
                        
                        if manager.isLoading && pendingColumnLoad != nil {
                            VStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .frame(width: 180, height: 200)
                            .id("loading")
                        }
                    }
                }
                .frame(height: 200)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .focusable()
                .focused($isBrowserFocused)
                .onMoveCommand { direction in
                    handleNavigation(direction)
                }
                .onTapGesture {
                    isBrowserFocused = true
                }
                .onChange(of: activeColumnIndex) { newIndex in
                    withAnimation {
                        let targetIndex = min(newIndex + 1, columnDirectories.count - 1)
                        if targetIndex >= 0 {
                            proxy.scrollTo(targetIndex, anchor: .trailing)
                        }
                    }
                }
                .onChange(of: columnDirectories.count) { newCount in
                    withAnimation {
                        let targetIndex = min(activeColumnIndex + 1, newCount - 1)
                        if targetIndex >= 0 {
                            proxy.scrollTo(targetIndex, anchor: .trailing)
                        }
                    }
                }
                .onChange(of: pendingColumnLoad) { pending in
                    if pending != nil {
                        withAnimation {
                            proxy.scrollTo("loading", anchor: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
    
    private func columnView(at index: Int) -> some View {
        let files = columnDirectories[index]
        let selection = columnSelections[index]
        
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        columnRow(file: file, isSelected: selection == file.name, isActiveColumn: index == activeColumnIndex, columnIndex: index)
                            .id(file.name)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: selection) { newSelection in
                if let newSelection = newSelection {
                    proxy.scrollTo(newSelection, anchor: nil)
                }
            }
        }
        .frame(width: 200)
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
    
    private func columnRow(file: MTPFile, isSelected: Bool, isActiveColumn: Bool, columnIndex: Int) -> some View {
        let highlightColor = isActiveColumn 
            ? Color(NSColor.controlAccentColor.blended(withFraction: 0.15, of: .black) ?? .controlAccentColor)
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
            
        return HStack(spacing: 6) {
            Image(nsImage: getThumbnailIcon(for: file))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .opacity(file.isDirectory ? 1.0 : 0.4)
            Text(file.name)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? (isActiveColumn ? .white : .primary) : (file.isDirectory ? .primary : .secondary.opacity(0.5)))
                .lineLimit(1)
            Spacer()
            if file.isDirectory {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? (isActiveColumn ? .white.opacity(0.7) : .secondary) : .secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? highlightColor : Color.clear)
        .cornerRadius(4)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard file.isDirectory else { return }
            activeColumnIndex = columnIndex
            isBrowserFocused = true
            selectItem(file, at: columnIndex)
        }
    }
    
    // MARK: - Pending Items List
    
    private var pendingItemsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pendingURLs.count == 1 {
                Text(String(format: String(localized: "Items to transfer (%d item):"), 1))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            } else {
                Text(String(format: String(localized: "Items to transfer (%d items):"), pendingURLs.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
            
            List {
                ForEach(pendingURLs, id: \.absoluteString) { url in
                    pendingItemRow(url: url)
                }
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(pendingURLs.count) * 28 + 8, 120))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
    
    private func pendingItemRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if fileSize > 0 {
                Text(formatBytes(fileSize))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Footer Buttons
    
    private var footerButtons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) {
                restoreMainViewState()
                onCancel()
            }
            .keyboardShortcut(.escape, modifiers: [])
            
            Button(String(localized: "Transfer")) {
                // Restore first; MainView's onConfirm will then set the correct
                // destination path in navigationStack before calling upload.
                restoreMainViewState(reloadFiles: false)
                onConfirm(pendingURLs, selectedPath)
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!isDeviceReady || manager.isLoading || pendingColumnLoad != nil || !hasInitiallyLoaded)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    // MARK: - State Restoration
    
    /// Restores the main view's navigation state after the sheet is dismissed.
    /// The column browser's `loadFiles` calls overwrite `manager.files` as a side effect;
    /// this method reverts `navigationStack` and reloads the original directory's files.
    private func restoreMainViewState(reloadFiles: Bool = true) {
        pendingColumnLoad = nil  // Prevent sheet's onChange from capturing the restoration walk
        manager.navigationStack = savedNavigationStack
        if reloadFiles {
            let pathToRestore = savedNavigationStack.last ?? "/"
            manager.loadFiles(at: pathToRestore)
        }
    }
    
    // MARK: - Column Navigation Logic
    
    /// Loads directory contents at `path` using MTPManager's existing `loadFiles`.
    /// The result is captured via `onChange(of: manager.files)` into `columnDirectories[forColumnIndex]`.
    /// Guarded: only one walk at a time — a new request is dropped if one is already in flight.
    private func loadColumn(path: String, forColumnIndex index: Int) {
        guard isDeviceReady, !manager.isLoading, pendingColumnLoad == nil else { return }
        pendingColumnLoad = index
        manager.loadFiles(at: path)
    }
    
    private func selectItem(_ file: MTPFile, at columnIndex: Int) {
        guard isDeviceReady, !manager.isLoading, pendingColumnLoad == nil else { return }
        let keepCount = columnIndex + 1
        columnDirectories = Array(columnDirectories.prefix(keepCount))
        columnSelections = Array(columnSelections.prefix(keepCount))
        columnSelections[columnIndex] = file.name
        
        updateSelectedPath()
        
        if file.isDirectory {
            loadColumn(path: file.path, forColumnIndex: columnIndex + 1)
        }
    }
    
    private func updateSelectedPath() {
        var path = ""
        for i in 0..<columnSelections.count {
            guard let name = columnSelections[i] else { break }
            if let file = columnDirectories[i].first(where: { $0.name == name }) {
                if file.isDirectory {
                    path += "/" + name
                } else {
                    break
                }
            }
        }
        if path.isEmpty { path = "/" }
        selectedPath = path
    }
    
    private func handleNavigation(_ direction: MoveCommandDirection) {
        guard !columnDirectories.isEmpty else { return }
        
        if activeColumnIndex >= columnDirectories.count {
            activeColumnIndex = columnDirectories.count - 1
        }
        
        let files = columnDirectories[activeColumnIndex]
        let currentSelection = columnSelections[activeColumnIndex]
        
        switch direction {
        case .up:
            guard !files.isEmpty else { return }
            let idx = files.firstIndex(where: { $0.name == currentSelection }) ?? 0
            var newIdx = idx - 1
            while newIdx >= 0 && !files[newIdx].isDirectory {
                newIdx -= 1
            }
            if newIdx >= 0 {
                selectItem(files[newIdx], at: activeColumnIndex)
            }
            
        case .down:
            guard !files.isEmpty else { return }
            let idx = files.firstIndex(where: { $0.name == currentSelection }) ?? -1
            var newIdx = idx + 1
            while newIdx < files.count && !files[newIdx].isDirectory {
                newIdx += 1
            }
            if newIdx < files.count {
                selectItem(files[newIdx], at: activeColumnIndex)
            }
            
        case .left:
            if activeColumnIndex > 0 {
                columnSelections[activeColumnIndex] = nil
                activeColumnIndex -= 1
                
                let keepCount = activeColumnIndex + 2
                columnDirectories = Array(columnDirectories.prefix(keepCount))
                columnSelections = Array(columnSelections.prefix(keepCount))
                
                updateSelectedPath()
            }
            
        case .right:
            if let currentSelection = currentSelection,
               let file = files.first(where: { $0.name == currentSelection }),
               file.isDirectory {
                if activeColumnIndex + 1 < columnDirectories.count {
                    let nextFiles = columnDirectories[activeColumnIndex + 1]
                    if let firstDir = nextFiles.first(where: { $0.isDirectory }) {
                        activeColumnIndex += 1
                        if columnSelections[activeColumnIndex] == nil {
                            selectItem(firstDir, at: activeColumnIndex)
                        }
                    }
                }
            }
            
        default:
            break
        }
    }
    
    // MARK: - Helpers
    
    private func formatBytes(_ bytes: Int64) -> String {
        let d = Double(bytes)
        if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1f MB", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1f KB", d / 1e3) }
        return "\(bytes) B"
    }
    
    /// Returns the system icon for a file based on its UTType, matching the existing FileListView thumbnail logic.
    private func getThumbnailIcon(for file: MTPFile) -> NSImage {
        if file.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = file.extension_.lowercased()
        if !ext.isEmpty {
            if let utType = UTType(filenameExtension: ext),
               let icon = NSWorkspace.shared.icon(for: utType) as NSImage? {
                return icon
            }
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

// MARK: - Preview

#Preview("ShareDestinationPicker") {
    ShareDestinationPickerView(
        manager: {
            let m = MTPManager()
            return m
        }(),
        pendingURLs: [
            URL(fileURLWithPath: "/Users/user/Documents/report.pdf"),
            URL(fileURLWithPath: "/Users/user/Pictures/photo.jpg"),
            URL(fileURLWithPath: "/Users/user/Music/song.mp3")
        ],
        onConfirm: { _, _ in },
        onCancel: {}
    )
}
