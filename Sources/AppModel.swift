import Foundation
import CoreLocation
import UIKit

/// What the dashboard shows, copied out of the engine for the main thread.
struct LiveState: Equatable {
    var phase: LaunchEngine.Phase = .calibrating
    var speed = 0.0
    var longG = 0.0
    var latG = 0.0
    var runTime: Double?
    var runDistance: Double?
    var liveSplits: [String: Double] = [:]
    var liveRollout: Double?
}

@MainActor
final class AppModel: ObservableObject {
    static let carPageURL = "hakob17.github.io/launchtimer/car"

    @Published private(set) var live = LiveState()
    /// Recent (longitudinal, lateral) g for the g-meter's trail, newest last.
    @Published private(set) var trail: [(Double, Double)] = []
    @Published private(set) var peakLong = 0.0
    @Published private(set) var peakLat = 0.0
    @Published private(set) var runs: [RunResult] = []
    /// The run just finished, shown big on the dashboard until the next one starts.
    @Published private(set) var latestRun: RunResult?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var carsWatching = 0
    @Published private(set) var pairCode: String
    @Published private(set) var demoRunning = false

    @Published var units: Units {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: "units"); pushRunsToCar() }
    }
    @Published var showRollout: Bool {
        didSet { UserDefaults.standard.set(showRollout, forKey: "rollout") }
    }
    @Published var acceptedSafety: Bool {
        didSet { UserDefaults.standard.set(acceptedSafety, forKey: "acceptedSafety") }
    }

    private let sensors = Sensors()
    private let link = CarLink()
    /// Only touched on `sensors.queue`.
    nonisolated(unsafe) private var engine = LaunchEngine()
    private let snapshotLock = NSLock()
    nonisolated(unsafe) private var snapshot = LiveState()
    private var ticker: Timer?
    private var tick = 0
    private var demoTimer: DispatchSourceTimer?

    init() {
        let defaults = UserDefaults.standard
        units = Units(rawValue: defaults.string(forKey: "units") ?? "")
            ?? (Locale.current.measurementSystem == .us || Locale.current.measurementSystem == .uk ? .imperial : .metric)
        showRollout = defaults.object(forKey: "rollout") as? Bool ?? true
        acceptedSafety = defaults.bool(forKey: "acceptedSafety")
        pairCode = PairCode.current
        authorization = sensors.authorization
        runs = RunStore.load()

        sensors.onAuthorization = { [weak self] status in self?.authorization = status }
        wire(engine)
        sensors.onMotion = { [weak self] sample in self?.engineAdd { $0.add(sample) } }
        sensors.onFix = { [weak self] fix in self?.engineAdd { $0.add(fix) } }
        sensors.onAltitude = { [weak self] altitude in self?.engineAdd { $0.add(altitude) } }

        link.onCars = { [weak self] count in
            guard let self else { return }
            let joined = count > self.carsWatching
            self.carsWatching = count
            if joined { self.pushRunsToCar() }
        }
        link.onHello = { [weak self] in self?.pushRunsToCar() }
        link.connect(room: pairCode)

        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Lifecycle

    func becameActive() {
        if authorization == .notDetermined { sensors.requestPermission() }
        if !demoRunning { sensors.start() }
        link.connect(room: pairCode)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func resignedActive() {
        guard !demoRunning else { return }
        sensors.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func requestLocation() {
        if authorization == .notDetermined {
            sensors.requestPermission()
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: Engine

    nonisolated private func engineAdd(_ body: (LaunchEngine) -> Void) {
        body(engine)
        let state = LiveState(phase: engine.phase, speed: engine.speed, longG: engine.longG, latG: engine.latG,
                              runTime: engine.runTime, runDistance: engine.runDistance, liveSplits: engine.liveSplits,
                              liveRollout: engine.liveRollout)
        snapshotLock.lock(); snapshot = state; snapshotLock.unlock()
    }

    nonisolated private func wire(_ engine: LaunchEngine) {
        engine.onRun = { [weak self] run in
            DispatchQueue.main.async { self?.finished(run) }
        }
    }

    private func finished(_ run: RunResult) {
        runs.insert(run, at: 0)
        latestRun = run
        RunStore.save(runs)
        pushRunsToCar()
    }

    func delete(_ run: RunResult) {
        runs.removeAll { $0.id == run.id }
        if latestRun?.id == run.id { latestRun = nil }
        RunStore.save(runs)
        pushRunsToCar()
    }

    private func refresh() {
        snapshotLock.lock(); let state = snapshot; snapshotLock.unlock()
        if state.phase == .running && live.phase != .running {
            latestRun = nil
            peakLong = 0; peakLat = 0
        }
        if state != live { live = state }
        trail.append((state.longG, state.latG))
        if trail.count > 40 { trail.removeFirst(trail.count - 40) }
        peakLong = max(peakLong, abs(state.longG))
        peakLat = max(peakLat, abs(state.latG))

        tick += 1
        if carsWatching > 0 && tick % 2 == 0 { pushLive(state) }
    }

    // MARK: Demo

    /// Plays a simulated drive through a fresh engine, in real time, instead of the sensors.
    func playDemo() {
        guard !demoRunning else { return }
        demoRunning = true
        sensors.stop()
        let demo = LaunchEngine()
        demo.source = "Demo"
        wire(demo)
        let player = DemoPlayer(events: DemoDrive.events())
        let queue = sensors.queue
        queue.addOperation { self.engine = demo }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: 0.01)
        timer.setEventHandler {
            queue.addOperation {
                for event in player.due() { self.feed(event) }
                if player.finished { DispatchQueue.main.async { self.endDemo() } }
            }
        }
        timer.resume()
        demoTimer = timer
    }

    nonisolated private func feed(_ event: DemoDrive.Event) {
        switch event {
        case .motion(let m): engineAdd { $0.add(m) }
        case .fix(let f): engineAdd { $0.add(f) }
        case .altitude(let a): engineAdd { $0.add(a) }
        }
    }

    func endDemo() {
        guard demoRunning else { return }
        demoTimer?.cancel()
        demoTimer = nil
        let fresh = LaunchEngine()
        wire(fresh)
        sensors.queue.addOperation { self.engine = fresh }
        demoRunning = false
        if UIApplication.shared.applicationState == .active { sensors.start() }
    }

    // MARK: Car screen

    func newPairCode() {
        pairCode = PairCode.renew()
        link.stop()
        link.connect(room: pairCode)
    }

    private func pushLive(_ state: LiveState) {
        var message: [String: Any] = [
            "type": "live", "phase": state.phase.rawValue, "v": round2(state.speed),
            "lon": round2(state.longG), "lat": round2(state.latG), "units": units.rawValue,
            "splits": displayedSplits(state).mapValues(round2),
            "peakLon": round2(peakLong), "peakLat": round2(peakLat), "demo": demoRunning,
        ]
        if let t = state.runTime { message["rt"] = round2(t) }
        if let d = state.runDistance { message["rd"] = round2(d) }
        link.sendLive(message)
    }

    /// Live split times as the user has chosen to see them (with or without rollout).
    func displayedSplits(_ state: LiveState) -> [String: Double] {
        guard showRollout, let rollout = state.liveRollout else { return state.liveSplits }
        return state.liveSplits.mapValues { max(0, $0 - rollout) }
    }

    private func pushRunsToCar() {
        guard carsWatching > 0 else { return }
        let recent = runs.prefix(12).map { CarFormat.run($0) }
        link.send(["type": "runs", "units": units.rawValue, "rollout": showRollout,
                   "latest": latestRun?.id.uuidString ?? "", "runs": Array(recent)])
    }
}

/// Hands out a demo's events as their time comes. Only used on the sensor queue.
private final class DemoPlayer: @unchecked Sendable {
    private let events: [DemoDrive.Event]
    private var index = 0
    private let start = ProcessInfo.processInfo.systemUptime

    init(events: [DemoDrive.Event]) { self.events = events }

    var finished: Bool { index >= events.count }

    func due() -> ArraySlice<DemoDrive.Event> {
        let now = ProcessInfo.processInfo.systemUptime - start
        let from = index
        while index < events.count && events[index].t <= now { index += 1 }
        return events[from..<index]
    }
}

private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

/// Runs in the shape the car page reads.
enum CarFormat {
    static func run(_ run: RunResult) -> [String: Any] {
        var out: [String: Any] = [
            "id": run.id.uuidString, "kind": run.kind.rawValue, "date": run.date.timeIntervalSince1970 * 1000,
            "maxSpeed": round2(run.maxSpeed), "peakG": round2(run.peakG), "distance": round2(run.distance),
            "source": run.source,
            "results": run.results.map { r -> [String: Any] in
                // Three decimals for times: they're the whole point.
                var item: [String: Any] = ["id": r.split.id, "label": r.split.label, "kind": r.split.kind.rawValue,
                                           "time": (r.time * 1000).rounded() / 1000]
                if let t = r.timeWithRollout { item["rollout"] = (t * 1000).rounded() / 1000 }
                if let v = r.finishSpeed { item["finishSpeed"] = round2(v) }
                if let d = r.distance { item["distance"] = round2(d) }
                return item
            },
            // Every other point is plenty for the chart on the car screen.
            "trace": stride(from: 0, to: run.trace.count, by: 2).map {
                [round2(run.trace[$0].t), round2(run.trace[$0].v), round2(run.trace[$0].a)]
            },
        ]
        if let grade = run.grade { out["grade"] = (grade * 1000).rounded() / 1000 }
        return out
    }
}

// MARK: - Storage

enum RunStore {
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("runs.json")
    }

    static func load() -> [RunResult] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RunResult].self, from: data)) ?? []
    }

    static func save(_ runs: [RunResult]) {
        let kept = Array(runs.prefix(500))
        if let data = try? JSONEncoder().encode(kept) { try? data.write(to: url, options: .atomic) }
    }
}

enum PairCode {
    /// 8 characters without look-alikes (no 0/O, 1/I/L), shown as XXXX-XXXX.
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let key = "pairCode"

    static var current: String {
        if let code = UserDefaults.standard.string(forKey: key), code.count == 8 { return code }
        return renew()
    }

    @discardableResult
    static func renew() -> String {
        var rng = SystemRandomNumberGenerator()
        let code = String((0..<8).map { _ in alphabet.randomElement(using: &rng)! })
        UserDefaults.standard.set(code, forKey: key)
        return code
    }

    static func formatted(_ code: String) -> String { "\(code.prefix(4))-\(code.suffix(4))" }
}
