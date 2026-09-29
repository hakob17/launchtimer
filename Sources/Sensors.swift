import Foundation
import CoreMotion
import CoreLocation

/// Feeds the phone's motion sensors, GPS and barometer into a `LaunchEngine`, all on one
/// serial queue so the engine never sees two inputs at once.
final class Sensors: NSObject, CLLocationManagerDelegate {
    let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "launchtimer.sensors"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    /// Called on `queue` with each input.
    var onMotion: ((MotionSample) -> Void)?
    var onFix: ((SpeedFix) -> Void)?
    var onAltitude: ((AltitudeSample) -> Void)?
    /// Called on the main queue when location permission changes.
    var onAuthorization: ((CLAuthorizationStatus) -> Void)?

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let location = CLLocationManager()
    /// Whether CoreMotion's rotation matrix maps device → world as written, or transposed.
    /// Worked out from gravity on the first samples rather than trusted from documentation.
    private var transposed: Bool?
    private(set) var running = false

    var motionAvailable: Bool { motion.isDeviceMotionAvailable }

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .otherNavigation
        location.distanceFilter = kCLDistanceFilterNone
    }

    var authorization: CLAuthorizationStatus { location.authorizationStatus }

    func requestPermission() {
        location.requestWhenInUseAuthorization()
    }

    func start() {
        guard !running else { return }
        running = true
        location.startUpdatingLocation()

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.01
            // Arbitrary heading: the magnetometer is useless inside a car, and the engine
            // finds forward by itself.
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                self.handle(data)
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, _ in
                guard let self, let data else { return }
                self.onAltitude?(AltitudeSample(t: data.timestamp, metres: data.relativeAltitude.doubleValue))
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        location.stopUpdatingLocation()
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
    }

    private func handle(_ data: CMDeviceMotion) {
        let r = data.attitude.rotationMatrix
        func world(_ v: CMAcceleration, transposed: Bool) -> (Double, Double, Double) {
            transposed
                ? (r.m11 * v.x + r.m21 * v.y + r.m31 * v.z, r.m12 * v.x + r.m22 * v.y + r.m32 * v.z, r.m13 * v.x + r.m23 * v.y + r.m33 * v.z)
                : (r.m11 * v.x + r.m12 * v.y + r.m13 * v.z, r.m21 * v.x + r.m22 * v.y + r.m23 * v.z, r.m31 * v.x + r.m32 * v.y + r.m33 * v.z)
        }
        if transposed == nil {
            // Gravity must come out pointing straight down in the world frame.
            let g = data.gravity
            let a = world(g, transposed: true), b = world(g, transposed: false)
            transposed = abs(a.2) >= abs(b.2)
        }
        let (x, y, _) = world(data.userAcceleration, transposed: transposed!)
        onMotion?(MotionSample(t: data.timestamp, x: x, y: y))
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Location times are wall-clock; the motion samples use time since boot.
        let offset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        let fixes = locations.filter { $0.speed >= 0 }.map {
            SpeedFix(t: $0.timestamp.timeIntervalSince1970 - offset, speed: $0.speed, accuracy: $0.speedAccuracy)
        }
        queue.addOperation { [weak self] in fixes.forEach { self?.onFix?($0) } }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async { self.onAuthorization?(status) }
    }
}
