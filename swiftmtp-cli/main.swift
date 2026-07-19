import Foundation

// MARK: - Models

struct MTPDeviceInfo: Codable, Identifiable {
    let vendorId: UInt16
    let productId: UInt16
    let serialNumber: String
    let manufacturer: String
    let model: String
    
    var id: String {
        return "\(vendorId)|\(productId)|\(serialNumber)"
    }
}

struct MTPStorage: Identifiable {
    let id: String
    let name: String
    let freeSpace: String
    let totalSpace: String
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = Double(bytes)
    var unitIndex = 0
    
    while size >= 1024 && unitIndex < units.count - 1 {
        size /= 1024
        unitIndex += 1
    }
    
    if unitIndex == 0 {
        return String(format: "%.0f %@", size, units[unitIndex])
    } else {
        return String(format: "%.2f %@", size, units[unitIndex])
    }
}

struct GomtpWalkFileInfo: Decodable {
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

struct TransferSizeInfo: Decodable {
    let total: Int64?
    let sent: Int64?
    let progress: Float?
}

struct TransferProgressData: Decodable {
    let fullPath: String?
    let name: String?
    let elapsedTime: Int64?
    let speed: Double?
    let totalFiles: Int64?
    let totalDirectories: Int64?
    let filesSent: Int64?
    let filesSentProgress: Float?
    let activeFileSize: TransferSizeInfo?
    let bulkFileSize: TransferSizeInfo?
    let status: String?
}

// MARK: - Helper C-Callback Router

class CallbackState {
    static let shared = CallbackState()
    
    var semaphore: DispatchSemaphore?
    var lastResultJson: String?
    var lastProgressJson: String?
    var didPrintProgress: Bool = false
}

let cbDone: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { ptr in
    if CallbackState.shared.didPrintProgress {
        print("\r\u{1B}[K", terminator: "")
        fflush(stdout)
        CallbackState.shared.didPrintProgress = false
    }
    
    if let ptr = ptr {
        CallbackState.shared.lastResultJson = String(cString: ptr)
    } else {
        CallbackState.shared.lastResultJson = nil
    }
    CallbackState.shared.semaphore?.signal()
}

let cbPreprocess: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { ptr in
    // ignored in simple CLI
}

let cbProgress: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void = { ptr in
    if let ptr = ptr {
        let jsonStr = String(cString: ptr)
        if let data = jsonStr.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataAny = obj["data"],
           let jsonData = try? JSONSerialization.data(withJSONObject: dataAny),
           let progress = try? JSONDecoder().decode(TransferProgressData.self, from: jsonData) {
            
            let speedMBps = progress.speed ?? 0.0
            let percent = progress.bulkFileSize?.progress ?? 0.0
            
            var etaString = "--s"
            if speedMBps > 0, let total = progress.bulkFileSize?.total, let sent = progress.bulkFileSize?.sent {
                let remainingMB = Double(total - sent) / (1024 * 1024)
                let remainingSecs = Int(remainingMB / speedMBps)
                if remainingSecs > 60 {
                    etaString = "\(remainingSecs / 60)m \(remainingSecs % 60)s"
                } else {
                    etaString = "\(remainingSecs)s"
                }
            }
            
            let barWidth = 30
            let filled = Int(Double(barWidth) * Double(percent) / 100.0)
            let empty = barWidth - filled
            let filledStr = String(repeating: "=", count: max(0, filled - 1)) + (filled > 0 ? ">" : "")
            let emptyStr = String(repeating: " ", count: empty)
            
            let line = String(format: "\r[%@%@] %5.1f%% | %6.2f MB/s | ETA: %@", filledStr, emptyStr, percent, speedMBps, etaString)
            print(line, terminator: "")
            fflush(stdout)
            CallbackState.shared.didPrintProgress = true
        }
    }
}

// MARK: - CLI MTP Client

class CLIMTPClient {
    
    static func fetchDevices() -> [MTPDeviceInfo]? {
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        GomtpFetchAvailableDevices(cbDone)
        sem.wait()
        
        guard let jsonStr = CallbackState.shared.lastResultJson else { return nil }
        return parseResponseData(jsonStr, as: [MTPDeviceInfo].self)
    }
    
    static func initialize(deviceId: String) -> Bool {
        let input = ["deviceId": deviceId]
        guard let jsonStr = toJson(input) else { return false }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpInitialize(ptr, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return false }
        if let err = extractError(result) {
            print("Error initializing device: \(err)")
            return false
        }
        return true
    }
    
    static func dispose(deviceId: String) {
        let input = ["deviceId": deviceId]
        guard let jsonStr = toJson(input) else { return }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpDispose(ptr, cbDone)
        }
        sem.wait()
    }
    
