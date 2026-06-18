import Darwin
import Foundation
import IOKit

final class SerialPort {
    private static let espressifVendorID = 0x303A
    private let fileHandle: FileHandle
    let path: String

    private init?(path: String) {
        guard let fileHandle = FileHandle(forWritingAtPath: path) else {
            return nil
        }

        guard Self.configure(fileHandle.fileDescriptor) else {
            try? fileHandle.close()
            return nil
        }

        self.path = path
        self.fileHandle = fileHandle
    }

    static func openFirstAvailable() -> SerialPort? {
        let paths = candidatePaths()

        for path in paths {
            if let port = SerialPort(path: path) {
                print("found serial port: \(path)")
                return port
            }

            print("could not open or configure serial port: \(path)")
        }

        if paths.isEmpty {
            print("no matching serial devices discovered")
        }

        return nil
    }

    func writeLine(_ line: String) -> Bool {
        guard let data = "\(line)\n".data(using: .utf8) else {
            return false
        }

        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return data.isEmpty
            }

            var offset = 0

            while offset < data.count {
                let written = Darwin.write(
                    fileHandle.fileDescriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )

                if written > 0 {
                    offset += written
                    continue
                }

                if written < 0, errno == EINTR {
                    continue
                }

                return false
            }

            return true
        }
    }

    func close() {
        try? fileHandle.close()
    }

    private static func candidatePaths() -> [String] {
        let discovered = serialDevices()
        let espressif = discovered
            .filter { $0.vendorID == espressifVendorID }
            .map(\.path)
        let fallback = discovered
            .map(\.path)
            .filter(isLikelyUSBSerialPath)
        let filesystemFallback = filesystemSerialPaths()

        var seen: Set<String> = []

        return (
            espressif.sorted() +
            fallback.sorted() +
            filesystemFallback.sorted()
        ).filter {
            seen.insert($0).inserted
        }
    }

    private static func filesystemSerialPaths() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: "/dev"
        ) else {
            return []
        }

        return entries
            .map { "/dev/\($0)" }
            .filter(isLikelyUSBSerialPath)
    }

    private static func serialDevices() -> [(path: String, vendorID: Int?)] {
        guard let matching = IOServiceMatching("IOSerialBSDClient") else {
            return []
        }

        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }

        defer {
            IOObjectRelease(iterator)
        }

        var result: [(path: String, vendorID: Int?)] = []
        var service = IOIteratorNext(iterator)

        while service != 0 {
            if let path = stringProperty(
                "IOCalloutDevice",
                entry: service
            ) {
                result.append(
                    (path: path, vendorID: usbVendorID(entry: service))
                )
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return result
    }

    private static func usbVendorID(entry: io_registry_entry_t) -> Int? {
        var current = entry

        while current != 0 {
            if let value = numberProperty("idVendor", entry: current) {
                if current != entry {
                    IOObjectRelease(current)
                }
                return value
            }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(
                current,
                kIOServicePlane,
                &parent
            )

            if current != entry {
                IOObjectRelease(current)
            }

            guard result == KERN_SUCCESS else {
                return nil
            }

            current = parent
        }

        return nil
    }

    private static func stringProperty(
        _ key: String,
        entry: io_registry_entry_t
    ) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }

        return value as? String
    }

    private static func numberProperty(
        _ key: String,
        entry: io_registry_entry_t
    ) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }

        return value.intValue
    }

    private static func isLikelyUSBSerialPath(_ path: String) -> Bool {
        path.hasPrefix("/dev/cu.usbmodem") ||
        path.hasPrefix("/dev/cu.usbserial") ||
        path.hasPrefix("/dev/cu.SLAB_USBtoUART")
    }

    private static func configure(_ fileDescriptor: Int32) -> Bool {
        var options = termios()

        guard tcgetattr(fileDescriptor, &options) == 0 else {
            return false
        }

        cfmakeraw(&options)

        guard cfsetspeed(&options, speed_t(B115200)) == 0 else {
            return false
        }

        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)

        return tcsetattr(fileDescriptor, TCSANOW, &options) == 0
    }
}
