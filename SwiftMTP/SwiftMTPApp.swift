import SwiftUI
import AppKit

/// Owns the original URLs (including their sandbox extensions) until the picker
/// is cancelled or MTPManager has acquired its own access for the transfer.
final class ShareRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    private let scopedURLs: [URL]

    init(urls: [URL]) {
        self.urls = urls
        scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    deinit {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}

/// A queue survives cold launch and periods without a main window. Repeated
/// shares must not replace the files in an already visible picker.
final class QuickActionState: ObservableObject {
    static let shared = QuickActionState()
    @Published private(set) var requests: [ShareRequest] = []

    func enqueue(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        requests.append(ShareRequest(urls: files))
    }

    func takeNext() -> ShareRequest? {
        guard !requests.isEmpty else { return nil }
        return requests.removeFirst()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var originalNewWindowAction: Selector?
    private var originalNewWindowTarget: AnyObject?
    private var originalNewWindowItem: NSMenuItem?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Keep SwiftUI's macOS 12-compatible window creation action, but route
        // every invocation through the single-main-window coordinator.
        DispatchQueue.main.async {
            self.installMainWindowAction()
        }
    }

    private func installMainWindowAction() {
        guard let item = NSApp.mainMenu?.items.compactMap(\.submenu)
            .flatMap(\.items).first(where: {
                $0.keyEquivalent.lowercased() == "n" &&
                $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command
            }), let action = item.action else { return }

        originalNewWindowAction = action
        originalNewWindowTarget = item.target
        originalNewWindowItem = item.copy() as? NSMenuItem
        item.target = self
        item.action = #selector(newWindowAction(_:))
        WindowManager.shared.installCreateWindowAction { [weak self] in
            guard let self, let action = self.originalNewWindowAction else { return false }
            // A nil target is valid: AppKit then searches the responder chain.
            return NSApp.sendAction(action, to: self.originalNewWindowTarget, from: self.originalNewWindowItem)
        }
    }

    /// Launch Services delivers these URLs with the user's file access grant.
    /// Do not convert them to paths and reconstruct URLs before using them.
    func application(_ application: NSApplication, open urls: [URL]) {
        receiveSharedFiles(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMainWindow()
        return false
    }

    @objc func sendToSwiftMTP(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        // readObjects preserves the pasteboard's sandbox access information.
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        receiveSharedFiles(urls)
    }

    private func receiveSharedFiles(_ urls: [URL]) {
        guard urls.contains(where: \.isFileURL) else { return }
        QuickActionState.shared.enqueue(urls)
        WindowManager.shared.showMainWindow()
    }

    @objc func newWindowAction(_ sender: Any) {
        WindowManager.shared.showMainWindow()
    }
    
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newWindowAction(_:)) {
            return !WindowManager.shared.hasWindowOpen
        }
        return true
    }
}