    static func fetchStorages(deviceId: String) -> [MTPStorage]? {
        let input = ["deviceId": deviceId]
        guard let jsonStr = toJson(input) else { return nil }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpFetchStorages(ptr, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return nil }
        if let err = extractError(result) {
            print("Error fetching storages: \(err)")
            return nil
        }
        
        guard let dataAny = parseEnvelopeData(result),
              let list = dataAny as? [[String: Any]] else {
            return nil
        }
        
        return list.compactMap { storage in
            let sidInt = storage["Sid"] as? NSNumber ?? storage["sid"] as? NSNumber ?? 0
            let id = String(UInt32(max(sidInt.int64Value, 0)))
            
            let infoAny = storage["Info"] as? [String: Any] ?? storage["info"] as? [String: Any]
            let name = infoAny?["StorageDescription"] as? String ?? "Storage"
            
            let freeSpaceRaw = (infoAny?["FreeSpaceInBytes"] as? NSNumber)?.int64Value ?? 0
            let totalSpaceRaw = (infoAny?["MaxCapability"] as? NSNumber)?.int64Value ?? 0
            
            let freeSpace = formatBytes(freeSpaceRaw)
            let totalSpace = formatBytes(totalSpaceRaw)
            
            return MTPStorage(id: id, name: name, freeSpace: freeSpace, totalSpace: totalSpace)
        }
    }
    
    static func walk(deviceId: String, storageId: Int, path: String) -> [GomtpWalkFileInfo]? {
        let input: [String: Any] = [
            "deviceId": deviceId,
            "storageId": storageId,
            "fullPath": path,
            "recursive": false,
            "skipDisallowedFiles": false,
            "skipHiddenFiles": false
        ]
        
        guard let jsonStr = toJson(input) else { return nil }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpWalk(ptr, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return nil }
        if let err = extractError(result) {
            print("Error listing directory: \(err)")
            return nil
        }
        return parseResponseData(result, as: [GomtpWalkFileInfo].self) ?? []
    }
    
    static func pull(deviceId: String, storageId: Int, sources: [String], destination: String) -> Bool {
        let input: [String: Any] = [
            "deviceId": deviceId,
            "storageId": storageId,
            "sources": sources,
            "destination": destination,
            "preprocessFiles": true
        ]
        
        guard let jsonStr = toJson(input) else { return false }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpDownloadFiles(ptr, cbPreprocess, cbProgress, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return false }
        if let err = extractError(result) {
            print("Error downloading: \(err)")
            return false
        }
        return true
    }
    
    static func push(deviceId: String, storageId: Int, sources: [String], destination: String) -> Bool {
        let input: [String: Any] = [
            "deviceId": deviceId,
            "storageId": storageId,
            "sources": sources,
            "destination": destination,
            "preprocessFiles": true
        ]
        
        guard let jsonStr = toJson(input) else { return false }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpUploadFiles(ptr, cbPreprocess, cbProgress, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return false }
        if let err = extractError(result) {
            print("Error uploading: \(err)")
            return false
        }
        return true
    }
    
    static func delete(deviceId: String, storageId: Int, files: [String]) -> Bool {
        let input: [String: Any] = [
            "deviceId": deviceId,
            "storageId": storageId,
            "files": files
        ]
        
        guard let jsonStr = toJson(input) else { return false }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpDeleteFile(ptr, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return false }
        if let err = extractError(result) {
            print("Error deleting: \(err)")
            return false
        }
        return true
    }
    
    static func mkdir(deviceId: String, storageId: Int, path: String) -> Bool {
        let input: [String: Any] = [
            "deviceId": deviceId,
            "storageId": storageId,
            "fullPath": path
        ]
        
        guard let jsonStr = toJson(input) else { return false }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpMakeDirectory(ptr, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return false }
        if let err = extractError(result) {
            print("Error creating directory: \(err)")
            return false
        }
        return true
    }
    
    static func rename(deviceId: String, storageId: Int, path: String, newName: String) -> Bool {
        let input: [String: Any] = [
            "deviceId": deviceId,
            "storageId": storageId,
            "fullPath": path,
            "newFileName": newName
        ]
        
        guard let jsonStr = toJson(input) else { return false }
        
        let sem = DispatchSemaphore(value: 0)
        CallbackState.shared.semaphore = sem
        jsonStr.withCString { ptr in
            GomtpRenameFile(ptr, cbDone)
        }
        sem.wait()
        
        guard let result = CallbackState.shared.lastResultJson else { return false }
        if let err = extractError(result) {
            print("Error renaming: \(err)")
            return false
        }
        return true
    }
    
    // MARK: - Utilities
    
