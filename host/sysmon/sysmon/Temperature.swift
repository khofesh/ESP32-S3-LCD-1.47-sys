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
        
        return normalizedName.hasPrefix("pmu") && normalizedName.contains("tdie")
    }
}

private final class HIDTemperatureReader {
    private let client: IOHIDEventSystemClientRef
    private lazy var services = copyHIDEventSystemServices(client)
    private lazy var processorServices = sensorServices().filter {
        guard let name = sensorName(for: $0) else {
            return false
        }

        return TemperatureReading(name: name, celsius: 0).isProcessorDie
    }
    
    init?() {
        guard let client = createHIDEventSystemClient(nil) else {
            return nil
        }
        
        self.client = client
        _ = setHIDEventSystemMatching(client, temperatureSensorMatching()
        )
    }
    
    deinit {
        Unmanaged<AnyObject>
            .fromOpaque(UnsafeRawPointer(client))
            .release()
    }
    
    private func sensorServices() -> [IOHIDServiceClientRef] {
        guard let services else {
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
    
    private func sensorName(for service: IOHIDServiceClientRef) -> String? {
        guard let property = copyHIDServiceProperty(service, "Product" as CFString) else {
            return nil
        }
        
        return property as? String
    }
    
    private func temperature(for service: IOHIDServiceClientRef) -> Double? {
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
    
    func averageProcessorTemperature() -> Double? {
        let temperatures = processorServices.compactMap(temperature)

        guard !temperatures.isEmpty else {
            return nil
        }

        return temperatures.reduce(0, +) / Double(temperatures.count)
    }
}

final class TemperatureReader {
    private let hidReader: HIDTemperatureReader?
    var isAvailable: Bool {
        cpuTemperatureCelsius() != nil
    }
    
    init() {
        hidReader = HIDTemperatureReader()
    }
    
    func cpuTemperatureCelsius() -> Int? {
        guard let temperature =
                hidReader?.averageProcessorTemperature() else {
            return nil
        }

        return Int(temperature.rounded())
    }
}
