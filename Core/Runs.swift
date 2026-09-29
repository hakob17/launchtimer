import Foundation

/// Standard gravity, for converting between g and m/s².
let standardGravity = 9.80665

enum Units: String, Codable, CaseIterable {
    case imperial, metric

    static let mph = 0.44704
    static let kmh = 1 / 3.6

    /// Metres per second → the unit shown to the user.
    func speed(_ metresPerSecond: Double) -> Double {
        metresPerSecond / (self == .imperial ? Units.mph : Units.kmh)
    }
    var speedLabel: String { self == .imperial ? "mph" : "km/h" }

    func distance(_ metres: Double) -> Double { self == .imperial ? metres / 0.3048 : metres }
    var distanceLabel: String { self == .imperial ? "ft" : "m" }
}

/// One measurement a run can produce: a speed range, a distance from a standstill, or a stop.
struct SplitDef: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case speed, distance, braking }
    let id: String
    let label: String
    let kind: Kind
    /// Speed ranges and braking: from/to in m/s. Distance: `to` is metres, `from` is 0.
    let from: Double
    let to: Double

    static func speed(_ from: Double, _ to: Double, _ unit: Double, _ suffix: String) -> SplitDef {
        SplitDef(id: "\(Int(from))-\(Int(to))\(suffix)", label: "\(Int(from))–\(Int(to)) \(suffix == "mph" ? "mph" : "km/h")",
                 kind: .speed, from: from * unit, to: to * unit)
    }

    /// Everything a run is measured against. Both unit systems are always measured, so a run
    /// can be shown either way later.
    static let all: [SplitDef] = [
        .speed(0, 30, Units.mph, "mph"), .speed(0, 60, Units.mph, "mph"), .speed(0, 100, Units.mph, "mph"),
        .speed(0, 130, Units.mph, "mph"), .speed(60, 130, Units.mph, "mph"),
        SplitDef(id: "eighth", label: "⅛ mile", kind: .distance, from: 0, to: 201.168),
        SplitDef(id: "quarter", label: "¼ mile", kind: .distance, from: 0, to: 402.336),
        SplitDef(id: "60-0mph", label: "60–0 mph", kind: .braking, from: 60 * Units.mph, to: 0),
        .speed(0, 50, Units.kmh, "kmh"), .speed(0, 100, Units.kmh, "kmh"), .speed(0, 150, Units.kmh, "kmh"),
        .speed(0, 200, Units.kmh, "kmh"), .speed(100, 200, Units.kmh, "kmh"),
        SplitDef(id: "201m", label: "201 m", kind: .distance, from: 0, to: 201),
        SplitDef(id: "402m", label: "402 m", kind: .distance, from: 0, to: 402),
        SplitDef(id: "100-0kmh", label: "100–0 km/h", kind: .braking, from: 100 * Units.kmh, to: 0),
    ]

    static let imperialIDs: Set<String> = ["0-30mph", "0-60mph", "0-100mph", "0-130mph", "60-130mph", "eighth", "quarter", "60-0mph"]
    static let metricIDs: Set<String> = ["0-50kmh", "0-100kmh", "0-150kmh", "0-200kmh", "100-200kmh", "201m", "402m", "100-0kmh"]

    static func shown(in units: Units) -> [SplitDef] {
        let ids = units == .imperial ? imperialIDs : metricIDs
        return all.filter { ids.contains($0.id) }
    }
}

struct SplitResult: Codable, Hashable, Identifiable {
    var id: String { split.id }
    let split: SplitDef
    /// Seconds. For launches from a standstill this counts from the first movement.
    let time: Double
    /// Seconds after the car rolled one foot, the drag-strip convention most magazines and
    /// makers quote. Only for splits that start from a standstill.
    let timeWithRollout: Double?
    /// Speed crossing the line, m/s (distance splits).
    let finishSpeed: Double?
    /// Metres (braking).
    let distance: Double?
}

struct TracePoint: Codable, Hashable {
    /// Seconds since the run started.
    let t: Double
    /// m/s
    let v: Double
    /// Longitudinal acceleration, g.
    let a: Double
}

struct RunResult: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case launch, rolling, braking }
    var id = UUID()
    var date = Date()
    let kind: Kind
    let results: [SplitResult]
    let maxSpeed: Double
    let peakG: Double
    let distance: Double
    let duration: Double
    /// Metres climbed from start to end (barometer), when available. Downhill runs are faster
    /// than flat ones, so a big number here makes the run hard to compare.
    let elevationChange: Double?
    let trace: [TracePoint]
    let source: String

    var grade: Double? {
        guard let elevationChange, distance > 50 else { return nil }
        return elevationChange / distance
    }

    func result(_ id: String) -> SplitResult? { results.first { $0.split.id == id } }

    /// The one number to headline this run with.
    func headline(for units: Units) -> SplitResult? {
        let order = units == .imperial
            ? ["0-60mph", "60-130mph", "quarter", "0-30mph", "60-0mph"]
            : ["0-100kmh", "100-200kmh", "402m", "0-50kmh", "100-0kmh"]
        return order.lazy.compactMap { result($0) }.first
    }
}
