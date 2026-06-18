import Darwin
import Foundation

@MainActor
final class SystemSampler {
    private var previousCPUTicks: CPUTicks?
    private var previousNetworkBytes: NetworkBytes?
    private let temperatureReader = TemperatureReader()

    var temperatureAvailable: Bool {
        temperatureReader.isAvailable
    }

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

private func readCPUTicks() -> CPUTicks? {
    var info = host_cpu_load_info()
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
