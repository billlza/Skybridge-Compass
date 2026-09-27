// I/O boundary for the macOS-hosted lifecycle test only. The script separately
// typechecks WeatherManager against the real iOS SDK before running this harness.
import Foundation

public enum CLAuthorizationStatus: Sendable { case notDetermined, restricted, denied, authorizedAlways, authorizedWhenInUse }
public let kCLLocationAccuracyKilometer: Double = 1000
public protocol CLLocationManagerDelegate: AnyObject {}
open class CLLocationManager: NSObject {
    public weak var delegate: (any CLLocationManagerDelegate)?
    public var desiredAccuracy: Double = 0
    open var authorizationStatus: CLAuthorizationStatus { .notDetermined }
    open func requestLocation() {}
    open func stopUpdatingLocation() {}
    open func requestWhenInUseAuthorization() {}
}
public struct CLLocationCoordinate2D: Sendable { public let latitude: Double; public let longitude: Double }
public final class CLLocation: Sendable { public let coordinate: CLLocationCoordinate2D; public init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate } }
public struct CLPlacemark: Sendable { public let locality: String?; public let administrativeArea: String? }
public final class CLGeocoder {
    public init() {}
    public func reverseGeocodeLocation(_ location: CLLocation) async throws -> [CLPlacemark] { [] }
}
public struct CLError: Error { public enum Code: Sendable { case denied }; public let code: Code }
