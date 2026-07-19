import Foundation
import IOKit

class CLIUSBMonitor {
    
    typealias USBDetectionResult = (protocolName: String, speedMbps: Int, maxSpeedBytesPerSecond: Double)
    private let monitoredServiceClass = "IOUSBHostDevice"
    
    func detectCurrentUSBProtocol(productHint: String? = nil, manufacturerHint: String? = nil) -> USBDetectionResult {
        if let hostResult = detectCurrentUSBProtocol(
            serviceClasses: [monitoredServiceClass],
            productHint: productHint,
            manufacturerHint: manufacturerHint
        ) {
            return hostResult
        }

        if let legacyResult = detectCurrentUSBProtocol(
            serviceClasses: ["IOUSBDevice"],
            productHint: productHint,
            manufacturerHint: manufacturerHint
        ) {
            return legacyResult
        }

        return ("Unknown", 0, 42_000_000)
    }

    private func detectCurrentUSBProtocol(
        serviceClasses: [String],
        productHint: String?,
        manufacturerHint: String?
    ) -> USBDetectionResult? {
        var bestMatch: (score: Int, result: USBDetectionResult)? = nil

        for serviceClass in serviceClasses {
            guard let matchingDict = IOServiceMatching(serviceClass) else { continue }

            var iterator: io_iterator_t = IO_OBJECT_NULL
            let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
            guard result == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            var device = IOIteratorNext(iterator)
            while device != IO_OBJECT_NULL {
                let detected = detectUSBProtocol(for: device)
                let score = scoreCandidateDevice(
                    device,
                    detected: detected,
                    productHint: productHint,
                    manufacturerHint: manufacturerHint
                )

                if let currentBest = bestMatch {
                    if score > currentBest.score || (score == currentBest.score && detected.speedMbps > currentBest.result.speedMbps) {
                        bestMatch = (score, detected)
                    }
                } else {
                    bestMatch = (score, detected)
                }

                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
            }
        }

        return bestMatch?.result
    }
    
    private func detectUSBProtocol(for device: io_object_t) -> USBDetectionResult {
        guard device != IO_OBJECT_NULL else {
            return ("Unknown", 0, 42_000_000)
        }

        if let detected = detectUSBProtocolDirectly(for: device) {
            return detected
        }

        if let parent = getParentEntry(device) {
            defer { IOObjectRelease(parent) }
            if let detected = detectUSBProtocolDirectly(for: parent) {
                return detected
            }
        }

        return ("Unknown", 0, 42_000_000)
    }

    private func detectUSBProtocolDirectly(for entry: io_object_t) -> USBDetectionResult? {
        if let linkSpeed = numericProperty(from: entry, keys: ["UsbLinkSpeed", "USBLinkSpeed", "LinkSpeed"]) {
            let speedMbps = normalizeLinkSpeedToMbps(linkSpeed)
            let protocolName = protocolName(forSpeedMbps: speedMbps)
            return detectionResult(protocolName: protocolName, speedMbps: speedMbps)
        }

        if let speedString = stringProperty(from: entry, keys: ["USBDeviceSpeed", "DeviceSpeed", "Speed"]) {
            return parseSpeed(speedString)
        }

        if let deviceSpeed = numericProperty(from: entry, keys: ["Device Speed"]),
           let detected = parseDeviceSpeedCode(deviceSpeed) {
            return detected
        }

        if let protocolName = controllerProtocolName(for: entry) {
            return detectionResult(protocolName: protocolName, speedMbps: speedMbps(forProtocolName: protocolName))
        }

        return nil
    }

    private func parseSpeed(_ speed: String) -> USBDetectionResult {
        let lowercased = speed.lowercased().replacingOccurrences(of: " ", with: "")
        switch lowercased {
        case "low", "lowspeed":
            return ("USB 2.0", 1, 42_000_000)
        case "full", "fullspeed":
            return ("USB 2.0", 12, 42_000_000)
        case "high", "highspeed":
            return ("USB 2.0", 480, 42_000_000)
        case "superspeed", "ss":
            return ("USB 3.0", 5_000, 437_500_000)
        case let s where s.contains("superspeedplus") || s.contains("ssp"):
            if lowercased.contains("10") {
                return ("USB 3.1", 10_000, 875_000_000)
            } else if lowercased.contains("20") {
                return ("USB 3.2", 20_000, 1_750_000_000)
            }
            return ("USB 3.1", 10_000, 875_000_000)
        default:
            if let numericSpeed = parseNumericSpeed(lowercased) {
                switch numericSpeed {
                case 20_000...:
                    return ("USB 3.2", numericSpeed, 1_750_000_000)
                case 10_000...:
                    return ("USB 3.1", numericSpeed, 875_000_000)
                case 5_000...:
                    return ("USB 3.0", numericSpeed, 437_500_000)
                case 480...:
                    return ("USB 2.0", numericSpeed, 42_000_000)
                case 12...:
                    return ("USB 2.0", numericSpeed, 42_000_000)
                case 1...:
                    return ("USB 2.0", numericSpeed, 42_000_000)
                default:
                    break
                }
            }
            return ("Unknown", 0, 42_000_000)
        }
    }

    private func parseNumericSpeed(_ rawValue: String) -> Int? {
        let digits = rawValue.filter(\.isNumber)
        guard let value = Int(digits), value > 0 else { return nil }

        if rawValue.contains("gbps") || rawValue.contains("gbit") {
            return value * 1_000
        }

        return value
    }

