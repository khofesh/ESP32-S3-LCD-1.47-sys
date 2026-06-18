//
//  Temperature.swift
//  sysmon
//
//  Created by fahmi ahmad on 18/06/26.
//

import Foundation
import IOKit.hid

final class TemperatureReader {
    private let hidManager: IOHIDManager
    private let isOpen: Bool
    
    init() {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        
        IOHIDManagerSetDeviceMatching(manager, nil)
        
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        
        hidManager = manager
        isOpen = result == kIOReturnSuccess
        
    }
    
    func cpuTemperatureCelsius() -> Int? {
        guard isOpen else {
            return nil
        }
        
        return nil
    }
}