    private static func toJson(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    private static func extractError(_ jsonStr: String) -> String? {
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = dict["error"] as? String, !error.isEmpty else {
            return nil
        }
        return error
    }
    
    private static func parseEnvelopeData(_ jsonStr: String) -> Any? {
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict["data"]
    }
    
    private static func parseResponseData<T: Decodable>(_ jsonStr: String, as type: T.Type) -> T? {
        guard let dataAny = parseEnvelopeData(jsonStr) else { return nil }
        
        let jsonData: Data
        if let str = dataAny as? String {
            jsonData = str.data(using: .utf8) ?? Data()
        } else if JSONSerialization.isValidJSONObject(dataAny) {
            jsonData = (try? JSONSerialization.data(withJSONObject: dataAny)) ?? Data()
        } else if dataAny is NSNull {
            jsonData = "[]".data(using: .utf8)!
        } else {
            return nil
        }
        
        return try? JSONDecoder().decode(T.self, from: jsonData)
    }
}

// MARK: - Interactive Shell

func parseShellArguments(_ input: String) -> [String] {
    var args: [String] = []
    var currentArg = ""
    var inSingleQuote = false
    var inDoubleQuote = false
    var escapeNext = false
    
    for char in input {
        if escapeNext {
            currentArg.append(char)
            escapeNext = false
        } else if char == "\\" {
            if inSingleQuote {
                currentArg.append(char)
            } else {
                escapeNext = true
            }
        } else if char == "'" {
            if inDoubleQuote {
                currentArg.append(char)
            } else {
                inSingleQuote.toggle()
            }
        } else if char == "\"" {
            if inSingleQuote {
                currentArg.append(char)
            } else {
                inDoubleQuote.toggle()
            }
        } else if char.isWhitespace {
            if inSingleQuote || inDoubleQuote {
                currentArg.append(char)
            } else {
                if !currentArg.isEmpty {
                    args.append(currentArg)
                    currentArg = ""
                }
            }
        } else {
            currentArg.append(char)
        }
    }
    if !currentArg.isEmpty || inSingleQuote || inDoubleQuote {
        args.append(currentArg)
    }
    return args
}

func readLineWithTabCompletion(prompt: String, onTab: (String) -> (replacementPrefix: String, matches: [String])) -> String? {
    print(prompt, terminator: "")
    fflush(stdout)
    
    var originalTerm = termios()
    tcgetattr(STDIN_FILENO, &originalTerm)
    
    var rawTerm = originalTerm
    rawTerm.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &rawTerm)
    
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTerm)
        print("")
    }
    
    var buffer = ""
    var cursorPos = 0
    
    while true {
        var c: UInt8 = 0
        let bytesRead = read(STDIN_FILENO, &c, 1)
        if bytesRead <= 0 { return nil }
        
        if c == 4 || c == 3 { // Ctrl+D or Ctrl+C
            return nil
        } else if c == 10 || c == 13 { // Enter
            break
        } else if c == 127 || c == 8 { // Backspace
            if cursorPos > 0 {
                let idx = buffer.index(buffer.startIndex, offsetBy: cursorPos - 1)
                buffer.remove(at: idx)
                cursorPos -= 1
                let clear = String(repeating: " ", count: buffer.count + 1)
                print("\r\(prompt)\(clear)\r\(prompt)\(buffer)", terminator: "")
                if cursorPos < buffer.count {
                    let back = String(repeating: "\u{0008}", count: buffer.count - cursorPos)
                    print(back, terminator: "")
                }
                fflush(stdout)
            }
        } else if c == 9 { // Tab
            let tabResult = onTab(buffer)
            let wordToComplete = tabResult.replacementPrefix
            let matches = tabResult.matches
            
            if matches.count == 1 {
                let completion = matches[0]
                if completion.hasPrefix(wordToComplete) {
                    var appendStr = String(completion.dropFirst(wordToComplete.count))
                    appendStr = appendStr.replacingOccurrences(of: " ", with: "\\ ")
                    buffer.insert(contentsOf: appendStr, at: buffer.index(buffer.startIndex, offsetBy: cursorPos))
                    cursorPos += appendStr.count
                }
                print("\r\(prompt)\(buffer)", terminator: "")
                fflush(stdout)
            } else if matches.count > 1 {
                print("\n" + matches.joined(separator: "  "))
                print("\(prompt)\(buffer)", terminator: "")
                fflush(stdout)
            }
        } else if c == 27 { // Escape sequence
            var seq = [UInt8](repeating: 0, count: 2)
            read(STDIN_FILENO, &seq, 2)
            if seq[0] == 91 { // '['
                if seq[1] == 68 { // Left
                    if cursorPos > 0 {
                        cursorPos -= 1
                        print("\u{0008}", terminator: "")
                        fflush(stdout)
                    }
                } else if seq[1] == 67 { // Right
                    if cursorPos < buffer.count {
                        let idx = buffer.index(buffer.startIndex, offsetBy: cursorPos)
                        print(String(buffer[idx]), terminator: "")
                        cursorPos += 1
                        fflush(stdout)
                    }
                }
            }
        } else if c >= 32 {
            let char = Character(UnicodeScalar(c))
            buffer.insert(char, at: buffer.index(buffer.startIndex, offsetBy: cursorPos))
            cursorPos += 1
            let clear = String(repeating: " ", count: buffer.count)
            print("\r\(prompt)\(clear)\r\(prompt)\(buffer)", terminator: "")
            if cursorPos < buffer.count {
                let back = String(repeating: "\u{0008}", count: buffer.count - cursorPos)
                print(back, terminator: "")
            }
            fflush(stdout)
        }
    }
    
    return buffer
}

class InteractiveShell {
    let deviceId: String
    var storageId: Int
    var currentPath: String = "/"
    
    init(deviceId: String, storageId: Int) {
        self.deviceId = deviceId
        self.storageId = storageId
    }
    
