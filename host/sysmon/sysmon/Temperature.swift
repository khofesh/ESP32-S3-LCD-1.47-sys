//
//  Temperature.swift
//  sysmon
//
//  Created by fahmi ahmad on 18/06/26.
//

import Foundation
import IOKit

// CPU temperature has no public macOS API, so this reads it through the
// private IOHIDEventSystem framework — the same source Apple's own tools use.
// On Apple Silicon the relevant sensors expose a processor-die temperature; on
// Intel Macs these HID sensors are usually absent, so reads return nil and the
// agent reports TMP:0. Because these symbols are private, they can change
// between macOS releases; treat unavailability as expected, not exceptional.

typealias IOHIDEventSystemClientRef = OpaquePointer
typealias IOHIDServiceClientRef = OpaquePointer
typealias IOHIDEventRef = OpaquePointer

// Sensor matching keys: Apple's vendor-defined HID usage page (0xff00) plus
// the temperature-sensor usage (0x05). temperatureEventType (15) is
// kIOHIDEventTypeTemperature, used both to request the event and to derive its
// value field.
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

    // Apple Silicon exposes many thermal sensors; the PMU "tdie" ones track
    // the processor die itself. Matching by name keeps us off GPU/battery/etc.
    var isProcessorDie: Bool {
        let normalizedName = name.lowercased()

        return normalizedName.hasPrefix("pmu") && normalizedName.contains("tdie")
    }
}

/// Holds an IOHIDEventSystem client and resolves the processor-die sensors
/// once, then averages their temperatures on demand.
private final class HIDTemperatureReader {
    private let client: IOHIDEventSystemClientRef
    // Resolved lazily and cached: the set of matching sensors doesn't change
    // over the process lifetime, so we only walk the service list once.
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
        // The client came from a "Create" call (+1 retain), so balance it
        // here. CF types reached via @_silgen_name aren't ARC-managed for us.
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
    
    /// Mean of the current processor-die readings, or nil if none are present
    /// or readable (e.g. on Intel Macs).
    func averageProcessorTemperature() -> Double? {
        let temperatures = processorServices.compactMap(temperature)

        guard !temperatures.isEmpty else {
            return nil
        }

        return temperatures.reduce(0, +) / Double(temperatures.count)
    }
}

/// Public-facing temperature source. Wraps the private HID reader and rounds
/// to whole degrees Celsius for the integer line protocol.
final class TemperatureReader {
    private let hidReader: HIDTemperatureReader?
    // Note: this performs a live sensor read, not a cheap flag check. The
    // agent only queries it once at startup, so the cost is immaterial.
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
