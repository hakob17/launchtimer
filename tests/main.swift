import Foundation

// Drives LaunchEngine with simulated drives and compares its times with the true ones.
//
//   swiftc -O Core/*.swift tests/main.swift -o build/engine-test && build/engine-test
//
// The phone sits in the car at a random angle, with accelerometer bias, noise and engine
// vibration; GPS reports a noisy, slightly late speed once a second at a random phase.

struct Rng {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double {
        let u = max(next(), 1e-12), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// A drive as longitudinal and lateral acceleration (g) over time.
struct Drive {
    var name: String
    /// Returns (longitudinal g, lateral g) for time t and current speed v (m/s).
    var profile: (Double, Double) -> (Double, Double)
    var duration: Double
}

struct Truth {
    var times: [Double] = []
    var speeds: [Double] = []
    var distances: [Double] = []
}

func simulate(_ drive: Drive, seed: UInt64, latency: Double, vibration: Double) -> ([RunResult], Truth) {
    var rng = Rng(state: seed)
    let engine = LaunchEngine()
    var runs: [RunResult] = []
    engine.onRun = { runs.append($0) }

    let yaw = rng.next() * 2 * .pi
    let bias = (x: rng.gauss() * 0.01, y: rng.gauss() * 0.01)
    let dt = 0.001
    var v = 0.0, d = 0.0, t = 0.0
    var truth = Truth()
    var nextSample = 0.0
    var nextFix = rng.next()
    var nextAltitude = 0.0
    while t < drive.duration {
        var (lon, lat) = drive.profile(t, v)
        if v <= 0 && lon < 0 { lon = 0 }
        v = max(0, v + lon * standardGravity * dt)
        d += v * dt
        t += dt
        truth.times.append(t); truth.speeds.append(v); truth.distances.append(d)

        if t >= nextSample {
            nextSample += 0.01
            let vib = vibration * sin(2 * .pi * 31 * t)
            let noisyLon = lon + rng.gauss() * 0.012 + vib
            let noisyLat = lat + rng.gauss() * 0.012 + vib * 0.5
            let x = noisyLon * cos(yaw) - noisyLat * sin(yaw) + bias.x
            let y = noisyLon * sin(yaw) + noisyLat * cos(yaw) + bias.y
            engine.add(MotionSample(t: t, x: x, y: y))
        }
        if t >= nextFix {
            nextFix += 1
            let lagged = interpolate(times: truth.times, values: truth.speeds, at: t - latency)
            engine.add(SpeedFix(t: t, speed: max(0, lagged + rng.gauss() * 0.15), accuracy: 0.3))
        }
        if t >= nextAltitude {
            nextAltitude += 0.1
            engine.add(AltitudeSample(t: t, metres: 100 + rng.gauss() * 0.1))
        }
    }
    return (runs, truth)
}

func trueSplit(_ split: SplitDef, truth: Truth, launchAt t0: Double) -> Double? {
    // Only what the car reached before the driver lifted counts.
    let lift = truth.speeds.indices.first { $0 > 0 && truth.speeds[$0] < truth.speeds[$0 - 1] } ?? truth.speeds.count
    let truth = Truth(times: Array(truth.times[..<lift]), speeds: Array(truth.speeds[..<lift]),
                      distances: Array(truth.distances[..<lift]))
    switch split.kind {
    case .speed where split.from == 0:
        return crossing(of: split.to, in: truth.speeds, times: truth.times).map { $0 - t0 }
    case .speed:
        guard let a = crossing(of: split.from, in: truth.speeds, times: truth.times),
              let b = crossing(of: split.to, in: truth.speeds, times: truth.times) else { return nil }
        return b - a
    case .distance:
        return crossing(of: split.to, in: truth.distances, times: truth.times).map { $0 - t0 }
    case .braking:
        return nil
    }
}

func trueBrakingDistance(from speed: Double, truth: Truth) -> Double? {
    guard let peak = truth.speeds.indices.max(by: { truth.speeds[$0] < truth.speeds[$1] }),
          let i = truth.speeds.indices.last(where: { $0 > peak && truth.speeds[$0] >= speed }),
          let stop = truth.speeds.indices.first(where: { $0 > i && truth.speeds[$0] <= 0 }) else { return nil }
    return truth.distances[stop] - truth.distances[i]
}

// A fast EV: 1 g off the line until the power limit, then brake hard to a stop.
func evLaunch(launchAt t0: Double, peakG: Double, power: Double, top: Double, liftAt: Double) -> Drive {
    var phase = 0, liftTime = 0.0
    return Drive(name: "EV launch", profile: { t, v in
        switch phase {
        case 0:
            guard t >= t0 else { return (0, 0) }
            if v >= top { phase = 1; liftTime = t; return (-0.25, 0) }
            let ramp = min(1, (t - t0) / 0.15)
            let a = min(peakG * ramp, power / max(v, 0.1) / standardGravity) - 0.0003 * v * v / standardGravity
            return (a, 0.02 * sin(t))
        case 1:
            if t - liftTime > 2 { phase = 2 }
            return (-0.25, 0)
        default:
            return v > 0 ? (-1.0, 0) : (0, 0)
        }
    }, duration: t0 + 60)
}

func gentle(launchAt t0: Double) -> Drive {
    Drive(name: "gentle driving", profile: { t, v in
        guard t >= t0 else { return (0, 0) }
        if t < t0 + 8 { return (v < 14 ? 0.15 : 0, 0.05 * sin(t)) }
        if t < t0 + 20 { return (0, 0.1 * sin(t / 2)) }
        return v > 0 ? (-0.2, 0) : (0, 0)
    }, duration: t0 + 35)
}

let checks: [String] = ["0-60mph", "0-100kmh", "0-130mph", "60-130mph", "quarter", "402m"]
var worst = 0.0
var failures = 0

for (label, latency, vibration, peakG, power, top) in [
    // Power is W/kg at the wheels; top is where the driver lifts.
    ("Plaid-like", 0.0, 0.0, 1.1, 300.0, 135 * Units.mph),
    ("Plaid-like, GPS 0.3 s late", 0.3, 0.0, 1.1, 300.0, 135 * Units.mph),
    ("SRT-like, engine vibration", 0.15, 0.03, 0.75, 170.0, 135 * Units.mph),
    ("Model 3 LR-like", 0.2, 0.0, 0.8, 150.0, 110 * Units.mph),
] {
    var errors: [String: [Double]] = [:]
    var brakeErrors: [Double] = []
    for seed in 1...12 {
        let t0 = 6.0
        let (runs, truth) = simulate(evLaunch(launchAt: t0, peakG: peakG, power: power, top: top, liftAt: 0),
                                     seed: UInt64(seed * 7919), latency: latency, vibration: vibration)
        guard let run = runs.first(where: { $0.kind == .launch }) else {
            print("  \(label) seed \(seed): no launch detected"); failures += 1; continue
        }
        for id in checks {
            guard let split = SplitDef.all.first(where: { $0.id == id }),
                  let truthTime = trueSplit(split, truth: truth, launchAt: t0) else { continue }
            guard let measured = run.result(id) else {
                print("  \(label) seed \(seed): missing \(id)"); failures += 1; continue
            }
            errors[id, default: []].append(measured.time - truthTime)
        }
        if let braking = runs.first(where: { $0.kind == .braking })?.result("60-0mph"),
           let d = braking.distance, let truthD = trueBrakingDistance(from: 60 * Units.mph, truth: truth) {
            brakeErrors.append(d - truthD)
            if seed <= 3 { print(String(format: "  braking seed %d: measured %.2f m, true %.2f m, time %.3f s", seed, d, truthD, braking.time)) }
        } else {
            print("  \(label) seed \(seed): no 60-0 braking result"); failures += 1
        }
    }
    print("\(label):")
    for id in checks {
        guard let e = errors[id], !e.isEmpty else { continue }
        let mean = e.reduce(0, +) / Double(e.count)
        let maxAbs = e.map(abs).max()!
        worst = max(worst, maxAbs)
        print(String(format: "  %-10@ mean error %+.3f s  worst %.3f s  (%d runs)", id as NSString, mean, maxAbs, e.count))
    }
    if !brakeErrors.isEmpty {
        let maxAbs = brakeErrors.map(abs).max()!
        print(String(format: "  60-0 mph   worst distance error %.2f m", maxAbs))
    }
}

// Ordinary driving must not be saved as a run.
var falseRuns = 0
for seed in 1...8 {
    let (runs, _) = simulate(gentle(launchAt: 5), seed: UInt64(seed * 104729), latency: 0.2, vibration: 0.01)
    falseRuns += runs.count
}
print("gentle driving: \(falseRuns) runs saved (want 0)")
if falseRuns > 0 { failures += 1 }

print(String(format: "worst split error %.3f s, %d failures", worst, failures))
exit(failures == 0 && worst < 0.15 ? 0 : 1)
