import Foundation

struct MTPFile: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let size: Int64
    var sizeKnown = true
    let dateModified: Date
    let isDirectory: Bool
    let path: String
    let extension_: String

    /// The Go bridge sends an ISO 8601 instant with an explicit time zone.
    /// Keep that instant intact; the views apply the Mac's display time zone.
    static func parseModificationDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    var displaySize: String {
        guard !isDirectory, sizeKnown else { return "—" }
        let bytes = Double(size)
        if bytes < 1024 { return "\(size) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", bytes / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", bytes / 1024 / 1024) }
        return String(format: "%.2f GB", bytes / 1024 / 1024 / 1024)
    }

    var kind: String {
        if isDirectory { return String(localized: "Folder") }
        switch extension_.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return String(localized: "Image")
        case "mp4", "mov", "avi", "mkv", "3gp": return String(localized: "Video")
        case "mp3", "aac", "flac", "wav", "m4a": return String(localized: "Audio")
        case "pdf": return String(localized: "PDF")
        case "zip", "rar", "7z": return String(localized: "Archive")
        case "apk": return String(localized: "APK")
        case "": return String(localized: "File")
        default: return String(localized: "\(extension_.uppercased()) file")
        }
    }

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        switch extension_.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv", "3gp": return "film"
        case "mp3", "aac", "flac", "wav", "m4a": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z": return "archivebox"
        case "apk": return "app.badge"
        default: return "doc"
        }
    }
}

extension MTPFile {
    static let mock: [MTPFile] = [
        MTPFile(id: "1", name: "DCIM", size: 0, dateModified: Date().addingTimeInterval(-86400), isDirectory: true, path: "/DCIM", extension_: ""),
        MTPFile(id: "2", name: "Download", size: 0, dateModified: Date().addingTimeInterval(-3600 * 5), isDirectory: true, path: "/Download", extension_: ""),
        MTPFile(id: "3", name: "Music", size: 0, dateModified: Date().addingTimeInterval(-3600 * 12), isDirectory: true, path: "/Music", extension_: ""),
        MTPFile(id: "4", name: "Podcasts", size: 0, dateModified: Date().addingTimeInterval(-86400 * 3), isDirectory: true, path: "/Podcasts", extension_: ""),
        MTPFile(id: "5", name: "Android", size: 0, dateModified: Date().addingTimeInterval(-86400 * 7), isDirectory: true, path: "/Android", extension_: ""),
        MTPFile(id: "6", name: "screenshot_20240101.png", size: 2_048_000, dateModified: Date().addingTimeInterval(-3600 * 2), isDirectory: false, path: "/screenshot_20240101.png", extension_: "png"),
        MTPFile(id: "7", name: "recording.mp4", size: 150_000_000, dateModified: Date().addingTimeInterval(-3600 * 8), isDirectory: false, path: "/recording.mp4", extension_: "mp4"),
        MTPFile(id: "8", name: "backup.zip", size: 45_000_000, dateModified: Date().addingTimeInterval(-86400 * 2), isDirectory: false, path: "/backup.zip", extension_: "zip"),
    ]
}
