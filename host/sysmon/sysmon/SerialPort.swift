import Darwin
import Foundation
import IOKit

/// A write-only handle to the board's USB CDC serial device.
///
/// The agent only ever sends stats lines to the board, so this never reads.
/// Discovery prefers the Espressif USB vendor ID; see `candidatePaths`.
final class SerialPort {
    /// Espressif's USB vendor ID. The ESP32-S3's native USB enumerates under
    /// this VID, so it's how we tell the board apart from other serial devices.
    private static let espressifVendorID = 0x303A
    private let fileHandle: FileHandle
    let path: String

    /// Opens and configures `path`, or fails if it can't be opened as a tty.
    private init?(path: String) {
        guard let fileHandle = FileHandle(forWritingAtPath: path) else {
            return nil
        }

        // A serial device that can't be put into raw 115200 8N1 mode isn't the
        // link we want; close the fd rather than leak it.
        guard Self.configure(fileHandle.fileDescriptor) else {
            try? fileHandle.close()
            return nil
        }

        self.path = path
        self.fileHandle = fileHandle
    }

    /// Finds and opens the board, preferring a VID-verified Espressif device
    /// and only falling back to other USB serial devices (loudly) if none.
    /// Returns `nil` when nothing usable is present; the caller retries.
    static func openFirstAvailable() -> SerialPort? {
        let candidates = candidatePaths()

        for path in candidates.verified {
            if let port = SerialPort(path: path) {
                print("found Espressif board: \(path)")
                return port
            }

            print("could not open or configure serial port: \(path)")
        }

        // Only fall back to non-Espressif USB serial devices when no board
        // with VID 0x303A is present, and never silently: writing stats into
        // an unrelated USB-serial dongle would be confusing, so name it.
        for path in candidates.fallback {
            if let port = SerialPort(path: path) {
                print("warning: no Espressif board found; using unverified "
                    + "USB serial device \(path)")
                return port
            }

            print("could not open or configure serial port: \(path)")
        }

        if candidates.verified.isEmpty, candidates.fallback.isEmpty {
            print("no matching serial devices discovered")
        }

        return nil
    }

    /// Writes one newline-terminated stats line to the board.
    ///
    /// Returns `false` on a real write error (e.g. the board was unplugged),
    /// which the run loop treats as the signal to reconnect.
    func writeLine(_ line: String) -> Bool {
        guard let data = "\(line)\n".data(using: .utf8) else {
            return false
        }

        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return data.isEmpty
            }

            // write(2) may return short or be interrupted, so loop until the
            // whole line is out, retrying on EINTR and bailing on any error.
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

    /// Splits discovered serial devices into VID-verified Espressif boards and
    /// best-effort fallbacks (other USB-serial devices plus a raw `/dev` scan),
    /// deduplicated and sorted for stable ordering.
    private static func candidatePaths() -> (verified: [String], fallback: [String]) {
        let discovered = serialDevices()
        let espressif = Set(
            discovered
                .filter { $0.vendorID == espressifVendorID }
                .map(\.path)
        )
        let usbSerial = discovered
            .map(\.path)
            .filter(isLikelyUSBSerialPath)
        let filesystemFallback = filesystemSerialPaths()

        let verified = espressif.sorted()

        var seen = espressif
        let fallback = (usbSerial.sorted() + filesystemFallback.sorted())
            .filter { seen.insert($0).inserted }

        return (verified: verified, fallback: fallback)
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

    /// Enumerates serial devices via IOKit, returning each one's callout path
    /// and (if it sits under a USB device) its vendor ID.
    private static func serialDevices() -> [(path: String, vendorID: Int?)] {
        // IOSerialBSDClient is the IOKit class backing every /dev tty/cu node.
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
            // Use the callout (/dev/cu.*) node, not the dial-in (/dev/tty.*)
            // one: opening cu.* does not block waiting for carrier detect.
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

    /// Walks up the IOKit service plane from a serial node until it finds the
    /// `idVendor` of the enclosing USB device, releasing intermediate parents.
    /// The original `entry` is owned by the caller and left untouched.
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

    /// Matches the common macOS naming for USB serial callout nodes (native
    /// USB CDC, FTDI/CP210x dongles, and Silicon Labs drivers).
    private static func isLikelyUSBSerialPath(_ path: String) -> Bool {
        path.hasPrefix("/dev/cu.usbmodem") ||
        path.hasPrefix("/dev/cu.usbserial") ||
        path.hasPrefix("/dev/cu.SLAB_USBtoUART")
    }

    /// Puts the tty into raw 115200 8N1 mode to match the firmware's serial
    /// settings, returning `false` if any termios call fails.
    private static func configure(_ fileDescriptor: Int32) -> Bool {
        var options = termios()

        guard tcgetattr(fileDescriptor, &options) == 0 else {
            return false
        }

        // Raw mode: no line editing, echo, or signal/flow processing — the
        // bytes we write should reach the board verbatim.
        cfmakeraw(&options)

        guard cfsetspeed(&options, speed_t(B115200)) == 0 else {
            return false
        }

        // CLOCAL: ignore modem control lines (USB CDC has none).
        // CREAD: enable the receiver. Then force 8 data bits, no parity,
        // one stop bit (8N1).
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)

        return tcsetattr(fileDescriptor, TCSANOW, &options) == 0
    }
}
