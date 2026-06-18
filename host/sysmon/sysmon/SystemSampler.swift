// Reads live CPU, memory, temperature, and network stats from the kernel and
// folds them into a StatsSample. Holds the previous CPU/network counters so
// rates can be computed as deltas between consecutive samples.
import Darwin
import Foundation

@MainActor
final class SystemSampler {
    // Baselines for the rate calculations; nil until the first sample primes
    // them (or after resetBaselines on reconnect).
    private var previousCPUTicks: CPUTicks?
    private var previousNetworkBytes: NetworkBytes?
    private let temperatureReader = TemperatureReader()

    var temperatureAvailable: Bool {
        temperatureReader.isAvailable
    }

    /// Clears the rate baselines so the next sample reports 0 instead of a
    /// delta spanning a disconnect. Called on every (re)connect.
    func resetBaselines() {
        previousCPUTicks = nil
        previousNetworkBytes = nil
    }

    func sample() -> StatsSample {
        let network = networkThroughput()

        return StatsSample(
            cpu: cpuPercent(),
            memory: memoryPercent(),
            temperature: temperatureReader.cpuTemperatureCelsius() ?? 0,
            rx: network.rx,
            tx: network.tx
        )
    }

    private func cpuPercent() -> Int {
        guard let current = readCPUTicks() else {
            return 0
        }

        // Always store the new snapshot as the next baseline, even on the
        // first call where we have nothing to diff against yet.
        defer {
            previousCPUTicks = current
        }

        guard let previous = previousCPUTicks else {
            return 0
        }

        return cpuUsagePercent(previous: previous, current: current)
    }

    private func networkThroughput() -> NetworkRate {
        let current = readNetworkBytes()

        defer {
            previousNetworkBytes = current
        }

        guard let previous = previousNetworkBytes else {
            return NetworkRate(rx: 0, tx: 0)
        }

        return networkRate(previous: previous, current: current)
    }
}

/// Reads aggregate (all-core) CPU tick counters via the Mach host_statistics
/// API. Returns nil if the kernel call fails.
private func readCPUTicks() -> CPUTicks? {
    var info = host_cpu_load_info()
    // host_statistics wants the buffer size measured in integer_t units, so
    // express the struct's size as a count of integer_t fields.
    var count = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info>.stride /
        MemoryLayout<integer_t>.stride
    )

    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
        infoPointer.withMemoryRebound(
            to: integer_t.self,
            capacity: Int(count)
        ) { intPointer in
            host_statistics(
                mach_host_self(),
                HOST_CPU_LOAD_INFO,
                intPointer,
                &count
            )
        }
    }

    guard result == KERN_SUCCESS else {
        return nil
    }

    return CPUTicks(
        user: UInt64(info.cpu_ticks.0),
        system: UInt64(info.cpu_ticks.1),
        idle: UInt64(info.cpu_ticks.2),
        nice: UInt64(info.cpu_ticks.3)
    )
}

/// Sums RX/TX byte counters across all non-loopback link-layer interfaces.
/// Uses systemUptime (a monotonic clock) so rate math is immune to wall-clock
/// adjustments.
private func readNetworkBytes() -> NetworkBytes {
    let sampledAt = ProcessInfo.processInfo.systemUptime
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    var rx: UInt64 = 0
    var tx: UInt64 = 0

    guard getifaddrs(&interfaces) == 0 else {
        return NetworkBytes(rx: 0, tx: 0, sampledAt: sampledAt)
    }

    defer {
        freeifaddrs(interfaces)
    }

    var pointer = interfaces

    while let current = pointer {
        let interface = current.pointee
        pointer = interface.ifa_next

        // Only AF_LINK entries carry if_data byte counters; skip loopback so
        // local traffic doesn't inflate the throughput shown on the board.
        guard let address = interface.ifa_addr,
              address.pointee.sa_family == UInt8(AF_LINK),
              interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
              let data = interface.ifa_data else {
            continue
        }

        let networkData = data
            .assumingMemoryBound(to: if_data.self)
            .pointee

        rx = rx &+ UInt64(networkData.ifi_ibytes)
        tx = tx &+ UInt64(networkData.ifi_obytes)
    }

    return NetworkBytes(rx: rx, tx: tx, sampledAt: sampledAt)
}

/// Memory usage as a 0–100 percent of physical RAM.
///
/// "Used" is defined as active + wired + compressed pages — roughly what
/// Activity Monitor shows as in-use memory. Inactive/cached pages are treated
/// as available. This leans slightly high since active includes cached file
/// pages, which is acceptable for a glanceable gauge.
private func memoryPercent() -> Int {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.stride /
        MemoryLayout<integer_t>.stride
    )

    let result = withUnsafeMutablePointer(to: &stats) { statsPointer in
        statsPointer.withMemoryRebound(
            to: integer_t.self,
            capacity: Int(count)
        ) { intPointer in
            host_statistics64(
                mach_host_self(),
                HOST_VM_INFO64,
                intPointer,
                &count
            )
        }
    }

    guard result == KERN_SUCCESS else {
        return 0
    }

    var pageSizeValue = vm_size_t()
    host_page_size(mach_host_self(), &pageSizeValue)

    let pageSize = UInt64(pageSizeValue)
    let active = UInt64(stats.active_count) * pageSize
    let wired = UInt64(stats.wire_count) * pageSize
    let compressed = UInt64(stats.compressor_page_count) * pageSize
    let used = active &+ wired &+ compressed
    let total = ProcessInfo.processInfo.physicalMemory

    guard total > 0 else {
        return 0
    }

    return Int(
        (Double(used) / Double(total) * 100)
            .rounded()
            .clamped(to: 0...100)
    )
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