@main
struct SwiftMTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @StateObject private var viewModeSettings = ViewModeSettings()

    @FocusedValue(\.isConnected) var isConnected
    @FocusedValue(\.isTransferActive) var isTransferActive
    @FocusedValue(\.isSelectedFilesEmpty) var isSelectedFilesEmpty
    @FocusedValue(\.isSingleFileSelected) var isSingleFileSelected
    @FocusedValue(\.showDeviceInfoAction) var showDeviceInfoAction
    @FocusedValue(\.showNewFolderAction) var showNewFolderAction
    @FocusedValue(\.showRenameAction) var showRenameAction
    @FocusedValue(\.showDeleteConfirmationAction) var showDeleteConfirmationAction
    @FocusedValue(\.connectDeviceAction) var connectDeviceAction
    @FocusedValue(\.disconnectDeviceAction) var disconnectDeviceAction
    @FocusedValue(\.isSingleItemSelected) var isSingleItemSelected
    @FocusedValue(\.openFileAction) var openFileAction
    @FocusedValue(\.quickLookAction) var quickLookAction

    var body: some Scene {
        WindowGroup {
            MainWindowRoot(viewModeSettings: viewModeSettings)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button { showNewFolderAction?() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(isConnected != true || isTransferActive == true)
                Button { openFileAction?() } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(isConnected != true || isTransferActive == true || isSingleItemSelected != true)
                Button { showRenameAction?() } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
                    .disabled(isConnected != true || isTransferActive == true || isSingleItemSelected != true)
                Button { quickLookAction?() } label: { Label("Quick Look", systemImage: "eye") }
                    .keyboardShortcut("y", modifiers: [.command])
                    .disabled(isConnected != true || isTransferActive == true || isSingleItemSelected != true)
                Button { showDeleteConfirmationAction?() } label: { Label("Delete", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(isConnected != true || isTransferActive == true || isSelectedFilesEmpty == true)
                    .labelStyle(.titleAndIcon)
                
                Divider()
                
                if isConnected == true {
                    Button { disconnectDeviceAction?() } label: { Label("Disconnect Device", systemImage: "cable.connector.slash") }
                        .keyboardShortcut("e", modifiers: [.command])
                        .disabled(isTransferActive == true)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button { connectDeviceAction?() } label: { Label("Connect Device", systemImage: "cable.connector") }
                        .keyboardShortcut("k", modifiers: [.command])
                        .disabled(isConnected == true)
                        .labelStyle(.titleAndIcon)
                }
                Button { showDeviceInfoAction?() } label: { Label("Device Info", systemImage: "info.circle") }
                    .keyboardShortcut("i", modifiers: [.command])
                    .disabled(isConnected != true || isTransferActive == true)
                    .labelStyle(.titleAndIcon)
                
                Divider()
                
                Button { handleImportAction() } label: { Label("Import", systemImage: "iphone.and.arrow.forward.inward") }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(isConnected != true || isTransferActive == true)
                    .labelStyle(.titleAndIcon)
                Button { handleExportAction() } label: { Label("Export", systemImage: "iphone.and.arrow.forward.outward") }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(isConnected != true || isTransferActive == true || isSelectedFilesEmpty == true)
                    .labelStyle(.titleAndIcon)
                
                Divider()
                
                Button(String(localized: "Export CLI Usage Guide")) {
                    exportCLIUsageAction()
                }
                
                Button(String(localized: "Clear Preview Cache")) {
                    clearCacheAction()
                }
            }
            
            GoMenuCommands()
            
            SidebarCommands()

            CommandGroup(before: .toolbar) {
                Toggle(isOn: Binding(
                    get: { viewModeSettings.viewModeRaw == FileBrowserViewMode.icons.rawValue },
                    set: { if $0 { viewModeSettings.viewModeRaw = FileBrowserViewMode.icons.rawValue } }
                )) {
                    Label(String(localized: "as Icons"), systemImage: "square.grid.2x2")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("1", modifiers: .command)

                Toggle(isOn: Binding(
                    get: { viewModeSettings.viewModeRaw == FileBrowserViewMode.list.rawValue },
                    set: { if $0 { viewModeSettings.viewModeRaw = FileBrowserViewMode.list.rawValue } }
                )) {
                    Label(String(localized: "as List"), systemImage: "list.bullet")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("2", modifiers: .command)

                Toggle(isOn: Binding(
                    get: { viewModeSettings.viewModeRaw == FileBrowserViewMode.gallery.rawValue },
                    set: { if $0 { viewModeSettings.viewModeRaw = FileBrowserViewMode.gallery.rawValue } }
                )) {
                    Label(String(localized: "as Gallery"), systemImage: "squares.below.rectangle")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()
            }
        }
        //.defaultSize(width: 900, height: 600)
        
        Settings {
            SettingsView()
        }
    }

    private func handleImportAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Import")
        if panel.runModal() == .OK {
            // Post notification to trigger import in MainView
            let userInfo: [String: Any] = ["urls": panel.urls]
            NotificationCenter.default.post(name: NSNotification.Name("SwiftMTPImportAction"), object: nil, userInfo: userInfo)
        }
    }

    private func handleExportAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Export Here")
        if panel.runModal() == .OK, let url = panel.url {
            // Post notification to trigger export in MainView
            let userInfo: [String: Any] = ["destinationURL": url]
            NotificationCenter.default.post(name: NSNotification.Name("SwiftMTPExportAction"), object: nil, userInfo: userInfo)
        }
    }

    private func exportCLIUsageAction() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "CLI_USAGE.md"
        panel.prompt = String(localized: "Export")
        
        if panel.runModal() == .OK, let destinationURL = panel.url {
            if let sourceURL = Bundle.main.url(forResource: "CLI_USAGE", withExtension: "md") {
                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Export Failed")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } else {
                let alert = NSAlert()
                alert.messageText = String(localized: "Export Failed")
                alert.informativeText = String(localized: "Could not find CLI_USAGE.md in the application bundle.")
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func clearCacheAction() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMTP_QuickLook")
        var size: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let fileSize = attrs.fileSize {
                    size += Int64(fileSize)
                }
            }
        }
        
        let sizeMB = Double(size) / 1000.0 / 1000.0
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear Preview Cache")
        alert.informativeText = String(format: String(localized: "Current preview cache size is %.2f MB. Are you sure you want to clear it?"), sizeMB)
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }
}

struct GoMenuCommands: Commands {
    @FocusedValue(\.isConnected) var isConnected
    @FocusedValue(\.canGoBack) var canGoBack
    @FocusedValue(\.navigateToPathAction) var navigateToPathAction
    @FocusedValue(\.navigateBackAction) var navigateBackAction
    @FocusedValue(\.showFolderPromptAction) var showFolderPromptAction
    
    var body: some Commands {
        CommandMenu(String(localized: "Go")) {
            Button { navigateBackAction?()} label: { Label("Enclosing Folder", systemImage: "arrow.up.folder") }
                .keyboardShortcut(.upArrow, modifiers: [.command])
                .disabled(canGoBack != true)
                
            Divider()
            
            Button { navigateToPathAction?("/DCIM") } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                .disabled(isConnected != true)
                .labelStyle(.titleAndIcon)
            Button { navigateToPathAction?("/Download") } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(isConnected != true)
                .labelStyle(.titleAndIcon)
                
            Divider()
            
            Button { showFolderPromptAction?() } label: { Label("Go to Folder...", systemImage: "arrow.forward.folder") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(isConnected != true)
        }
    }
}

struct IsConnectedFocusedKey: FocusedValueKey { typealias Value = Bool }
struct CanGoBackFocusedKey: FocusedValueKey { typealias Value = Bool }
struct IsTransferActiveFocusedKey: FocusedValueKey { typealias Value = Bool }
struct IsSelectedFilesEmptyFocusedKey: FocusedValueKey { typealias Value = Bool }
struct IsSingleFileSelectedFocusedKey: FocusedValueKey { typealias Value = Bool }
struct NavigateToPathActionFocusedKey: FocusedValueKey { typealias Value = (String) -> Void }
struct NavigateBackActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct ShowFolderPromptActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct ShowDeviceInfoActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct ShowNewFolderActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct ShowRenameActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct ShowDeleteConfirmationActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct ConnectDeviceActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct DisconnectDeviceActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct IsSingleItemSelectedFocusedKey: FocusedValueKey { typealias Value = Bool }
struct OpenFileActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }
struct QuickLookActionFocusedKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var isConnected: Bool? {
        get { self[IsConnectedFocusedKey.self] }
        set { self[IsConnectedFocusedKey.self] = newValue }
    }
    var canGoBack: Bool? {
        get { self[CanGoBackFocusedKey.self] }
        set { self[CanGoBackFocusedKey.self] = newValue }
    }
    var isTransferActive: Bool? {
        get { self[IsTransferActiveFocusedKey.self] }
        set { self[IsTransferActiveFocusedKey.self] = newValue }
    }
    var isSelectedFilesEmpty: Bool? {
        get { self[IsSelectedFilesEmptyFocusedKey.self] }
        set { self[IsSelectedFilesEmptyFocusedKey.self] = newValue }
    }
    var isSingleFileSelected: Bool? {
        get { self[IsSingleFileSelectedFocusedKey.self] }
        set { self[IsSingleFileSelectedFocusedKey.self] = newValue }
    }
    var navigateToPathAction: ((String) -> Void)? {
        get { self[NavigateToPathActionFocusedKey.self] }
        set { self[NavigateToPathActionFocusedKey.self] = newValue }
    }
    var navigateBackAction: (() -> Void)? {
        get { self[NavigateBackActionFocusedKey.self] }
        set { self[NavigateBackActionFocusedKey.self] = newValue }
    }
    var showFolderPromptAction: (() -> Void)? {
        get { self[ShowFolderPromptActionFocusedKey.self] }
        set { self[ShowFolderPromptActionFocusedKey.self] = newValue }
    }
    var showDeviceInfoAction: (() -> Void)? {
        get { self[ShowDeviceInfoActionFocusedKey.self] }
        set { self[ShowDeviceInfoActionFocusedKey.self] = newValue }
    }
    var showNewFolderAction: (() -> Void)? {
        get { self[ShowNewFolderActionFocusedKey.self] }
        set { self[ShowNewFolderActionFocusedKey.self] = newValue }
    }
    var showRenameAction: (() -> Void)? {
        get { self[ShowRenameActionFocusedKey.self] }
        set { self[ShowRenameActionFocusedKey.self] = newValue }
    }
    var showDeleteConfirmationAction: (() -> Void)? {
        get { self[ShowDeleteConfirmationActionFocusedKey.self] }
        set { self[ShowDeleteConfirmationActionFocusedKey.self] = newValue }
    }
    var connectDeviceAction: (() -> Void)? {
        get { self[ConnectDeviceActionFocusedKey.self] }
        set { self[ConnectDeviceActionFocusedKey.self] = newValue }
    }
    var disconnectDeviceAction: (() -> Void)? {
        get { self[DisconnectDeviceActionFocusedKey.self] }
        set { self[DisconnectDeviceActionFocusedKey.self] = newValue }
    }
    var isSingleItemSelected: Bool? {
        get { self[IsSingleItemSelectedFocusedKey.self] }
        set { self[IsSingleItemSelectedFocusedKey.self] = newValue }
    }
    var openFileAction: (() -> Void)? {
        get { self[OpenFileActionFocusedKey.self] }
        set { self[OpenFileActionFocusedKey.self] = newValue }
    }
    var quickLookAction: (() -> Void)? {
        get { self[QuickLookActionFocusedKey.self] }
        set { self[QuickLookActionFocusedKey.self] = newValue }
    }
}

