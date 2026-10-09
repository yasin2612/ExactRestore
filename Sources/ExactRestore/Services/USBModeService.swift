import Foundation

/// Reads the host's USB tree to tell DFU apart from other modes, since cfgutil reports the same data for both.
enum USBModeService {
    private static let appleVendorID = 0x05AC
    private static let dfuProductID = 0x1227
    private static let recoveryProductIDs: Set<Int> = [0x1280, 0x1281, 0x1282, 0x1283]

    /// Returns modes keyed by ECID, or nil if the USB tree could not be read.
    static func modesByECID() async -> [UInt64: DeviceMode]? {
        guard
            let output = try? await ShellRunner.run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOUSBHostDevice", "-l"]),
            let data = output.data(using: .utf8),
            let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return nil }

        var modes: [UInt64: DeviceMode] = [:]
        collect(entries, into: &modes)
        return modes
    }

    /// Walks the whole tree, because Macs behind a hub are nested under the hub's entry.
    private static func collect(_ entries: [[String: Any]], into modes: inout [UInt64: DeviceMode]) {
        for entry in entries {
            if let children = entry["IORegistryEntryChildren"] as? [[String: Any]] {
                collect(children, into: &modes)
            }

            guard
                (entry["idVendor"] as? Int) == appleVendorID,
                let product = entry["idProduct"] as? Int,
                let serial = (entry["USB Serial Number"] ?? entry["kUSBSerialNumberString"]) as? String,
                let ecid = ecid(fromUSBSerial: serial)
            else { continue }

            if product == dfuProductID {
                modes[ecid] = .dfu
            } else if recoveryProductIDs.contains(product) {
                modes[ecid] = .recovery
            }
        }
    }

    /// DFU and Recovery serials look like "CPID:8012 ... ECID:00114DA20C418026 ...".
    static func ecid(fromUSBSerial serial: String) -> UInt64? {
        guard let range = serial.range(of: "ECID:") else { return nil }
        return UInt64(serial[range.upperBound...].prefix(while: \.isHexDigit), radix: 16)
    }

    static func ecid(fromCfgutil value: String) -> UInt64? {
        let hex = value.lowercased().hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return UInt64(hex, radix: 16)
    }
}
