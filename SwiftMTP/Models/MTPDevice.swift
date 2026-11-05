import Foundation
import CoreFoundation

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

    let freeSpaceKnown: Bool
    let totalSpaceKnown: Bool

    init(id: String, name: String, freeSpace: Int64?, totalSpace: Int64?) {
        self.id = id
        self.name = name
        self.freeSpaceKnown = freeSpace.map { $0 >= 0 } ?? false
        // A zero total cannot describe a usable capacity (e.g. virtual storages).
        self.totalSpaceKnown = totalSpace.map { $0 > 0 } ?? false
        self.freeSpace = freeSpaceKnown ? freeSpace! : 0
        self.totalSpace = totalSpaceKnown ? totalSpace! : 0
    }

    var hasCapacityInfo: Bool {
        totalSpaceKnown && freeSpaceKnown && freeSpace <= totalSpace
    }

    // The numeric placeholder is consumed only when hasCapacityInfo is true.
    var usedSpace: Int64 { hasCapacityInfo ? totalSpace - freeSpace : 0 }

    var displayFreeSpace: String { freeSpaceKnown ? formatBytes(freeSpace) : "—" }
    var displayTotalSpace: String { totalSpaceKnown ? formatBytes(totalSpace) : "—" }

    /// Preserve integer precision across JSON/NSNumber bridging; never wrap or truncate.
    static func capacityBytes(from value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let bytes = UInt64(number.stringValue), bytes != UInt64.max else { return nil }
        return Int64(exactly: bytes)
    }

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
