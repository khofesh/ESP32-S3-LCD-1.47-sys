//
//  main.swift
//  sysmon
//
//  Created by fahmi ahmad on 17/06/26.
//

import Foundation
import Darwin

struct StatsSample {
    let cpu: Int
    let memory: Int
    let temperature: Int
    let rx: Int
    let tx: Int
    
    func protocolLine() -> String {
        "CPU:\(cpu),MEM:\(memory),TMP:\(temperature),RX:\(rx),TX:\(tx)"
    }
}

struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
    
    var total: UInt64 {
        user + system + idle + nice
    }
}

var previousCPUTicks: CPUTicks?

func readCPUTicks() -> CPUTicks? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    
    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
        infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPointer, &count)
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

@MainActor
func cpuPercent() -> Int {
    guard let current = readCPUTicks() else {
        return 0
    }
    
    guard let previous = previousCPUTicks else {
        previousCPUTicks = current
        return 0
    }
    
    let totalDelta = current.total - previous.total
    let idleDelta = current.idle - previous.idle
    previousCPUTicks = current
    
    guard totalDelta > 0 else {
        return 0
    }
    
    let usedDelta = totalDelta - idleDelta
    return Int((Double(usedDelta) / Double(totalDelta)) * 100)
}

struct NetworkBytes {
    let rx: UInt64
    let tx: UInt64
}

var previousNetworkBytes: NetworkBytes?

func readNetworkBytes() -> NetworkBytes {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    
    guard getifaddrs(&interfaces) == 0 else {
        return NetworkBytes(rx: 0, tx: 0)
    }
    
    var pointer = interfaces
    while pointer != nil {
        let interface = pointer!.pointee
        let address = interface.ifa_addr.pointee
        
        if address.sa_family == UInt8(AF_LINK),
           let data = interface.ifa_data {
            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(networkData.ifi_ibytes)
            tx += UInt64(networkData.ifi_obytes)
        }
        pointer = interface.ifa_next
    }
    
    freeifaddrs(interfaces)
    
    return NetworkBytes(rx: rx, tx: tx)
}

@MainActor
func networkThroughput() -> (rx: Int, tx: Int) {
    let current = readNetworkBytes()
    
    guard let previous = previousNetworkBytes else {
        previousNetworkBytes = current
        return (rx: 0, tx: 0)
    }
    
    previousNetworkBytes = current
    
    let rxDelta = current.rx >= previous.rx ? current.rx - previous.rx : 0
    let txDelta = current.tx >= previous.tx ? current.tx - previous.tx : 0
    
    return (Int(rxDelta / 1024), Int(txDelta / 1024))
}

func memoryPercent() -> Int {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    
    let result = withUnsafeMutablePointer(to: &stats) { statsPointer in
        statsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
        }
    }
    
    guard result == KERN_SUCCESS else { return 0 }
    
    var pageSizeValue = vm_size_t()
    host_page_size(mach_host_self(), &pageSizeValue)
    let pageSize = UInt64(pageSizeValue)
    let active = UInt64(stats.active_count) * pageSize
    
    let wired = UInt64(stats.wire_count) * pageSize
    let compressed = UInt64(stats.compressor_page_count) * pageSize
    let used = active + wired + compressed
    let total = ProcessInfo.processInfo.physicalMemory

    return Int((Double(used) / Double(total)) * 100)
}

func findSerialPort() -> String? {
    let devPath = "/dev"
    
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: devPath) else { return nil }
    
    let candidates = entries.filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.SLAB_USBtoUART") }
        .sorted()
    
    guard let first = candidates.first else { return nil }
    
    return "\(devPath)/\(first)"
}

func writeLine(_ line: String, to fileHandle: FileHandle) -> Bool {
    guard let data = "\(line)\n".data(using: .utf8) else {
        return false
    }

    let written: Int = data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return -1
        }

        return Darwin.write(fileHandle.fileDescriptor, baseAddress, data.count)
    }

    return written == data.count
}

func configureSerialPort(_ fileHandle: FileHandle) -> Bool {
    let fd = fileHandle.fileDescriptor
    var options = termios()
    
    guard tcgetattr(fd, &options) == 0 else {
        return false
    }
    
    cfmakeraw(&options)
    cfsetspeed(&options, speed_t(B115200))
    
    options.c_cflag |= tcflag_t(CLOCAL | CREAD)
    options.c_cflag &= ~tcflag_t(CSTOPB)
    options.c_cflag &= ~tcflag_t(PARENB)
    options.c_cflag &= ~tcflag_t(CSIZE)
    options.c_cflag |= tcflag_t(CS8)
    
    return tcsetattr(fd, TCSANOW, &options) == 0
}

func openSerialPort() -> FileHandle? {
    guard let port = findSerialPort() else {
        print("serial port not found")
        return nil
    }

    guard let serial = FileHandle(forWritingAtPath: port) else {
        print("could not open serial port: \(port)")
        return nil
    }

    guard configureSerialPort(serial) else {
        print("could not configure serial port: \(port)")
        return nil
    }

    print("found serial port: \(port)")
    return serial
}

@MainActor
func readStatsSample() -> StatsSample {
    let net = networkThroughput()
    
    return StatsSample(
        cpu: cpuPercent(),
        memory: memoryPercent(),
        temperature: 58,
        rx: net.rx,
        tx: net.tx
    )
}

@MainActor
func streamSamples(to serial: FileHandle, count: Int) {
    for _ in 1...count {
        let sample = readStatsSample()
        let line = sample.protocolLine()

        print(line)
        writeLine(line, to: serial)

        Thread.sleep(forTimeInterval: 1.0)
    }
}

guard let serial = openSerialPort() else {
    exit(1)
}

streamSamples(to: serial, count: 10)