    func run() {
        print("Connected to \(deviceId). Storage: \(storageId). Type 'help' for commands, 'exit' to quit.")
        
        while true {
            guard let line = readLineWithTabCompletion(prompt: "mtp:\(currentPath)> ", onTab: { input in
                var args = parseShellArguments(input)
                if input.hasSuffix(" ") && !input.hasSuffix("\\ ") {
                    args.append("")
                }
                guard let lastArg = args.last, args.count > 1 else { return ("", []) }
                let command = args[0]
                
                if command == "cd" || command == "ls" || command == "pull" {
                    var dir = self.currentPath
                    var partial = lastArg
                    let replacementPrefix = lastArg
                    
                    if let lastSlashIndex = lastArg.lastIndex(of: "/") {
                        let pathPart = String(lastArg[..<lastSlashIndex])
                        dir = self.resolvePath(pathPart)
                        let afterSlash = lastArg.index(after: lastSlashIndex)
                        partial = String(lastArg[afterSlash...])
                    }
                    
                    guard let files = CLIMTPClient.walk(deviceId: self.deviceId, storageId: self.storageId, path: dir) else { return ("", []) }
                    
                    var matches: [String] = []
                    for file in files {
                        if file.name.hasPrefix(partial) {
                            if let lastSlashIndex = lastArg.lastIndex(of: "/") {
                                let prefixPart = String(lastArg[...lastSlashIndex])
                                matches.append(prefixPart + file.name + (file.isFolder ? "/" : ""))
                            } else {
                                matches.append(file.name + (file.isFolder ? "/" : ""))
                            }
                        }
                    }
                    return (replacementPrefix, matches)
                }
                return ("", [])
            }) else { break }
            
            let args = parseShellArguments(line)
            if args.isEmpty { continue }
            
            let command = args[0]
            
            switch command {
            case "exit", "quit":
                return
            case "pwd":
                print(currentPath)
            case "ls":
                handleLs(args: args)
            case "cd":
                handleCd(args: args)
            case "pull":
                handlePull(args: args)
            case "push":
                handlePush(args: args)
            case "rm":
                handleRm(args: args)
            case "mv":
                handleMv(args: args)
            case "mkdir":
                handleMkdir(args: args)
            case "info":
                handleInfo(args: args)
            case "help":
                print("Available commands:")
                print("  ls [-a] [path]       - List directory")
                print("  cd <path>            - Change directory")
                print("  pwd                  - Print working directory")
                print("  pull <file> <local>  - Download file to local path")
                print("  push <local> <dest>  - Upload local file to device path")
                print("  rm [-r] <path>       - Delete file or directory (use -r for directories)")
                print("  mv <path> <new_path> - Rename file or directory")
                print("  mkdir <path>         - Create a new directory")
                print("  info                 - Show device information")
                print("  exit                 - Quit the shell")
            default:
                print("Unknown command: \(command)")
            }
        }
    }
    
    private func handleLs(args: [String]) {
        var showAll = false
        var targetPath = currentPath
        
        for arg in args.dropFirst() {
            if arg == "-a" || arg == "-al" || arg == "-la" || arg == "-l" {
                showAll = true
            } else {
                targetPath = resolvePath(arg)
            }
        }
        
        guard let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: targetPath) else {
            print("Failed to read directory.")
            return
        }
        
