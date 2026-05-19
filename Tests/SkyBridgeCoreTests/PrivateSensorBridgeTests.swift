import XCTest
import PrivateSensorBridge

final class PrivateSensorBridgeTests: XCTestCase {
    func testTemperatureKeyClassificationDoesNotTreatMemoryAsCPU() {
        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("TC0P"), .cpu)
        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("Tp09"), .cpu)
        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("Te0S"), .cpu)
        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("Tf0P"), .cpu)

        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("TG0P"), .gpu)
        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("Tg1D"), .gpu)

        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("Tm0P"), .memory)
        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("TB0T"), .system)
        XCTAssertEqual(PrivateSensorBridge.classifyTemperatureKey("F0Ac"), .unknown)
    }

    func testHottestTemperatureIgnoresInvalidSensorValues() {
        let readings = [
            PrivateTemperatureReading(key: "TC0P", valueCelsius: 45, group: .cpu),
            PrivateTemperatureReading(key: "Tp09", valueCelsius: 62.5, group: .cpu),
            PrivateTemperatureReading(key: "Te0S", valueCelsius: 131, group: .cpu),
            PrivateTemperatureReading(key: "Tf0P", valueCelsius: .nan, group: .cpu)
        ]

        XCTAssertEqual(PrivateSensorBridge.hottestTemperature(readings), 62.5)
    }

    func testAverageTemperatureUsesOnlyValidReadings() {
        let readings = [
            PrivateTemperatureReading(key: "TC0P", valueCelsius: 45, group: .cpu),
            PrivateTemperatureReading(key: "Tp09", valueCelsius: 55, group: .cpu),
            PrivateTemperatureReading(key: "Te0S", valueCelsius: -11, group: .cpu)
        ]

        XCTAssertEqual(PrivateSensorBridge.averageTemperature(readings), 50)
        XCTAssertNil(PrivateSensorBridge.averageTemperature([]))
    }

    func testTemperatureReadingCarriesSource() {
        let smc = PrivateTemperatureReading(key: "TC0P", valueCelsius: 45, group: .cpu)
        let hid = PrivateTemperatureReading(key: "IOHID:CPU", valueCelsius: 44, group: .cpu, source: .iohid)

        XCTAssertEqual(smc.source, .smc)
        XCTAssertEqual(hid.source, .iohid)
    }

    func testFanReadingCarriesStableSMCKey() {
        let fan = PrivateFanReading(index: 0, key: "F0Ac", rpm: 2210)

        XCTAssertEqual(fan.index, 0)
        XCTAssertEqual(fan.key, "F0Ac")
        XCTAssertEqual(fan.rpm, 2210)
        XCTAssertEqual(fan.source, .smc)
    }

    func testPowerReadingCarriesComponentAndSource() {
        let readings = [
            PrivatePowerReading(component: .cpu, watts: 12.4),
            PrivatePowerReading(component: .gpu, watts: 8.7),
            PrivatePowerReading(component: .ane, watts: 0.9),
            PrivatePowerReading(component: .ram, watts: 1.6),
            PrivatePowerReading(component: .package, watts: 24.8)
        ]

        XCTAssertEqual(PrivateSensorBridge.powerValue(readings, component: .cpu), 12.4)
        XCTAssertEqual(PrivateSensorBridge.powerValue(readings, component: .gpu), 8.7)
        XCTAssertEqual(PrivateSensorBridge.powerValue(readings, component: .ane), 0.9)
        XCTAssertEqual(PrivateSensorBridge.powerValue(readings, component: .ram), 1.6)
        XCTAssertEqual(PrivateSensorBridge.powerValue(readings, component: .package), 24.8)
        XCTAssertNil(PrivateSensorBridge.powerValue([], component: .gpu))
        XCTAssertEqual(readings.first?.source, .ioreport)
    }
}