    private func parseDeviceSpeedCode(_ value: Int) -> USBDetectionResult? {
        switch value {
        case 0: return ("USB 2.0", 1, 42_000_000)
        case 1: return ("USB 2.0", 12, 42_000_000)
        case 2: return ("USB 2.0", 480, 42_000_000)
        case 3: return ("USB 3.0", 5_000, 437_500_000)
        case 4: return ("USB 3.1", 10_000, 875_000_000)
        case 5: return ("USB 3.2", 20_000, 1_750_000_000)
        default: return nil
        }
    }

    private func numericProperty(from entry: io_object_t, keys: [String]) -> Int? {
        for key in keys {
            if let value = getProperty(entry, key: key as CFString) {
                switch value {
                case let number as NSNumber:
                    return number.intValue
                case let string as String:
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let decimal = Int(trimmed) { return decimal }
                    if trimmed.hasPrefix("0x"), let hex = Int(trimmed.dropFirst(2), radix: 16) { return hex }
                default: break
                }
            }
        }
        return nil
    }

    private func stringProperty(from entry: io_object_t, keys: [String]) -> String? {
        for key in keys {
            if let value = getProperty(entry, key: key as CFString) {
                switch value {
                case let string as String:
                    if !string.isEmpty { return string }
                case let number as NSNumber:
                    return number.stringValue
                default: break
                }
            }
        }
        return nil
    }

    private func protocolName(forSpeedMbps speedMbps: Int) -> String {
        switch speedMbps {
        case 20_000...: return "USB 3.2"
        case 10_000...: return "USB 3.1"
        case 5_000...: return "USB 3.0"
        case 1...: return "USB 2.0"
        default: return "Unknown"
        }
    }

    private func controllerProtocolName(for entry: io_object_t) -> String? {
        if let revision = stringProperty(from: entry, keys: ["UsbHostControllerProtocolRevision"]) {
            return parseControllerProtocolRevision(revision)
        }
        if let parent = getParentEntry(entry) {
            defer { IOObjectRelease(parent) }
            return controllerProtocolName(for: parent)
        }
        return nil
    }

    private func parseControllerProtocolRevision(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "2", "2.0": return "USB 2.0"
        case "3", "3.0": return "USB 3.0"
        case "3.1": return "USB 3.1"
        case "3.2": return "USB 3.2"
        default: return nil
        }
    }

    private func speedMbps(forProtocolName protocolName: String) -> Int {
        switch protocolName {
        case "USB 3.2": return 20_000
        case "USB 3.1": return 10_000
        case "USB 3.0": return 5_000
        case "USB 2.0": return 480
        default: return 0
        }
    }

    private func detectionResult(protocolName: String, speedMbps: Int) -> USBDetectionResult {
        switch protocolName {
        case "USB 3.2": return (protocolName, max(speedMbps, 20_000), 1_750_000_000)
        case "USB 3.1": return (protocolName, max(speedMbps, 10_000), 875_000_000)
        case "USB 3.0": return (protocolName, max(speedMbps, 5_000), 437_500_000)
        case "USB 2.0": return (protocolName, max(speedMbps, 1), 42_000_000)
        default: return ("Unknown", 0, 42_000_000)
        }
    }

    private func normalizeLinkSpeedToMbps(_ rawValue: Int) -> Int {
        if rawValue >= 1_000_000 {
            return max(1, Int(round(Double(rawValue) / 1_000_000.0)))
        }
        return rawValue
    }

    private func scoreCandidateDevice(
        _ device: io_object_t,
        detected: USBDetectionResult,
        productHint: String?,
        manufacturerHint: String?
    ) -> Int {
        let texts = [
            stringProperty(from: device, keys: ["USB Product Name", "kUSBProductString"]),
            stringProperty(from: device, keys: ["USB Vendor Name", "kUSBVendorString"]),
            getDeviceName(device)
        ].compactMap { $0?.lowercased() }

        let productHint = productHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let manufacturerHint = manufacturerHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var score = detected.speedMbps
        var matchedHint = false

        if let productHint, !productHint.isEmpty {
            if texts.contains(where: { $0.contains(productHint) || productHint.contains($0) }) {
                score += 50_000
                matchedHint = true
            }
        }

        if let manufacturerHint, !manufacturerHint.isEmpty {
            if texts.contains(where: { $0.contains(manufacturerHint) || manufacturerHint.contains($0) }) {
                score += 20_000
                matchedHint = true
            }
        }

        if numericProperty(from: device, keys: ["UsbLinkSpeed", "USBLinkSpeed", "LinkSpeed"]) != nil {
            score += 100_000
        }

        if (productHint?.isEmpty == false || manufacturerHint?.isEmpty == false), !matchedHint {
            score -= 25_000
        }

        if let vendorId = numericProperty(from: device, keys: ["idVendor"]), vendorId != 1452 {
            score += 5_000
        }

        return score
    }
    
    private func getProperty(_ entry: io_object_t, key: CFString) -> Any? {
        guard let property = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0) else {
            return nil
        }
        return property.takeRetainedValue()
    }
    
    private func getParentEntry(_ entry: io_object_t) -> io_object_t? {
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
        guard result == KERN_SUCCESS, parent != IO_OBJECT_NULL else {
            return nil
        }
        return parent
    }
    
    private func getDeviceName(_ device: io_object_t) -> String? {
        var name = [CChar](repeating: 0, count: 128)
        let result = IORegistryEntryGetName(device, &name)
        if result == KERN_SUCCESS {
            return String(cString: name)
        }
        return nil
    }
}
