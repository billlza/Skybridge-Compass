import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()
print("Metal device: \(device?.name ?? "None")")

guard let device = device else {
    print("❌ Metal device not available")
    exit(1)
}

let library = device.makeDefaultLibrary()
print("Default library: \(library != nil)")

guard let library = library else {
    print("❌ Default Metal library not available")
    exit(1)
}

let hazeVertex = library.makeFunction(name: "hazeVertex")
print("hazeVertex function: \(hazeVertex != nil)")

let hazeFragment = library.makeFunction(name: "hazeFragment")
print("hazeFragment function: \(hazeFragment != nil)")

if hazeVertex != nil && hazeFragment != nil {
    print("✅ All Metal components are available")
} else {
    print("❌ Some Metal components are missing")
}