/// Tracks the main scene's actual window, including hidden/minimized windows.
/// Settings, panels and sheets never count as a main window.
final class WindowManager: ObservableObject {
    static let shared = WindowManager()
    @Published private(set) var hasWindowOpen = false
    private weak var mainWindow: NSWindow?
    private var mainWindowID: UUID?
    private var createWindow: (() -> Bool)?
    private var isCreatingWindow = false
    private var needsMainWindow = false
    private var closeObserver: NSObjectProtocol?

    func installCreateWindowAction(_ action: @escaping () -> Bool) {
        createWindow = action
        if needsMainWindow { showMainWindow() }
    }

    @discardableResult
    func register(_ window: NSWindow, id: UUID) -> Bool {
        if let existing = mainWindow, existing !== window {
            // Also guard restoration or any system action that bypasses Cmd-N.
            window.close()
            showMainWindow()
            return false
        }
        guard mainWindow !== window else { return true }
        mainWindow = window
        mainWindowID = id
        hasWindowOpen = true
        isCreatingWindow = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.mainWindow = nil
            self.mainWindowID = nil
            self.hasWindowOpen = false
            if let observer = self.closeObserver {
                NotificationCenter.default.removeObserver(observer)
                self.closeObserver = nil
            }
        }
        if needsMainWindow { showMainWindow() }
        return true
    }

    func isMainWindow(id: UUID?) -> Bool {
        id != nil && mainWindow != nil && mainWindowID == id
    }

    func showMainWindow() {
        needsMainWindow = true
        if let window = mainWindow {
            needsMainWindow = false
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard !isCreatingWindow, let createWindow else { return }
        isCreatingWindow = true
        if !createWindow() { isCreatingWindow = false }
    }
}

/// Only the main scene installs this view; never infer its window by scanning
/// NSApp.windows for a visible/key window (a sheet or Settings may be key).
private struct MainWindowRoot: View {
    let viewModeSettings: ViewModeSettings
    @State private var windowID = UUID()
    @State private var isMainWindow = false

    var body: some View {
        Group {
            if isMainWindow {
                MainView(mainWindowID: windowID).environmentObject(viewModeSettings)
            } else {
                Color.clear
            }
        }
        .background(MainWindowReader(id: windowID) { isMainWindow = true })
    }
}

private struct MainWindowReader: NSViewRepresentable {
    let id: UUID
    let onRegister: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.id = id
        view.onRegister = onRegister
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var id = UUID()
        var onRegister: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                if WindowManager.shared.register(window, id: self.id) {
                    self.onRegister?()
                }
            }
        }
    }
}
