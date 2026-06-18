//
//  Temperature.swift
//  sysmon
//
//  Created by fahmi ahmad on 18/06/26.
//

import Foundation
import IOKit

typealias IOHIDEventSystemClientRef = OpaquePointer
typealias IOHIDServiceClientRef = OpaquePointer
typealias IOHIDEventRef = OpaquePointer

private let appleVendorUsagePage: Int32 = 0xff00
private let temperatureSensorUsage: Int32 = 0x0005
private let temperatureEventType: Int64 = 15

@_silgen_name("IOHIDEventSystemClientCreate")
private func createHIDEventSystemClient(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func setHIDEventSystemMatching(
    _ client: IOHIDEventSystemClientRef,
    _ matching: CFDictionary
) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func copyHIDEventSystemServices(
    _ client: IOHIDEventSystemClientRef
) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func copyHIDServiceProperty(
    _ service: IOHIDServiceClientRef,
    _ key: CFString
) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func copyHIDServiceEvent(
    _ service: IOHIDServiceClientRef,
    _ eventType: Int64,
    _ options: Int32,
    _ timestamp: Int64
) -> IOHIDEventRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func hidEventFloatValue(
    _ event: IOHIDEventRef,
    _ field: Int32
) -> Double

private func temperatureSensorMatching() -> CFDictionary {
    [
        "PrimaryUsagePage": NSNumber(
            value: appleVendorUsagePage
        ),
        "PrimaryUsage": NSNumber(
            value: temperatureSensorUsage
        )
    ] as CFDictionary
}

private struct TemperatureReading {
    let name: String
    let celsius: Double
    
    var isProcessorDie: Bool {
        let normalizedName = name.lowercased()
        
        return normalizedName.hasPrefix("pmu") || normalizedName.contains("tdie")
    }
}

private final class HIDTemperatureReader {
    private let client: IOHIDEventSystemClientRef
    
    init?() {
        guard let client = createHIDEventSystemClient(nil) else {
            return nil
        }
        
        self.client = client
        _ = setHIDEventSystemMatching(client, temperatureSensorMatching()
        )
    }
    
    func sensorServices() -> [IOHIDServiceClientRef] {
        guard let services = copyHIDEventSystemServices(client) else {
            return []
        }

        let count = CFArrayGetCount(services)
        var result: [IOHIDServiceClientRef] = []

        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(
                services,
                index
            ) else {
                continue
            }

            result.append(OpaquePointer(pointer))
        }

        return result
    }
    
    func sensorName(for service: IOHIDServiceClientRef) -> String? {
        guard let property = copyHIDServiceProperty(service, "Product" as CFString) else {
            return nil
        }
        
        return property as? String
    }
    
    func temperature(for service: IOHIDServiceClientRef) -> Double? {
        guard let event = copyHIDServiceEvent(
            service,
            temperatureEventType,
            0,
            0
            ) else {
            return nil
        }
        
        // defer releases the copied macOS event when the function exits
        defer {
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
        }
        
        // << 16 creates the HID field identifier for the temperature value
        let temperatureField = Int32(
            temperatureEventType << 16
        )
        let value = hidEventFloatValue(event, temperatureField)
        
        guard value.isFinite,
              value > 0,
              value < 150 else {
            return nil
        }
        
        return value
    }
    
    func readings() -> [TemperatureReading] {
        var result: [TemperatureReading] = []
        
        for service in sensorServices() {
            guard let name = sensorName(for: service),
                  let celsius = temperature(for: service) else {
                continue
            }
            
            result.append(
                TemperatureReading(
                    name: name,
                    celsius: celsius
                )
            )
        }
        
        return result
    }
    
    func printReadings() {
        let currentReadings = readings().filter(\.isProcessorDie)
        
        if currentReadings.isEmpty {
            print("No HID temperature sensors found")
            return
        }
        
        for reading in currentReadings {
            print(
                "\(reading.name): " +
                String(format: "%.1f°C", reading.celsius)
            )
        }
    }
}

@MainActor
func printDebugHIDReadings() {
    let reader = HIDTemperatureReader()
    reader?.printReadings()
}

private func findSMCService() -> io_service_t? {
    var iterator: io_iterator_t = 0
    
    guard let matching = IOServiceMatching("AppleSMC"),
          IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
          ) == KERN_SUCCESS else {
        return nil
    }
    
    defer {
        IOObjectRelease(iterator)
    }
    
    let service = IOIteratorNext(iterator)
    
    return service == 0 ? nil : service
}

private func openSMCConnection() -> io_connect_t? {
    guard let service = findSMCService() else {
        return nil
    }
    
    defer {
        IOObjectRelease(service)
    }
    
    var connection: io_connect_t = 0
    let result = IOServiceOpen(
        service,
        mach_task_self_,
        0,
        &connection
    )
    
    return result == KERN_SUCCESS ? connection : nil
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpu: UInt32 = 0
    var gpu: UInt32 = 0
    var memory: UInt32 = 0
}

private struct SMCKeyInfo {
    // how many sensor bytes are valid
    var dataSize: UInt32 = 0
    // identifies the encoding, such as "flt "
    var dataType: UInt32 = 0
    // contains SMC flags
    var attributes: UInt8 = 0
    
    var reserved1: UInt8 = 0
    var reserved2: UInt8 = 0
    var reserved3: UInt8 = 0
}

// SMC expects exactly 32 bytes embedded directly in its request structure
private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8
)

private func emptySMCBytes() -> SMCBytes {
    (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimit = SMCPowerLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data: UInt32 = 0
    var bytes: SMCBytes = emptySMCBytes()
}

private func smcKeyCode(_ key: String) -> UInt32? {
    let bytes = Array(key.utf8)
    
    guard bytes.count == 4 else {
        return nil
    }
    
    return bytes.reduce(UInt32(0)) { result, byte in
        (result << 8) | UInt32(byte)
    }
}

private final class SMCConnection {
    let handle: io_connect_t
    
    init?() {
        guard let connection = openSMCConnection() else {
            return nil
        }
        
        handle = connection
    }
    
    func call(_ request: SMCKeyData) -> SMCKeyData? {
        var input = request
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        
        let result = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    handle,
                    2,
                    inputPointer,
                    MemoryLayout<SMCKeyData>.size,
                    outputPointer,
                    &outputSize
                )
            }
            
        }
        
        guard result == KERN_SUCCESS, output.result == 0 else {
            return nil
        }
        
        return output
    }
    
    func keyInfo(for key: String) -> SMCKeyInfo? {
        guard let keyCode = smcKeyCode(key) else {
            return nil
        }
        
        var request = SMCKeyData()
        request.key = keyCode
        // command 9 asks the SMC for key metadata
        request.command = 9
        
        guard let response = call(request) else {
            return nil
        }
        
        return response.keyInfo
    }
    
    func readValue(for key: String) -> SMCKeyData? {
        guard let keyCode = smcKeyCode(key),
              let info = keyInfo(for: key) else {
            return nil
        }
        
        var request = SMCKeyData()
        request.key = keyCode
        request.keyInfo = info
        // command 5 requests the key's value
        request.command = 5
        
        return call(request)
    }
    
    deinit {
        IOServiceClose(handle)
    }
}

final class TemperatureReader {
    private let smcConnection: SMCConnection?
    
    init() {
        smcConnection = SMCConnection()
    }
    
    func cpuTemperatureCelsius() -> Int? {
        guard smcConnection != nil else {
            return nil
        }
        
        return nil
    }
}
