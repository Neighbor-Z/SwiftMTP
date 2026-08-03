import Foundation
import Combine
import AppKit
import UserNotifications

/// Manages MTP device communication.
final class MTPManager: ObservableObject {
    
    // MARK: – Published State
    @Published var connectionState: ConnectionState = .disconnected
    @Published var files: [MTPFile] = []
    @Published var navigationStack: [String] = []
    @Published var selectedStorage: MTPStorage? = nil
    @Published var isLoading: Bool = false
    @Published var transferProgress: Double? = nil
    @Published var transferStats: TransferStatistics? = nil
    @Published var silentTransferStats: TransferStatistics? = nil
    @Published var errorMessage: String? = nil
    @Published var availableDevices: [MTPDeviceInfo] = []
    @Published private(set) var isTransferActive: Bool = false
    @Published var isShowingNameConflictAlert: Bool = false
    @Published var lastDirectoryJson: String = ""
    
    // NEW: Pass "" to let Go connect to the first available device, or specific ID for exact matches.
    var deviceId: String = ""
    
    var currentPath: String { navigationStack.last ?? "/" }
    var canGoBack: Bool { navigationStack.count > 1 }
    
    var sortedFiles: [MTPFile] {
        files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func hasConflictingItems(for sourceURLs: [URL]) -> Bool {
        guard !sourceURLs.isEmpty else { return false }
        let existingNames = Set(files.map { $0.name })
        for url in sourceURLs {
            if existingNames.contains(url.lastPathComponent) {
                return true
            }
        }
        return false
    }
    
    // MARK: – Gomtp routing (C callbacks cannot capture Swift context)
    private enum Operation {
        case none
        case initializing
        case fetchingStorages
        case walking
        case deleting
        case makingDirectory
        case renaming
        case uploading
        case downloading
        case silentDownloading
        case disposing
    }

    private var operation: Operation = .none
    private var transferCompletion: ((Error?) -> Void)?
    private var scopedSourceURLs: [URL] = []
    private var scopedDestinationURL: URL?
    private var cachedDeviceInfo: (name: String, manufacturer: String)? = nil
    private var pendingDeviceId: String? = nil
    private var pendingNavigationPath: String? = nil
    private var deviceScanWorkItem: DispatchWorkItem?
    
    // MARK: – Promise Downloads (for multi-select drag-drop)
    private let promiseQueueLock = DispatchQueue(label: "app.swiftmtp.promise-queue", attributes: [])
    private var promiseDownloadBatch: [(file: MTPFile, destination: URL, completion: (Error?) -> Void)] = []
    private var promiseBatchTimer: Timer?
    private var isProcessingPromiseBatch: Bool = false
    
    // MARK: – USB Hotplug & Retry Logic
    private var usbMonitor: USBMonitor?
    private var hotplugRetryCount: Int = 0
    private var retryTimer: Timer?
    private var shouldIgnoreUSBEvents: Bool = false
    
    
    private enum CallbackRouter {
        static weak var manager: MTPManager?
        
        // These callbacks do not capture any local context.
        static let done: GomtpOnCbResult = { jsonPtr in
            CallbackRouter.manager?.handleDone(jsonPtr: jsonPtr)
        }
        
        // Separate callback for device list - completely independent of operation state.
        static let deviceListDone: GomtpOnCbResult = { jsonPtr in
            CallbackRouter.manager?.handleDeviceListDone(jsonPtr: jsonPtr)
        }
        
        static let preprocess: GomtpOnCbResult = { jsonPtr in
            CallbackRouter.manager?.handlePreprocess(jsonPtr: jsonPtr)
        }
        
        static let progress: GomtpOnCbResult = { jsonPtr in
            CallbackRouter.manager?.handleProgress(jsonPtr: jsonPtr)
        }
        
        static let cancelDone: GomtpOnCbResult = { jsonPtr in
            CallbackRouter.manager?.handleCancelDone(jsonPtr: jsonPtr)
        }
    }
    
    init() {
        CallbackRouter.manager = self
        
        // Initialize and start USB monitor
        self.usbMonitor = USBMonitor { [weak self] attached in
            self?.handleUSBEvent(attached: attached)
        }
        self.usbMonitor?.startMonitoring()
        
        // Initial fetch
        fetchAvailableDevices()
    }
    
    deinit {
        // Clean up USB monitor and retry timer
        retryTimer?.invalidate()
        retryTimer = nil
        usbMonitor?.stopMonitoring()
        usbMonitor = nil
    }
    
    // MARK: – Callback handlers
    private func handlePreprocess(jsonPtr: UnsafeMutablePointer<CChar>?) {
        // Currently unused by the Swift UI.
        _ = jsonPtr
    }
    
    private func handleProgress(jsonPtr: UnsafeMutablePointer<CChar>?) {
        guard let jsonPtr else { return }
        guard operation == .downloading || operation == .uploading || operation == .silentDownloading else { return }
        
        let jsonString = String(cString: jsonPtr)
        let (errorString, dataAny) = parseEnvelope(jsonString)
        if let errorString {
            // Cancel errors are handled by the done callback; ignore in progress.
            if ErrorStringLocalizer.isTransferCancelledError(errorString) {
                // Don't set operation = .none here. The done callback will
                // handle the full cleanup including reconnection.
                let localizedError = ErrorStringLocalizer.localize(errorString)
                self.errorMessage = localizedError
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if ErrorStringLocalizer.isDeviceDisconnectedError(errorString) {
                    self.handleDeviceDisconnected()
                } else {
                    if self.operation != .silentDownloading {
                        self.isTransferActive = false
                        self.transferProgress = nil
                        self.transferStats = nil
                        let localizedError = ErrorStringLocalizer.localize(errorString)
                        self.connectionState = .error(localizedError)
                        self.errorMessage = localizedError
                    } else {
                        self.silentTransferStats = nil
                    }
                }
            }
            operation = .none
            return
        }
        guard let dataAny else { return }
        guard let progressData = decodeFullTransferProgress(from: dataAny) else { return }
        let stats = TransferStatistics(progressData: progressData)
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.operation == .silentDownloading {
                self.silentTransferStats = stats
            } else {
                self.transferStats = stats
                self.transferProgress = stats.progressPercentage
            }
        }
    }
    
