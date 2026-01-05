//
// MenuBarIconStateTests.swift
// SkyBridgeCoreTests
//
// Property-Based Tests for MenuBarIconState
// **Feature: menubar-app, Property 4: Icon State Reflects Transfer State**
// **Validates: Requirements 4.1, 4.2**
//

import Testing
import Foundation
@testable import SkyBridgeUI

@Suite("MenuBarIconState Property Tests")
struct MenuBarIconStateTests {
    
 // MARK: - Property 4: Icon State Reflects Transfer State
    
 /// **Feature: menubar-app, Property 4: Icon State Reflects Transfer State**
 /// *For any* active file transfer, the menu bar icon state SHALL be `.transferring(progress:)`
 /// with progress matching the actual transfer progress.
 /// **Validates: Requirements 4.1, 4.2**
    @Test("Property 4: Icon state reflects transfer progress", arguments: [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0])
    func iconStateReflectsTransferProgress(progress: Double) {
        let state = MenuBarIconState.transferring(progress: progress)
        
 // Verify progress is accessible
        #expect(state.progress != nil)
        #expect(state.progress! >= 0.0)
        #expect(state.progress! <= 1.0)
        
 // Verify progress matches input
        #expect(abs(state.progress! - progress) < 0.001)
        
 // Verify state is active
        #expect(state.isActive == true)
    }
    
 /// **Feature: menubar-app, Property 4: Icon State Reflects Transfer State**
 /// Normal state should have no progress
    @Test("Normal state has no progress")
    func normalStateHasNoProgress() {
        let state = MenuBarIconState.normal
        #expect(state.progress == nil)
        #expect(state.isActive == false)
    }
    
 /// **Feature: menubar-app, Property 4: Icon State Reflects Transfer State**
 /// Error state should have no progress
    @Test("Error state has no progress")
    func errorStateHasNoProgress() {
        let state = MenuBarIconState.error
        #expect(state.progress == nil)
        #expect(state.isActive == false)
    }
    
 /// **Feature: menubar-app, Property 4: Icon State Reflects Transfer State**
 /// Scanning state should be active but have no progress
    @Test("Scanning state is active without progress")
    func scanningStateIsActiveWithoutProgress() {
        let state = MenuBarIconState.scanning
        #expect(state.progress == nil)
        #expect(state.isActive == true)
    }
    
 // MARK: - MenuBarTransferItem Tests
    
 /// Test transfer item progress formatting
    @Test("Transfer item formats progress correctly", arguments: [
        (0.0, "0%"),
        (0.5, "50%"),
        (1.0, "100%"),
        (0.333, "33%")
    ])
    func transferItemFormatsProgress(progress: Double, expected: String) {
        let item = MenuBarTransferItem(
            id: "test",
            fileName: "test.txt",
            progress: progress,
            speed: 1000,
            state: .transferring
        )
        #expect(item.formattedProgress == expected)
    }
    
 /// Test transfer item speed formatting
    @Test("Transfer item formats speed correctly", arguments: [
        (500.0, "500 B/s"),
        (1500.0, "1.5 KB/s"),
        (1_500_000.0, "1.5 MB/s"),
        (1_500_000_000.0, "1.5 GB/s")
    ])
    func transferItemFormatsSpeed(speed: Double, expected: String) {
        let item = MenuBarTransferItem(
            id: "test",
            fileName: "test.txt",
            progress: 0.5,
            speed: speed,
            state: .transferring
        )
        #expect(item.formattedSpeed == expected)
    }
    
 // MARK: - MenuBarConfiguration Tests
    
 /// Test default configuration values
    @Test("Default configuration has expected values")
    func defaultConfigurationValues() {
        let config = MenuBarConfiguration.default
        #expect(config.enabled == true)
        #expect(config.popoverWidth == 320)
        #expect(config.popoverHeight == 400)
        #expect(config.maxDevicesShown == 5)
        #expect(config.showTransferProgress == true)
    }
    
 /// Test configuration Codable round-trip
    @Test("Configuration survives Codable round-trip")
    func configurationCodableRoundTrip() throws {
        let original = MenuBarConfiguration(
            enabled: false,
            popoverWidth: 400,
            popoverHeight: 500,
            maxDevicesShown: 10,
            showTransferProgress: false
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MenuBarConfiguration.self, from: data)
        
        #expect(decoded == original)
    }
}