        let sortedFiles = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for file in sortedFiles {
            if !showAll && file.name.hasPrefix(".") {
                continue
            }
            let type = file.isFolder ? "<DIR>" : "     "
            let sizeStr = file.isFolder ? "-" : String(file.size)
            let paddedSize = String(repeating: " ", count: max(0, 12 - sizeStr.count)) + sizeStr
            let dateStr = file.dateAdded.padding(toLength: 20, withPad: " ", startingAt: 0)
            print("\(type) \(paddedSize)  \(dateStr)  \(file.name)")
        }
    }
    
    private func handleCd(args: [String]) {
        if args.count < 2 {
            currentPath = "/"
            return
        }
        let target = resolvePath(args[1])
        // Optionally verify if it's a valid directory by calling walk, but we'll just set it.
        // Actually, we should verify.
        guard let _ = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: target) else {
            print("cd: no such file or directory: \(target)")
            return
        }
        currentPath = target
    }
    
    private func handlePull(args: [String]) {
        if args.count < 3 {
            print("Usage: pull <remote_path> <local_path>")
            return
        }
        let remote = resolvePath(args[1])
        let local = NSString(string: args[2]).expandingTildeInPath
        
        let remoteName = remote.components(separatedBy: "/").last ?? ""
        var localDestination = local
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: local, isDirectory: &isDir) {
            if isDir.boolValue {
                localDestination = (local as NSString).appendingPathComponent(remoteName)
            }
        }
        
        if FileManager.default.fileExists(atPath: localDestination) {
            print("pull: '\(localDestination)' already exists locally. Overwrite? [y/n]: ", terminator: "")
            fflush(stdout)
            if let response = readLine(), response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
                // proceed
            } else {
                print("Aborted.")
                return
            }
        }
        
        print("Pulling \(remote) to \(local)...")
        if CLIMTPClient.pull(deviceId: deviceId, storageId: storageId, sources: [remote], destination: local) {
            print("\nPull complete.")
        } else {
            print("\nPull failed.")
        }
    }
    
    private func handlePush(args: [String]) {
        if args.count < 3 {
            print("Usage: push <local_path> <remote_dir>")
            return
        }
        let local = NSString(string: args[1]).expandingTildeInPath
        let remote = resolvePath(args[2])
        
        let localName = URL(fileURLWithPath: local).lastPathComponent
        if let remoteFiles = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: remote) {
            if remoteFiles.contains(where: { $0.name == localName }) {
                print("push: '\(localName)' already exists in '\(remote)'. Overwrite? [y/n]: ", terminator: "")
                fflush(stdout)
                if let response = readLine(), response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
                    // proceed
                } else {
                    print("Aborted.")
                    return
                }
            }
        }
        
        print("Pushing \(local) to \(remote)...")
        if CLIMTPClient.push(deviceId: deviceId, storageId: storageId, sources: [local], destination: remote) {
            print("\nPush complete.")
        } else {
            print("\nPush failed.")
        }
    }
    
    private func handleRm(args: [String]) {
        var isRecursive = false
        var targetArg: String? = nil
        
        for arg in args.dropFirst() {
            if arg == "-r" || arg == "-R" {
                isRecursive = true
            } else if targetArg == nil {
                targetArg = arg
            } else {
                print("Usage: rm [-r] <path>")
                return
            }
        }
        
        guard let targetName = targetArg else {
            print("Usage: rm [-r] <path>")
            return
        }
        
        let targetPath = resolvePath(targetName)
        if targetPath == "/" {
            print("rm: cannot remove root directory")
            return
        }
        
        let components = targetPath.components(separatedBy: "/")
        let childName = components.last ?? ""
        var parentPath = String(targetPath.prefix(upTo: targetPath.lastIndex(of: "/") ?? targetPath.endIndex))
        if parentPath.isEmpty { parentPath = "/" }
        
        guard let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: parentPath) else {
            print("rm: failed to access parent directory")
            return
        }
        
        guard let targetFile = files.first(where: { $0.name == childName }) else {
            print("rm: no such file or directory: \(targetName)")
            return
        }
        
        if targetFile.isFolder && !isRecursive {
            print("rm: \(targetName): is a directory (use -r to delete)")
            return
        }
        
        print("Are you sure you want to delete '\(targetPath)'? [y/n]: ", terminator: "")
        fflush(stdout)
        if let response = readLine(), response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
            print("Deleting \(targetPath)...")
            if CLIMTPClient.delete(deviceId: deviceId, storageId: storageId, files: [targetPath]) {
                print("Deleted.")
            } else {
                print("Failed to delete.")
            }
        } else {
            print("Aborted.")
        }
    }
    
    private func handleMv(args: [String]) {
        if args.count < 3 {
            print("Usage: mv <path> <new_path>")
            return
        }
        let targetPath = resolvePath(args[1])
        let targetNewPath = resolvePath(args[2])
        
        let targetComponents = targetPath.components(separatedBy: "/")
        let newComponents = targetNewPath.components(separatedBy: "/")
        
        if targetComponents.dropLast() != newComponents.dropLast() {
            print("mv: can only be used for renaming, not moving. The target directory must be the same.")
            return
        }
        
        if targetPath == "/" {
            print("mv: cannot rename root directory")
            return
        }
        
        let newName = newComponents.last ?? ""
        if newName.isEmpty {
            print("mv: new name cannot be empty")
            return
        }
        var parentPath = String(targetPath.prefix(upTo: targetPath.lastIndex(of: "/") ?? targetPath.endIndex))
        if parentPath.isEmpty { parentPath = "/" }
        
        if let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: parentPath) {
            if files.contains(where: { $0.name == newName }) {
                print("mv: a file or directory named '\(newName)' already exists")
                return
            }
        }
        
        print("Renaming '\(targetPath)' to '\(newName)'...")
        if CLIMTPClient.rename(deviceId: deviceId, storageId: storageId, path: targetPath, newName: newName) {
            print("Renamed.")
        } else {
            print("Failed to rename.")
        }
    }
    
    private func handleMkdir(args: [String]) {
        if args.count < 2 {
            print("Usage: mkdir <path>")
            return
        }
        let targetPath = resolvePath(args[1])
        
        let components = targetPath.components(separatedBy: "/")
        let newName = components.last ?? ""
        if newName.isEmpty {
            print("mkdir: directory name cannot be empty")
            return
        }
        
        var parentPath = String(targetPath.prefix(upTo: targetPath.lastIndex(of: "/") ?? targetPath.endIndex))
        if parentPath.isEmpty { parentPath = "/" }
        
        guard let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: parentPath) else {
            print("mkdir: parent directory '\(parentPath)' does not exist")
            return
        }
        
        if files.contains(where: { $0.name == newName }) {
            print("mkdir: a file or directory named '\(newName)' already exists")
            return
        }
        
        print("Creating directory '\(targetPath)'...")
        if CLIMTPClient.mkdir(deviceId: deviceId, storageId: storageId, path: targetPath) {
            print("Created.")
        } else {
            print("Failed to create directory.")
        }
    }
    
    private func handleInfo(args: [String]) {
        guard let devices = CLIMTPClient.fetchDevices(),
              let device = devices.first(where: { $0.id == deviceId }) else {
            print("Device info not available.")
            return
        }
        
        let usbMonitor = CLIUSBMonitor()
        let usbResult = usbMonitor.detectCurrentUSBProtocol(productHint: device.model, manufacturerHint: device.manufacturer)
        
        print("""
        Device Information
        ------------------
        Manufacturer: \(device.manufacturer.isEmpty ? "-" : device.manufacturer)
        Device Model: \(device.model)
        Protocol:     \(usbResult.protocolName) (\(usbResult.speedMbps) Mbps)
        """)
        
        if let storages = CLIMTPClient.fetchStorages(deviceId: deviceId),
           let storage = storages.first(where: { Int($0.id) == storageId }) {
            print("Storage:      \(storage.name)")
            print("Free Space:   \(storage.freeSpace)")
            print("Total Space:  \(storage.totalSpace)")
        }
    }
    
    private func resolvePath(_ input: String) -> String {
        let basePath = input.hasPrefix("/") ? input : "\(currentPath)/\(input)"
        let components = basePath.components(separatedBy: "/")
        var stack = [String]()
        
        for comp in components {
            if comp == "" || comp == "." {
                continue
            } else if comp == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                } else {
                    print("Warning: Already at root directory, cannot go up further.")
                }
            } else {
                stack.append(comp)
            }
        }
        
        return "/" + stack.joined(separator: "/")
    }
}