    /// Independent handler for device list results. Does NOT interact with `operation`,
    /// so it can safely execute while Walk/Upload/Download/etc. are in progress.
    private func handleDeviceListDone(jsonPtr: UnsafeMutablePointer<CChar>?) {
        guard let jsonPtr else { return }
        let jsonString = String(cString: jsonPtr)
        
        if let errorString = parseEnvelopeErrorOnly(jsonString) {
            print("MTPManager: Error fetching available devices: \(errorString)")
            return
        }
        
        guard let dataAny = parseEnvelopeData(jsonString) else { return }
        let d = dataFromAny(dataAny)
        guard let devices = try? JSONDecoder().decode([MTPDeviceInfo].self, from: d) else {
            print("MTPManager: Failed to decode available devices payload")
            DispatchQueue.main.async { [weak self] in
                self?.availableDevices = []
                self?.handleDeviceDisconnected()
            }
            return
        }
        
        print("MTPManager: Found \(devices.count) devices")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableDevices = devices
            
            // Check if the currently connected device disappeared from the list.
            // This handles physical USB disconnection when no MTP operation is in flight.
            let isCurrentlyConnected: Bool = {
                if case .connected = self.connectionState { return true }
                if case .connecting = self.connectionState { return true }
                return false
            }()
            
            if isCurrentlyConnected && !self.deviceId.isEmpty {
                let stillPresent = devices.contains(where: { $0.id == self.deviceId })
                if !stillPresent {
                    print("MTPManager: Active device \(self.deviceId) no longer present — disconnecting")
                    self.handleDeviceDisconnected()
                    self.operation = .none
                    
                    // If there are remaining devices, auto-connect to the first one.
                    if let nextDevice = devices.first {
                        print("MTPManager: Auto-connecting to remaining device \(nextDevice.id)")
                        self.switchDevice(to: nextDevice.id)
                    }
                    return
                }
            }
            
            // Auto-connect logic: if disconnected and devices available, connect to the first one.
            if case .disconnected = self.connectionState, self.operation != .initializing, let first = devices.first {
                print("MTPManager: Auto-connecting to \(first.id)")
                self.switchDevice(to: first.id)
            }
        }
    }
    
    private func handleDone(jsonPtr: UnsafeMutablePointer<CChar>?) {
        guard let jsonPtr else { return }
        
        let jsonString = String(cString: jsonPtr)
        
        switch operation {
        case .initializing:
            if let errorString = parseEnvelopeErrorOnly(jsonString) {
                DispatchQueue.main.async {
                    if ErrorStringLocalizer.isDeviceDisconnectedError(errorString) {
                        self.handleDeviceDisconnected()
                    } else {
                        let localizedError = ErrorStringLocalizer.localize(errorString)
                        self.connectionState = .error(localizedError)
                        self.errorMessage = localizedError
                    }
                }
                operation = .none
                return
            }
            
            // Extract device info from the Initialize response
            if let dataAny = parseEnvelopeData(jsonString),
               let deviceInfo = parseDeviceInfo(dataAny) {
                self.cachedDeviceInfo = deviceInfo
            }
            
            operation = .fetchingStorages
            let fetchStoragesInput: [String: Any] = ["deviceId": self.deviceId]
            if let fetchJson = self.toJsonString(fetchStoragesInput) {
                fetchJson.withCString { ptr in
                    GomtpFetchStorages(ptr, CallbackRouter.done)
                }
            }
            
        case .fetchingStorages:
            if let errorString = parseEnvelopeErrorOnly(jsonString) {
                DispatchQueue.main.async {
                    let localizedError = ErrorStringLocalizer.localize(errorString)
                    self.connectionState = .error(localizedError)
                    self.errorMessage = localizedError
                }
                operation = .none
                return
            }
            
            guard let dataAny = parseEnvelopeData(jsonString) else {
                DispatchQueue.main.async {
                    let localizedError = String(localized: "Invalid storages payload")
                    self.connectionState = .error(localizedError)
                }
                operation = .none
                return
            }
            
            let storages = parseStorages(dataAny)
            guard let first = storages.first else {
                DispatchQueue.main.async {
                    let localizedError = String(localized: "No storages found")
                    self.connectionState = .error(localizedError)
                    self.errorMessage = localizedError
                }
                operation = .none
                return
            }
            
            // Use cached device info from initialization, or fallback to defaults
            let deviceName = self.cachedDeviceInfo?.name ?? "MTP Device"
            let deviceManufacturer = self.cachedDeviceInfo?.manufacturer ?? ""
            
            let detectedUSB: USBMonitor.USBDetectionResult = self.usbMonitor?.detectCurrentUSBProtocol(
                productHint: deviceName,
                manufacturerHint: deviceManufacturer
            )
                ?? (protocolName: "Unknown", speedMbps: 0, maxSpeedBytesPerSecond: 42_000_000)
            let usbProtocol = self.mapUSBProtocol(from: detectedUSB.protocolName)
            
            let device = MTPDevice(
                id: "device-1",
                name: deviceName,
                manufacturer: deviceManufacturer,
                storages: storages,
                usbProtocol: usbProtocol,
                usbSpeedMbps: detectedUSB.speedMbps,
                maxSpeedBytesPerSecond: detectedUSB.maxSpeedBytesPerSecond
            )
            DispatchQueue.main.async {
                self.connectionState = .connected(device)
                self.selectedStorage = first
                if let pendingPath = self.pendingNavigationPath {
                    self.pendingNavigationPath = nil
                    self.navigateToPath(pendingPath)
                } else {
                    self.navigationStack = ["/"]
                    self.loadFiles(at: "/")
                }
            }
            operation = .none // will be overwritten by loadFiles(_:).
            
        case .walking:
            // Check if this walk was superseded by a newer directory request.
            if let dict = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any],
            let errorType = dict["errorType"] as? String,
            errorType == "ErrorWalkCancelled" {
                return
            }
            
            if let errorString = parseEnvelopeErrorOnly(jsonString) {
                DispatchQueue.main.async {
                    if ErrorStringLocalizer.isDeviceDisconnectedError(errorString) {
                        self.handleDeviceDisconnected()
                    } else {
                        self.isLoading = false
                        let localizedError = ErrorStringLocalizer.localize(errorString)
                        self.connectionState = .error(localizedError)
                        self.errorMessage = localizedError
                    }
                }
                operation = .none
                return
            }

            DispatchQueue.main.async {
                self.lastDirectoryJson = jsonString
            }
            
            guard let filesAny = parseEnvelopeData(jsonString) else {
                DispatchQueue.main.async { self.isLoading = false }
                operation = .none
                return
            }
            
            let filesData = dataFromAny(filesAny)
            if filesData.isEmpty {
                // e.g. empty directory listing: gomtp typically returns `data: []`.
                DispatchQueue.main.async {
                    self.files = []
                    self.isLoading = false
                }
                operation = .none
                return
            }
            guard let decoded = try? JSONDecoder().decode([GomtpWalkFileInfo].self, from: filesData) else {
                DispatchQueue.main.async { self.isLoading = false }
                operation = .none
                return
            }
            
            let mappedFiles: [MTPFile] = decoded.map { fi in
                MTPFile(
                    id: String(fi.objectId),
                    name: fi.name,
                    size: fi.size,
                    dateModified: self.parseGomtpDate(fi.dateAdded) ?? Date(),
                    isDirectory: fi.isFolder,
                    path: fi.path,
                    extension_: fi.extension_
                )
            }
            
            DispatchQueue.main.async {
                self.files = mappedFiles
                self.isLoading = false
            }
            operation = .none
            
        case .deleting, .makingDirectory, .renaming:
            if let errorString = parseEnvelopeErrorOnly(jsonString) {
                DispatchQueue.main.async {
                    if ErrorStringLocalizer.isDeviceDisconnectedError(errorString) {
                        self.handleDeviceDisconnected()
                    } else {
                        let localizedError = ErrorStringLocalizer.localize(errorString)
                        self.connectionState = .error(localizedError)
                        self.errorMessage = localizedError
                    }
                }
                operation = .none
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadFiles(at: self.currentPath)
            }
            operation = .none
            
        case .silentDownloading:
            if let errorString = parseEnvelopeErrorOnly(jsonString) {
                self.finishTransferCompletion(errorString: errorString)
                DispatchQueue.main.async { [weak self] in
                    self?.silentTransferStats = nil
                    if ErrorStringLocalizer.isDeviceDisconnectedError(errorString) {
                        self?.handleDeviceDisconnected()
                    }
                }
                operation = .none
                return
            }
            self.finishTransferCompletion(errorString: nil)
            DispatchQueue.main.async { [weak self] in
                self?.silentTransferStats = nil
            }
            operation = .none
            
        case .downloading, .uploading:
            // Data is a bool for done.
            if let errorString = parseEnvelopeErrorOnly(jsonString) {
                self.finishTransferCompletion(errorString: errorString)
                DispatchQueue.main.async {
                    if ErrorStringLocalizer.isDeviceDisconnectedError(errorString) {
                        self.handleDeviceDisconnected()
                    } else if ErrorStringLocalizer.isTransferCancelledError(errorString) {
                        // User-initiated cancel: the MTP session is corrupt after
                        // cancellation (broken transaction IDs, stale USB data).
                        // Dispose and reconnect to reset the session.
                        self.isTransferActive = false
                        self.transferProgress = nil
                        self.transferStats = nil
                        let localizedError = ErrorStringLocalizer.localize(errorString)
                        self.errorMessage = localizedError
                        self.reconnectAndRestore(to: self.currentPath)
                    } else {
                        self.isTransferActive = false
                        self.transferProgress = nil
                        self.transferStats = nil
                        let localizedError = ErrorStringLocalizer.localize(errorString)
                        self.connectionState = .error(localizedError)
                        self.errorMessage = localizedError
                    }
                }
                operation = .none
                return
            }
            
            let completedOp = operation
            self.finishTransferCompletion(errorString: nil)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isTransferActive = false
                self.transferProgress = nil
                self.transferStats = nil
                self.loadFiles(at: self.currentPath)
                
                if !NSApplication.shared.isActive {
                    let content = UNMutableNotificationContent()
                    content.title = String(localized: "Transfer Complete")
                    content.body = completedOp == .uploading ? String(localized: "Import completed successfully.") : String(localized: "Export completed successfully.")
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                        if granted {
                            UNUserNotificationCenter.current().add(request)
                        }
                    }
                }
            }
            
        case .disposing:
            DispatchQueue.main.async {
                self.connectionState = .disconnected
                self.files = []
                self.navigationStack = []
                self.selectedStorage = nil
                self.isTransferActive = false
                self.transferProgress = nil
                self.transferStats = nil
                self.errorMessage = nil
                self.isLoading = false
                self.cachedDeviceInfo = nil
            }
            operation = .none
            if let nextDeviceId = pendingDeviceId {
                pendingDeviceId = nil
                self.deviceId = nextDeviceId
                self.connectDevice()
            }
            
        case .none:
            break
        }
    }
    
    // MARK: – Device Connection
    func connectDevice() {
        DispatchQueue.main.async {
            self.connectionState = .connecting
            self.errorMessage = nil
        }
        
        operation = .initializing
        let input: [String: Any] = ["deviceId": self.deviceId]
        if let jsonString = toJsonString(input) {
            DispatchQueue.global(qos: .userInitiated).async {
                jsonString.withCString { ptr in
                    GomtpInitialize(ptr, CallbackRouter.done)
                }
            }
        }
    }
    
    func disconnectDevice() {
        operation = .disposing
        let input: [String: Any] = ["deviceId": self.deviceId]
        if let jsonString = toJsonString(input) {
            DispatchQueue.global(qos: .userInitiated).async {
                jsonString.withCString { ptr in
                    GomtpDispose(ptr, CallbackRouter.done)
                }
            }
        }
    }
    
    // MARK: – USB Hotplug & Retry Logic
    private let maxRetryCount: Int = 1
    private let retryDelay: TimeInterval = 2.0
    private let initialCheckDelay: TimeInterval = 1.5  // Initial delay before checking connection status
    
    /// Handles USB device attachment/detachment events
    private func handleUSBEvent(attached: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = nil
            if case .error = self?.connectionState {
                self?.connectionState = .disconnected
            }
        }
        
        // Debounce USB events - many events fire rapidly during plug/unplug.
        // This prevents rapid-fire scans that could overwhelm the USB bus.
        deviceScanWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fetchAvailableDevices()
        }
        deviceScanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }
    
    /// Attempts to connect with retry logic
    private func attemptConnectWithRetry() {
        // Check if already connected
        if case .connected = connectionState {
            print("MTPManager: Already connected, skipping retry")
            hotplugRetryCount = 0
            return
        }
        
        // Attempt connection
        connectDevice()
        
        // Register to monitor for success/failure
        // We'll check the connection state after a delay to allow device initialization
        DispatchQueue.main.asyncAfter(deadline: .now() + initialCheckDelay) { [weak self] in
            self?.checkConnectionAndRetry()
        }
    }
    
    /// Checks if connection succeeded, retries if needed
    private func checkConnectionAndRetry() {
        // If connected, reset retry count and return
        if case .connected = connectionState {
            print("MTPManager: Connection successful, retry count reset")
            hotplugRetryCount = 0
            return
        }
        
        // If failed, attempt retry
        hotplugRetryCount += 1
        print("MTPManager: Connection failed, retry attempt \(hotplugRetryCount)/\(maxRetryCount)")
        
        if hotplugRetryCount >= maxRetryCount {
            print("MTPManager: Max retries reached, giving up")
            hotplugRetryCount = 0
            return
        }
        
        // Schedule next retry
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            print("MTPManager: Attempting retry \(self?.hotplugRetryCount ?? 0 + 1)...")
            self?.attemptConnectWithRetry()
        }
    }
    
    // MARK: – Navigation
    func navigate(to directory: MTPFile) {
        guard directory.isDirectory else { return }
        let newPath = currentPath == "/" ? "/\(directory.name)" : "\(currentPath)/\(directory.name)"
        navigationStack.append(newPath)
        loadFiles(at: newPath)
    }
    
    func navigateBack() {
        guard canGoBack else { return }
        navigationStack.removeLast()
        loadFiles(at: currentPath)
    }
    
    func navigate(toIndex index: Int) {
        guard index < navigationStack.count else { return }
        navigationStack = Array(navigationStack.prefix(index + 1))
        loadFiles(at: currentPath)
    }

    /// Navigate directly to an absolute path (e.g. "/Pictures/Screenshots").
    /// Builds the full breadcrumb navigation stack from "/" to the target.
    func navigateToPath(_ path: String) {
        guard selectedStorage != nil else { return }
        var stack: [String] = ["/"]
        let components = path.split(separator: "/").map(String.init)
        var current = ""
        for component in components {
            current += "/\(component)"
            stack.append(current)
        }
        navigationStack = stack
        loadFiles(at: path)
    }
    
    // MARK: – File Listing
    func loadFiles(at path: String) {
        guard let storage = selectedStorage else { return }
        guard storage.id != "" else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.isLoading = true
        }
        
        let storageId = self.uint32FromStorageId(storage.id)
        let skipHiddenFiles = false
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "fullPath": path,
            "recursive": false,
            "skipDisallowedFiles": false,
            "skipHiddenFiles": skipHiddenFiles
        ]
        
        guard let jsonString = self.toJsonString(input) else {
            DispatchQueue.main.async { [weak self] in
                self?.isLoading = false
            }
            return
        }
        
        operation = .walking
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpWalk(ptr, CallbackRouter.done)
            }
        }
    }
    
    // MARK: – Transfer
    func download(files: [MTPFile], destinationURL: URL) {
        guard !files.isEmpty else { return }
        guard let storage = selectedStorage else { return }
        
        let storageId = self.uint32FromStorageId(storage.id)
        let sources = files.map(\.path)
        let destination = destinationURL.path
        
        DispatchQueue.main.async { [weak self] in
            self?.isTransferActive = true
            self?.transferProgress = 0
        }
        beginSecurityScopedAccess(destinationURL: destinationURL)
        
        let preprocessFiles = true
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "sources": sources,
            "destination": destination,
            "preprocessFiles": preprocessFiles
        ]
        
        guard let jsonString = toJsonString(input) else {
            DispatchQueue.main.async { [weak self] in
                self?.isTransferActive = false
                self?.transferProgress = nil
            }
            endSecurityScopedAccess()
            return
        }
        operation = .downloading
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpDownloadFiles(ptr, CallbackRouter.preprocess, CallbackRouter.progress, CallbackRouter.done)
            }
        }
    }
    
    func upload(sourceURLs: [URL]) {
        guard !sourceURLs.isEmpty else { return }
        guard let storage = selectedStorage else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.isTransferActive = true
            self?.transferProgress = 0
        }
        beginSecurityScopedAccess(sourceURLs: sourceURLs)
        let storageId = uint32FromStorageId(storage.id)
        let sources = sourceURLs.map(\.path)
        let destination = currentPath
        
        let preprocessFiles = true
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "sources": sources,
            "destination": destination,
            "preprocessFiles": preprocessFiles
        ]
        
        guard let jsonString = toJsonString(input) else {
            DispatchQueue.main.async { [weak self] in
                self?.isTransferActive = false
                self?.transferProgress = nil
            }
            endSecurityScopedAccess()
            return
        }
        operation = .uploading
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpUploadFiles(ptr, CallbackRouter.preprocess, CallbackRouter.progress, CallbackRouter.done)
            }
        }
    }
    
    func downloadPromise(file: MTPFile, to destinationFolderURL: URL, completion: @escaping (Error?) -> Void) {
        if case .downloading = operation {
            completion(NSError(domain: "MTPManager.Transfer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Another transfer is already running."
            ]))
            return
        }
        if case .uploading = operation {
            completion(NSError(domain: "MTPManager.Transfer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Another transfer is already running."
            ]))
            return
        }
        guard let storage = selectedStorage else {
            completion(NSError(domain: "MTPManager.Transfer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No storage selected."
            ]))
            return
        }
        
        transferCompletion = completion
        DispatchQueue.main.async { [weak self] in
            self?.isTransferActive = true
            self?.transferProgress = 0
        }
        
        let storageId = self.uint32FromStorageId(storage.id)
        let sources = [file.path]
        let destination = destinationFolderURL.path
        let preprocessFiles = true
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "sources": sources,
            "destination": destination,
            "preprocessFiles": preprocessFiles
        ]
        
        guard let jsonString = toJsonString(input) else {
            DispatchQueue.main.async { [weak self] in
                self?.isTransferActive = false
                self?.transferProgress = nil
            }
            finishTransferCompletion(errorString: "Failed to encode download payload.")
            return
        }
        
        operation = .downloading
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpDownloadFiles(ptr, CallbackRouter.preprocess, CallbackRouter.progress, CallbackRouter.done)
            }
        }
    }
    
    /// Download multiple files from device as a batch promise (for drag-to-Finder).
    /// Sends all file paths in a single GomtpDownloadFiles call for proper "n of n" progress.
    func downloadPromiseBatch(files: [MTPFile], to destinationFolderURL: URL, completion: @escaping (Error?) -> Void) {
        if case .downloading = operation {
            completion(NSError(domain: "MTPManager.Transfer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Another transfer is already running."
            ]))
            return
        }
        if case .uploading = operation {
            completion(NSError(domain: "MTPManager.Transfer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Another transfer is already running."
            ]))
            return
        }
        guard let storage = selectedStorage else {
            completion(NSError(domain: "MTPManager.Transfer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No storage selected."
            ]))
            return
        }
        
        transferCompletion = completion
        DispatchQueue.main.async { [weak self] in
            self?.isTransferActive = true
            self?.transferProgress = 0
        }
        
        let storageId = self.uint32FromStorageId(storage.id)
        let sources = files.map(\.path)
        let destination = destinationFolderURL.path
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "sources": sources,
            "destination": destination,
            "preprocessFiles": true
        ]
        
        guard let jsonString = toJsonString(input) else {
            DispatchQueue.main.async { [weak self] in
                self?.isTransferActive = false
                self?.transferProgress = nil
            }
            finishTransferCompletion(errorString: "Failed to encode download payload.")
            return
        }
        
        operation = .downloading
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpDownloadFiles(ptr, CallbackRouter.preprocess, CallbackRouter.progress, CallbackRouter.done)
            }
        }
    }
    
    func downloadAndPreview(file: MTPFile, to destinationFolderURL: URL, completion: @escaping (Error?) -> Void) {
        if operation != .none && operation != .walking {
            completion(NSError(domain: "MTPManager.Transfer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Another operation is running."
            ]))
            return
        }
        guard let storage = selectedStorage else {
            completion(NSError(domain: "MTPManager.Transfer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No storage selected."
            ]))
            return
        }
        
        transferCompletion = completion
        
        let storageId = self.uint32FromStorageId(storage.id)
        let sources = [file.path]
        let destination = destinationFolderURL.path
        let preprocessFiles = true
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "sources": sources,
            "destination": destination,
            "preprocessFiles": preprocessFiles
        ]
        
        guard let jsonString = toJsonString(input) else {
            finishTransferCompletion(errorString: "Failed to encode download payload.")
            return
        }
        
        operation = .silentDownloading
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpDownloadFiles(ptr, CallbackRouter.preprocess, CallbackRouter.progress, CallbackRouter.done)
            }
        }
    }
    
    func deleteFiles(_ filesToDelete: [MTPFile]) {
        guard !filesToDelete.isEmpty else { return }
        guard let storage = selectedStorage else { return }
        
        let storageId = uint32FromStorageId(storage.id)
        let filePaths = filesToDelete.map(\.path)
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "files": filePaths
        ]
        
        guard let jsonString = toJsonString(input) else { return }
        operation = .deleting
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpDeleteFile(ptr, CallbackRouter.done)
            }
        }
    }
    
    func createFolder(named name: String) {
        guard let storage = selectedStorage else { return }
        
        if files.contains(where: { $0.name == name }) {
            DispatchQueue.main.async { [weak self] in
                self?.isShowingNameConflictAlert = true
            }
            return
        }
        
        let storageId = uint32FromStorageId(storage.id)
        let fullPath = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
        
        DispatchQueue.main.async { [weak self] in
            self?.isLoading = true
        }
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "fullPath": fullPath
        ]
        guard let jsonString = toJsonString(input) else { return }
        operation = .makingDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpMakeDirectory(ptr, CallbackRouter.done)
            }
        }
    }
    
    func renameFile(_ file: MTPFile, to newName: String) {
        guard let storage = selectedStorage else { return }
        
        if file.name != newName && files.contains(where: { $0.name == newName }) {
            DispatchQueue.main.async { [weak self] in
                self?.isShowingNameConflictAlert = true
            }
            return
        }
        
        let storageId = uint32FromStorageId(storage.id)
        
        DispatchQueue.main.async { [weak self] in
            self?.isLoading = true
        }
        
        let input: [String: Any] = [
            "deviceId": self.deviceId,
            "storageId": Int(storageId),
            "fullPath": file.path,
            "newFileName": newName
        ]
        
        guard let jsonString = toJsonString(input) else { return }
        operation = .renaming
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpRenameFile(ptr, CallbackRouter.done)
            }
        }
    }
    
    // MARK: – Cancel Transfer
    func cancelTransfer() {
        guard isTransferActive else { return }
        
        let input: [String: Any] = ["deviceId": self.deviceId]
        guard let jsonString = toJsonString(input) else { return }
        
        // Fire-and-forget: CancelTransfer uses its own callback that does NOT
        // go through the operation state machine (similar to FetchAvailableDevices).
        DispatchQueue.global(qos: .userInitiated).async {
            jsonString.withCString { ptr in
                GomtpCancelTransfer(ptr, CallbackRouter.cancelDone)
            }
        }
    }
    
    private func handleCancelDone(jsonPtr: UnsafeMutablePointer<CChar>?) {
        guard let jsonPtr else { return }
        let jsonString = String(cString: jsonPtr)
        
        if let errorString = parseEnvelopeErrorOnly(jsonString) {
            print("MTPManager: CancelTransfer error: \(errorString)")
        } else {
            print("MTPManager: Transfer cancelled successfully")
        }
        // The actual transfer operation's done callback will fire separately
        // with a cancellation error, which handleDone will process normally.
        // We don't reset UI state here — let the transfer's own error handling do it.
    }
    
    /// After a user-initiated cancel, the MTP session is left in a corrupt state
    /// (broken transaction IDs, pending USB data, or invalid directory access). We must 
    /// dispose and reconnect to reset the protocol state, then navigate to the target path.
    func reconnectAndRestore(to targetPath: String) {
        let savedPath = targetPath
        let savedDeviceId = self.deviceId
        
        // Save the path to restore after reconnection
        pendingNavigationPath = savedPath
        
        // Queue reconnection to the same device after dispose completes
        pendingDeviceId = savedDeviceId
        
        // Show connecting state while we reset
        connectionState = .connecting
        
        // Dispose the corrupt MTP session.
        // handleDone(.disposing) will see pendingDeviceId and call connectDevice().
        // handleDone(.fetchingStorages) will see pendingNavigationPath and navigate there.
        operation = .disposing
        let input: [String: Any] = ["deviceId": savedDeviceId]
        if let jsonString = toJsonString(input) {
            DispatchQueue.global(qos: .userInitiated).async {
                jsonString.withCString { ptr in
                    GomtpDispose(ptr, CallbackRouter.done)
                }
            }
        }
    }
    
    // MARK: – Helpers
    private func isDeviceDisconnectedError(_ error: String) -> Bool {
        // Electron uses `errorType` to detect device changed / lost device.
        // Our `parseEnvelopeErrorOnly` may format it as: `ErrorDeviceChanged: ...`
        return error.contains("ErrorDeviceChanged") || error.contains("LIBUSB_ERROR_NO_DEVICE")
    }
    
    private func handleDeviceDisconnected() {
        connectionState = .disconnected
        files = []
        navigationStack = []
        selectedStorage = nil
        isLoading = false
        isTransferActive = false
        transferProgress = nil
        transferStats = nil
        finishTransferCompletion(errorString: "Device disconnected.")
        errorMessage = nil
    }
    
    private func beginSecurityScopedAccess(sourceURLs: [URL]) {
        scopedSourceURLs = sourceURLs.filter { $0.startAccessingSecurityScopedResource() }
    }
    
    private func beginSecurityScopedAccess(destinationURL: URL) {
        if destinationURL.startAccessingSecurityScopedResource() {
            scopedDestinationURL = destinationURL
        }
    }
    
    private func endSecurityScopedAccess() {
        scopedSourceURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedSourceURLs = []
        scopedDestinationURL?.stopAccessingSecurityScopedResource()
        scopedDestinationURL = nil
    }
    
    private func finishTransferCompletion(errorString: String?) {
        endSecurityScopedAccess()
        guard let completion = transferCompletion else { return }
        transferCompletion = nil
        if let errorString {
            completion(NSError(domain: "MTPManager.Transfer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: errorString
            ]))
        } else {
            completion(nil)
        }
    }
    
    private func fetchStorages() {
        operation = .fetchingStorages
        let input: [String: Any] = ["deviceId": self.deviceId]
        if let jsonString = toJsonString(input) {
            DispatchQueue.global(qos: .userInitiated).async {
                jsonString.withCString { ptr in
                    GomtpFetchStorages(ptr, CallbackRouter.done)
                }
            }
        }
    }
    
    func fetchAvailableDevices() {
        // NOTE: Does NOT set `operation` - device scanning is completely independent
        // of the MTP operation state machine. This prevents clobbering in-flight
        // operations (Walk, Upload, etc.) whose callbacks would be misrouted.
        DispatchQueue.global(qos: .userInitiated).async {
            GomtpFetchAvailableDevices(CallbackRouter.deviceListDone)
        }
    }
    
    func switchDevice(to newDeviceId: String) {
        guard !newDeviceId.isEmpty else { return }
        
        // If already connected to this device, do nothing.
        if case .connected = connectionState, self.deviceId == newDeviceId {
            return
        }
        if case .connecting = connectionState, self.deviceId == newDeviceId {
            return
        }
        
        // If we're already disposing, queue the next device and wait.
        if case .disposing = operation {
            pendingDeviceId = newDeviceId
            return
        }
        
        // Disconnect current device if needed, then connect after dispose completes.
        switch connectionState {
        case .connected, .connecting, .error:
            pendingDeviceId = newDeviceId
            disconnectDevice()
            return
        case .disconnected:
            break
        }
        
        self.deviceId = newDeviceId
        self.connectDevice()
    }
    
    private func uint32FromStorageId(_ storageId: String) -> UInt32 {
        if let v = UInt32(storageId) { return v }
        // Some storages may have non-numeric IDs; best-effort fallback.
        return 0
    }
    
    private func toJsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    private func dataFromAny(_ any: Any) -> Data {
        // In Foundation, `NSJSONSerialization` sometimes directly throws/triggers exceptions
        // for non-JSON container types, try?/Catch may not be able to catch.
        // Use isValidJSONObject for strong verification to avoid the collapse of empty dir or other cases.
        guard JSONSerialization.isValidJSONObject(any) else { return Data() }
        return (try? JSONSerialization.data(withJSONObject: any, options: [])) ?? Data()
    }
    
    private func parseEnvelope(_ jsonString: String) -> (error: String?, data: Any?) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any]
        else {
            return ("Invalid gomtp JSON", nil)
        }
        
        let errorString = (dict["error"] as? String) ?? ""
        // Electron treats `errorType` as `stderr`.
        let errorTypeString = (dict["errorType"] as? String) ?? ""
        let dataAny = dict["data"]
        
        if !errorString.isEmpty && !errorTypeString.isEmpty {
            return ("\(errorTypeString): \(errorString)", dataAny)
        }
        if !errorString.isEmpty {
            return (errorString, dataAny)
        }
        if !errorTypeString.isEmpty {
            return (errorTypeString, dataAny)
        }
        return (nil, dataAny)
    }
    
    private func parseEnvelopeErrorOnly(_ jsonString: String) -> String? {
        let (error, _) = parseEnvelope(jsonString)
        return error
    }
    
    private func parseEnvelopeData(_ jsonString: String) -> Any? {
        let (_, data) = parseEnvelope(jsonString)
        return data
    }
    
    private func parseDeviceInfo(_ any: Any) -> (name: String, manufacturer: String)? {
        // Data structure from Go's send_to_js: { mtpDeviceInfo: {...}, usbDeviceInfo: {...} }
        guard let dict = any as? [String: Any] else { return nil }
        
        // Try to get from mtpDeviceInfo first (MTP protocol info)
        if let mtpInfo = dict["mtpDeviceInfo"] as? [String: Any] {
            let model = mtpInfo["Model"] as? String ?? ""
            let manufacturer = mtpInfo["Manufacturer"] as? String ?? ""
            
            // If we have a model, use it along with manufacturer
            if !model.isEmpty || !manufacturer.isEmpty {
                return (name: model.isEmpty ? "MTP Device" : model, manufacturer: manufacturer)
            }
        }
        
        // Fallback to usbDeviceInfo
        if let usbInfo = dict["usbDeviceInfo"] as? [String: Any] {
            let deviceName = usbInfo["DeviceName"] as? String ?? ""
            let manufacturer = usbInfo["Manufacturer"] as? String ?? ""
            
            if !deviceName.isEmpty || !manufacturer.isEmpty {
                return (name: deviceName.isEmpty ? "Android Device" : deviceName, manufacturer: manufacturer)
            }
        }
        
        return nil
    }
    
    private func parseStorages(_ any: Any) -> [MTPStorage] {
        guard let list = any as? [[String: Any]] else { return [] }
        return list.compactMap { storage in
            let sidInt = int64FromAny(storage["Sid"]) ?? int64FromAny(storage["sid"]) ?? 0
            let id = String(UInt32(max(sidInt, 0)))
            
            let infoAny = storage["Info"] as? [String: Any] ?? storage["info"] as? [String: Any]
            let name = infoAny?["StorageDescription"] as? String ?? "Storage"
            
            let freeSpace = int64FromAny(infoAny?["FreeSpaceInBytes"]) ?? 0
            let totalSpace = int64FromAny(infoAny?["MaxCapability"]) ?? 0
            
            return MTPStorage(
                id: id,
                name: name,
                freeSpace: freeSpace,
                totalSpace: totalSpace
            )
        }
    }
    
    private func int64FromAny(_ any: Any?) -> Int64? {
        switch any {
        case let v as Int64: return v
        case let v as UInt64: return Int64(v)
        case let v as Int: return Int64(v)
        case let v as Double: return Int64(v)
        case let v as Float: return Int64(v)
        case let v as NSNumber: return v.int64Value
        default: return nil
        }
    }
    
    private func parseGomtpDate(_ dateAdded: String) -> Date? {
        // Format matches `send_to_js/constants.go`:
        // "2006-01-02T15:04:05.000Z"
        // Note: Backend sends local time despite the 'Z' suffix.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.date(from: dateAdded)
    }
    
    private struct GomtpWalkFileInfo: Decodable {
        let size: Int64
        let isFolder: Bool
        let dateAdded: String
        let name: String
        let path: String
        let extension_: String
        let objectId: UInt32
        
        private enum CodingKeys: String, CodingKey {
            case size
            case isFolder
            case dateAdded
            case name
            case path
            case extension_ = "extension"
            case objectId
        }
    }
    
    private struct TransferSizeInfo: Decodable {
        let total: Int64?
        let sent: Int64?
        let progress: Float?
    }
    // MARK: - Transfer Progress Decoding
    
    private func decodeFullTransferProgress(from dataAny: Any) -> TransferProgressData? {
        let d = dataFromAny(dataAny)
        guard !d.isEmpty else { return nil }
        return try? JSONDecoder().decode(TransferProgressData.self, from: d)
    }
    
    private func mapUSBProtocol(from name: String) -> USBProtocol {
        switch name {
        case "USB 2.0": return .usb20
        case "USB 3.0": return .usb30
        case "USB 3.1": return .usb31
        case "USB 3.2": return .usb32
        default: return .unknown
        }
    }
}
