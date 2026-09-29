import Foundation

/// A made-up drive, as the sensors would report it: stand still, launch hard to about 115 mph,
/// lift, brake to a stop. Used by the in-app demo (for trying the app, and for App Review, who
/// can't do a real launch) and to preview the car screen.
enum DemoDrive {
    enum Event {
        case motion(MotionSample)
        case fix(SpeedFix)
        case altitude(AltitudeSample)

        var t: Double {
            switch self {
            case .motion(let m): return m.t
            case .fix(let f): return f.t
            case .altitude(let a): return a.t
            }
        }
    }

    static let duration = 32.0

    /// Events in time order, starting at t = 0.
    static func events(seed: UInt64 = 42) -> [Event] {
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        func gauss() -> Double {
            let u = max(random(), 1e-12), v = random()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }

        let launch = 4.0, peakG = 0.95, power = 190.0, top = 115 * Units.mph
        let yaw = 1.1
        var events: [Event] = []
        var v = 0.0, t = 0.0, stage = 0, stageTime = 0.0
        var nextSample = 0.0, nextFix = 0.37, nextAltitude = 0.0
        var history: [(Double, Double)] = []
        let dt = 0.002
        while t < duration {
            var lon = 0.0
            switch stage {
            case 0:
                if t >= launch {
                    let ramp = min(1, (t - launch) / 0.15)
                    lon = min(peakG * ramp, power / max(v, 0.1) / standardGravity) - 0.0003 * v * v / standardGravity
                    if v >= top { stage = 1; stageTime = t }
                }
            case 1:
                lon = -0.25
                if t - stageTime > 2 { stage = 2 }
            default:
                lon = v > 0 ? -0.95 : 0
            }
            if v <= 0 && lon < 0 { lon = 0 }
            v = max(0, v + lon * standardGravity * dt)
            t += dt
            history.append((t, v))
            let lat = stage == 0 && t > launch ? 0.03 * sin(t * 1.7) : 0

            if t >= nextSample {
                nextSample += 0.01
                let l = lon + gauss() * 0.012, s = lat + gauss() * 0.012
                events.append(.motion(MotionSample(t: t, x: l * cos(yaw) - s * sin(yaw) + 0.004,
                                                   y: l * sin(yaw) + s * cos(yaw) - 0.003)))
            }
            if t >= nextFix {
                nextFix += 1
                let lagged = history.last(where: { $0.0 <= t - 0.15 })?.1 ?? 0
                events.append(.fix(SpeedFix(t: t, speed: max(0, lagged + gauss() * 0.12), accuracy: 0.3)))
            }
            if t >= nextAltitude {
                nextAltitude += 0.1
                events.append(.altitude(AltitudeSample(t: t, metres: 0.4 * sin(t / 10) + gauss() * 0.05)))
            }
        }
        return events
    }
}
