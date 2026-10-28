import Foundation

struct MTPDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let manufacturer: String
    let storages: [MTPStorage]
    let usbProtocol: USBProtocol
    let usbSpeedMbps: Int
    let maxSpeedBytesPerSecond: Double

    var usbLinkDescription: String {
        usbProtocol.linkDescription(speedMbps: usbSpeedMbps)
    }

    static let mock = MTPDevice(
        id: "device-1",
        name: "Pixel 10 Pro",
        manufacturer: "Google",
        storages: [
            MTPStorage(id: "storage-1", name: "Internal shared storage", freeSpace: 45_000_000_000, totalSpace: 256_000_000_000)
        ],
        usbProtocol: .usb31,
        usbSpeedMbps: 10_000,
        maxSpeedBytesPerSecond: 880_000_000
    )
}

struct MTPStorage: Identifiable, Equatable {
    let id: String
    let name: String
    let freeSpace: Int64
    let totalSpace: Int64

    var usedSpace: Int64 { totalSpace - freeSpace }

    /// Some storages (e.g. DBI's virtual Album) report no capacity at all.
    var hasCapacityInfo: Bool { totalSpace > 0 }

    var displayFreeSpace: String { hasCapacityInfo ? formatBytes(freeSpace) : "-" }
    var displayTotalSpace: String { hasCapacityInfo ? formatBytes(totalSpace) : "-" }

    private func formatBytes(_ bytes: Int64) -> String {
        let d = Double(bytes)
        if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1f MB", d / 1e6) }
        return String(format: "%.1f KB", d / 1e3)
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(MTPDevice)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var device: MTPDevice? {
        if case .connected(let d) = self { return d }
        return nil
    }
}