// MARK: - Main Logic

func printUsage() {
    let msg = """
    swiftmtp-cli - SwiftMTP command line tool
    
    Usage:
      swiftmtp-cli devices
      swiftmtp-cli storages <deviceId>
      swiftmtp-cli ls [-a] <deviceId> <storageId> <path>
      swiftmtp-cli pull <deviceId> <storageId> <remotePath> <localPath>
      swiftmtp-cli push <deviceId> <storageId> <localPath> <remotePath>
      swiftmtp-cli rm [-r] <deviceId> <storageId> <remotePath>
      swiftmtp-cli mv <deviceId> <storageId> <remotePath> <newPath>
      swiftmtp-cli mkdir <deviceId> <storageId> <remotePath>
      swiftmtp-cli shell <deviceId> <storageId>
      swiftmtp-cli info <deviceId> <storageId>
      
    Options:
      -h, --help     Show this help message and exit
      -v, --version  Show version information and exit
    
    """
    print(msg)
}

func printVersion() {
    print("SwiftMTP App    v1.2.4")
    print("swiftmtp-cli    v0.1.2")
    
    var sysinfo = utsname()
    uname(&sysinfo)
    
    let sysname = withUnsafeBytes(of: &sysinfo.sysname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    let release = withUnsafeBytes(of: &sysinfo.release) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    let machine = withUnsafeBytes(of: &sysinfo.machine) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    
    print("\(sysname) \(release) \(machine)")
}

func main() {
    var args = CommandLine.arguments
    if args.count < 2 {
        printUsage()
        exit(1)
    }
    
    let command = args[1]
    
    let deviceCommands = ["storages", "ls", "pull", "push", "rm", "mv", "mkdir", "shell", "info"]
    if deviceCommands.contains(command) {
        if let devices = CLIMTPClient.fetchDevices() {
            var deviceIdIndex = 2
            
            if command == "ls" && args.count > 2 && (args[2] == "-a" || args[2] == "-l" || args[2] == "-al" || args[2] == "-la") {
                deviceIdIndex = 3
            } else if command == "rm" && args.count > 2 && args[2] == "-r" {
                deviceIdIndex = 3
            }
            
            var providedDeviceId = false
            if args.count > deviceIdIndex {
                let arg = args[deviceIdIndex]
                for dev in devices {
                    let parts = dev.id.components(separatedBy: "|")
                    if dev.id == arg || parts.contains(arg) {
                        providedDeviceId = true
                        break
                    }
                }
                if !providedDeviceId && arg.contains("|") {
                    providedDeviceId = true
                }
            }
            
            let omitted = (args.count <= deviceIdIndex) || !providedDeviceId
            
            if omitted {
                if devices.count == 1 {
                    args.insert(devices[0].id, at: deviceIdIndex)
                } else if devices.count == 0 {
                    print("Error: No MTP devices connected. Please connect a device.")
                    exit(1)
                } else {
                    print("Error: Multiple MTP devices connected (\(devices.count)). You must explicitly specify a valid <deviceId>.")
                    exit(1)
                }
            }
        }
    }
    
    switch command {
    case "-h", "--help", "help":
        printUsage()
        exit(0)
        
    case "-v", "--version", "version":
        printVersion()
        exit(0)
        
    case "devices":
        guard let devices = CLIMTPClient.fetchDevices() else {
            print("Failed to fetch devices.")
            exit(1)
        }
        print("List of devices attached:")
        for dev in devices {
            print("\(dev.id)\tdevice\t\(dev.model) (\(dev.manufacturer))")
        }
        print("\nHint: Use any of the pipe-separated parts as <deviceId> for the following commands.\n")
        
    case "storages":
        if args.count < 3 {
            print("Usage: swiftmtp-cli storages <deviceId>")
            exit(1)
        }
        let deviceId = args[2]
        if !CLIMTPClient.initialize(deviceId: deviceId) {
            exit(1)
        }
        guard let storages = CLIMTPClient.fetchStorages(deviceId: deviceId) else {
            print("Failed to fetch storages.")
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        print("Storages for device \(deviceId):")
        for s in storages {
            print("\(s.id)\t\(s.name) (\(s.freeSpace) free / \(s.totalSpace) total)")
        }
        CLIMTPClient.dispose(deviceId: deviceId)
        
    case "ls":
        if args.count < 5 {
            print("Usage: swiftmtp-cli ls [-a] <deviceId> <storageId> <path>")
            exit(1)
        }
        // Basic parsing for -a
        var offset = 0
        var showAll = false
        if args[2] == "-a" || args[2] == "-l" || args[2] == "-al" || args[2] == "-la" {
            showAll = true
            offset = 1
        }
        
        if args.count < 5 + offset {
             print("Usage: swiftmtp-cli ls [-a] <deviceId> <storageId> <path>")
             exit(1)
        }
        
        let deviceId = args[2 + offset]
        let storageId = Int(args[3 + offset]) ?? 0
        let path = args[4 + offset]
        
        if !CLIMTPClient.initialize(deviceId: deviceId) { exit(1) }
        guard let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: path) else {
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        
        let sortedFiles = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for file in sortedFiles {
            if !showAll && file.name.hasPrefix(".") { continue }
            let type = file.isFolder ? "<DIR>" : "     "
            let sizeStr = file.isFolder ? "-" : String(file.size)
            let paddedSize = String(repeating: " ", count: max(0, 12 - sizeStr.count)) + sizeStr
            let dateStr = file.dateAdded.padding(toLength: 20, withPad: " ", startingAt: 0)
            print("\(type) \(paddedSize)  \(dateStr)  \(file.name)")
        }
        CLIMTPClient.dispose(deviceId: deviceId)
        
    case "pull":
        if args.count < 6 {
            print("Usage: swiftmtp-cli pull <deviceId> <storageId> <remotePath> <localPath>")
            exit(1)
        }
        let deviceId = args[2]
        let storageId = Int(args[3]) ?? 0
        let remotePath = args[4]
        let localPath = NSString(string: args[5]).expandingTildeInPath
        
        let remoteName = remotePath.components(separatedBy: "/").last ?? ""
        var localDestination = localPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir) {
            if isDir.boolValue {
                localDestination = (localPath as NSString).appendingPathComponent(remoteName)
            }
        }
        
        if FileManager.default.fileExists(atPath: localDestination) {
            print("pull: '\(localDestination)' already exists locally. Overwrite? [y/n]: ", terminator: "")
            fflush(stdout)
            if let response = readLine(), response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
                // proceed
            } else {
                print("Aborted.")
                exit(1)
            }
        }
        
        if !CLIMTPClient.initialize(deviceId: deviceId) { exit(1) }
        if CLIMTPClient.pull(deviceId: deviceId, storageId: storageId, sources: [remotePath], destination: localPath) {
            print("Pull complete.")
        } else {
            print("Pull failed.")
        }
        CLIMTPClient.dispose(deviceId: deviceId)
        
    case "push":
        if args.count < 6 {
            print("Usage: swiftmtp-cli push <deviceId> <storageId> <localPath> <remotePath>")
            exit(1)
        }
        let deviceId = args[2]
        let storageId = Int(args[3]) ?? 0
        let localPath = NSString(string: args[4]).expandingTildeInPath
        let remotePath = args[5]
        
        if !CLIMTPClient.initialize(deviceId: deviceId) { exit(1) }
        
        let localName = URL(fileURLWithPath: localPath).lastPathComponent
        if let remoteFiles = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: remotePath) {
            if remoteFiles.contains(where: { $0.name == localName }) {
                print("push: '\(localName)' already exists in '\(remotePath)'. Overwrite? [y/n]: ", terminator: "")
                fflush(stdout)
                if let response = readLine(), response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
                    // proceed
                } else {
                    print("Aborted.")
                    CLIMTPClient.dispose(deviceId: deviceId)
                    exit(1)
                }
            }
        }
        
        if CLIMTPClient.push(deviceId: deviceId, storageId: storageId, sources: [localPath], destination: remotePath) {
            print("Push complete.")
        } else {
            print("Push failed.")
        }
        CLIMTPClient.dispose(deviceId: deviceId)
        
    case "rm":
        var offset = 0
        var isRecursive = false
        if args.count > 2 && (args[2] == "-r" || args[2] == "-R") {
            isRecursive = true
            offset = 1
        }
        
        if args.count < 5 + offset {
            print("Usage: swiftmtp-cli rm [-r] <deviceId> <storageId> <remotePath>")
            exit(1)
        }
        
        let deviceId = args[2 + offset]
        let storageId = Int(args[3 + offset]) ?? 0
        let path = args[4 + offset]
        
        if !CLIMTPClient.initialize(deviceId: deviceId) { exit(1) }
        
        if path == "/" {
            print("rm: cannot remove root directory")
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        
        let components = path.components(separatedBy: "/")
        let childName = components.last ?? ""
        var parentPath = String(path.prefix(upTo: path.lastIndex(of: "/") ?? path.endIndex))
        if parentPath.isEmpty { parentPath = "/" }
        
        guard let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: parentPath) else {
            print("rm: failed to access parent directory")
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        
        guard let targetFile = files.first(where: { $0.name == childName }) else {
            print("rm: no such file or directory: \(path)")
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        
        if targetFile.isFolder && !isRecursive {
            print("rm: \(path): is a directory (use -r to delete)")
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        
        print("Are you sure you want to delete '\(path)'? [y/n]: ", terminator: "")
        fflush(stdout)
        if let response = readLine(), response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "y" {
            print("Deleting \(path)...")
            if CLIMTPClient.delete(deviceId: deviceId, storageId: storageId, files: [path]) {
                print("Deleted.")
            } else {
                print("Failed to delete.")
            }
        } else {
            print("Aborted.")
        }
        CLIMTPClient.dispose(deviceId: deviceId)
        
    case "mv":
        if args.count < 6 {
            print("Usage: swiftmtp-cli mv <deviceId> <storageId> <remotePath> <newPath>")
            exit(1)
        }
        
        let deviceId = args[2]
        let storageId = Int(args[3]) ?? 0
        let path = args[4]
        let newPath = args[5]
        
        let targetComponents = path.components(separatedBy: "/")
        let newComponents = newPath.components(separatedBy: "/")
        
        if targetComponents.dropLast() != newComponents.dropLast() {
            print("mv: can only be used for renaming, not moving. The target directory must be the same.")
            exit(1)
        }
        
        if path == "/" {
            print("mv: cannot rename root directory")
            exit(1)
        }
        
        if !CLIMTPClient.initialize(deviceId: deviceId) { exit(1) }
        
        let newName = newComponents.last ?? ""
        if newName.isEmpty {
            print("mv: new name cannot be empty")
            exit(1)
        }
        var parentPath = String(path.prefix(upTo: path.lastIndex(of: "/") ?? path.endIndex))
        if parentPath.isEmpty { parentPath = "/" }
        
        if let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: parentPath) {
            if files.contains(where: { $0.name == newName }) {
                print("mv: a file or directory named '\(newName)' already exists")
                CLIMTPClient.dispose(deviceId: deviceId)
                exit(1)
            }
        }
        
        print("Renaming '\(path)' to '\(newName)'...")
        if CLIMTPClient.rename(deviceId: deviceId, storageId: storageId, path: path, newName: newName) {
            print("Renamed.")
        } else {
            print("Failed to rename.")
        }
        CLIMTPClient.dispose(deviceId: deviceId)
        
    case "mkdir":
        if args.count < 5 {
            print("Usage: swiftmtp-cli mkdir <deviceId> <storageId> <remotePath>")
            exit(1)
        }
        
        let deviceId = args[2]
        let storageId = Int(args[3]) ?? 0
        let path = args[4]
        
        let components = path.components(separatedBy: "/")
        let newName = components.last ?? ""
        if newName.isEmpty {
            print("mkdir: directory name cannot be empty")
            exit(1)
        }
        
        if !CLIMTPClient.initialize(deviceId: deviceId) { exit(1) }
        
        var parentPath = String(path.prefix(upTo: path.lastIndex(of: "/") ?? path.endIndex))
        if parentPath.isEmpty { parentPath = "/" }
        
        guard let files = CLIMTPClient.walk(deviceId: deviceId, storageId: storageId, path: parentPath) else {
            print("mkdir: parent directory '\(parentPath)' does not exist")
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        
        if files.contains(where: { $0.name == newName }) {
            print("mkdir: a file or directory named '\(newName)' already exists")
            CLIMTPClient.dispose(deviceId: deviceId)
            exit(1)
        }
        
        print("Creating directory '\(path)'...")
        if CLIMTPClient.mkdir(deviceId: deviceId, storageId: storageId, path: path) {
            print("Created.")
        } else {
            print("Failed to create directory.")
        }
        CLIMTPClient.dispose(deviceId: deviceId)
        
    case "info":
        if args.count < 4 {
            print("Usage: swiftmtp-cli info <deviceId> <storageId>")
            exit(1)
        }
        
        let deviceId = args[2]
        let storageId = Int(args[3]) ?? 0
        
        guard let devices = CLIMTPClient.fetchDevices(),
              let device = devices.first(where: { $0.id == deviceId }) else {
            print("Failed to fetch device info.")
            exit(1)
        }
        
        let usbMonitor = CLIUSBMonitor()
        let usbResult = usbMonitor.detectCurrentUSBProtocol(productHint: device.model, manufacturerHint: device.manufacturer)
        
        print("""
        Device Information
        ------------------
        Manufacturer: \(device.manufacturer.isEmpty ? "-" : device.manufacturer)
        Device Model: \(device.model)
        Protocol:     \(usbResult.protocolName) (\(usbResult.speedMbps) Mbps)
        """)
        
        if let storages = CLIMTPClient.fetchStorages(deviceId: deviceId),
           let storage = storages.first(where: { Int($0.id) == storageId }) {
            print("Storage:      \(storage.name)")
            print("Free Space:   \(storage.freeSpace)")
            print("Total Space:  \(storage.totalSpace)")
        }
        
    case "shell":
        if args.count < 4 {
            print("Usage: swiftmtp-cli shell <deviceId> <storageId>")
            exit(1)
        }
        let deviceId = args[2]
        let storageId = Int(args[3]) ?? 0
        
        if !CLIMTPClient.initialize(deviceId: deviceId) {
            print("Failed to connect to device.")
            exit(1)
        }
        
        let shell = InteractiveShell(deviceId: deviceId, storageId: storageId)
        shell.run()
        
        CLIMTPClient.dispose(deviceId: deviceId)
        print("Disconnected. Bye.")
        
    default:
        print("Unknown command.")
        printUsage()
        exit(1)
    }
}

main()
