import Foundation

/// Horizontal acceleration of the phone in a fixed world frame (z up, gravity removed), in g.
/// The engine works out which horizontal direction is "forward" on its own, so the phone can
/// sit in any mount at any angle, as long as it doesn't move relative to the car.
struct MotionSample {
    let t: Double
    let x: Double
    let y: Double
}

/// A GPS speed reading. `t` is the fix time on the same clock as the motion samples.
struct SpeedFix {
    let t: Double
    /// m/s
    let speed: Double
    /// m/s, 1σ; zero or less when unknown.
    let accuracy: Double
}

struct AltitudeSample {
    let t: Double
    let metres: Double
}

/// Detects launches, rolling pulls and stops, and times them.
///
/// GPS on a phone reports speed about once a second — far too coarse to time a 3-second run
/// on its own — while the accelerometer reports 100 times a second but drifts. The engine
/// integrates the accelerometer and pins the result to the GPS readings: for each run it fits
/// speed(t) = v₀ + s·∫a − b·t (starting speed, accelerometer scale and bias) to the GPS fixes by
/// weighted least squares, with priors that keep s near 1 and b near 0 when there are only a
/// few fixes. A launch starts at zero by definition and a stop ends at zero, which pins v₀.
final class LaunchEngine: @unchecked Sendable {  // confined to one queue by its owner
    enum Phase: String, Codable {
        /// Waiting for the car to stand still once, to learn the accelerometer's bias.
        case calibrating
        /// Standing still: the next launch will be timed.
        case ready
        case running
        case moving
    }

    /// Called with each finished run, on the thread that fed the engine.
    var onRun: ((RunResult) -> Void)?
    /// Name stored with each run ("iPhone", or an external GPS).
    var source = "iPhone"
    /// Launches with a lower peak than this (g) are treated as ordinary driving and not saved.
    var minimumLaunchG = 0.3

    private(set) var phase: Phase = .calibrating
    /// Best current estimate, m/s.
    private(set) var speed = 0.0
    /// Smoothed for display, g. Positive = speeding up / turning right... sign of lateral is arbitrary.
    private(set) var longG = 0.0
    private(set) var latG = 0.0
    /// While running: seconds and metres since the start.
    private(set) var runTime: Double?
    private(set) var runDistance: Double?
    /// While running: splits already passed, by id, from the live estimate (the saved run is
    /// recomputed with every GPS fix and may differ by a few hundredths).
    private(set) var liveSplits: [String: Double] = [:]
    /// While running: when the car had rolled one foot, from the live estimate.
    private(set) var liveRollout: Double?
    /// Seconds GPS speed lags reality; learned from runs with enough fixes.
    private(set) var gpsLatency = 0.0

    private var samples: [MotionSample] = []
    /// Bias-corrected, lightly smoothed copy of `samples` (same indices), for detection.
    private var quick: [(x: Double, y: Double)] = []
    private var fixes: [SpeedFix] = []
    private var altitudes: [AltitudeSample] = []

    private var bias = (x: 0.0, y: 0.0)
    private var axis: (x: Double, y: Double)?
    private var stillSince: Double?
    private var triggerSince: Double?
    private var endSince: Double?
    private var brakeStart: Double?
    private var brakeResume: Double?

    private struct Run {
        let kind: RunResult.Kind
        let t0: Double
        var times: [Double] = []
        /// Along-axis acceleration, g, and its running integral (g·s).
        var along: [Double] = []
        var integral: [Double] = []
        var fit: Fit
        var maxSpeed = 0.0
        var peakG = 0.0
        var distance = 0.0
        var fixCount = 0
    }
    private var run: Run?

    // MARK: Input

    func add(_ sample: MotionSample) {
        let previous = samples.last
        samples.append(sample)
        let raw = (x: sample.x - bias.x, y: sample.y - bias.y)
        let last = quick.last ?? raw
        let q = (x: last.x + 0.25 * (raw.x - last.x), y: last.y + 0.25 * (raw.y - last.y))
        quick.append(q)

        let dt = previous.map { min(max(sample.t - $0.t, 0), 0.1) } ?? 0
        let (lon, lat) = project(q)
        longG += 0.1 * (lon - longG)
        latG += 0.1 * (lat - latG)

        updateStillness(at: sample.t)

        switch phase {
        case .calibrating:
            break
        case .ready:
            detectLaunch(at: sample.t)
        case .running:
            advanceRun(sample)
        case .moving:
            speed = max(0, speed + lon * standardGravity * dt)
            detectRolling(at: sample.t)
        }
        trackBraking(at: sample.t)
        trim(now: sample.t)
    }

    func add(_ fix: SpeedFix) {
        guard fix.speed >= 0 else { return }
        if let previous = fixes.last { learnAxis(from: previous, to: fix) }
        fixes.append(fix)
        switch phase {
        case .running:
            refit()
        case .moving, .calibrating:
            // Without a run to anchor to, blend towards GPS; it is only for display.
            speed = axis == nil ? fix.speed : speed + 0.4 * (fix.speed - speed)
        case .ready:
            break
        }
    }

    func add(_ altitude: AltitudeSample) {
        altitudes.append(altitude)
    }

    // MARK: Standing still

    private func updateStillness(at t: Double) {
        let window = recent(0.6, before: t)
        guard window.count >= 30 else { return }
        var mx = 0.0, my = 0.0
        for i in window { mx += samples[i].x; my += samples[i].y }
        mx /= Double(window.count); my /= Double(window.count)
        var variance = 0.0
        for i in window {
            let dx = samples[i].x - mx, dy = samples[i].y - my
            variance += dx * dx + dy * dy
        }
        let jitter = (variance / Double(window.count)).squareRoot()
        let recentFix = fixes.last.flatMap { t - $0.t < 2.5 ? $0 : nil }
        let gpsSaysStopped = recentFix.map { $0.speed < 0.8 } ?? (speed < 1)
        let quiet = jitter < 0.045 && gpsSaysStopped && hypot(mx - bias.x, my - bias.y) < 0.08
            || jitter < 0.045 && phase == .calibrating && gpsSaysStopped

        guard quiet else { stillSince = nil; return }
        if stillSince == nil { stillSince = t }
        guard let since = stillSince, t - since >= 0.5 else { return }

        // Stopped: whatever the accelerometer reads now is its bias.
        bias.x += 0.05 * (mx - bias.x)
        bias.y += 0.05 * (my - bias.y)
        switch phase {
        case .running:
            finishRun(endingAt: since)
            phase = .ready
        case .moving, .calibrating:
            finishBraking(stoppedAt: since)
            phase = .ready
        case .ready:
            break
        }
        speed = 0
    }

    // MARK: Starting a run

    private func detectLaunch(at t: Double) {
        let q = quick[quick.count - 1]
        guard hypot(q.x, q.y) > 0.1 else { triggerSince = nil; return }
        if triggerSince == nil { triggerSince = t }
        guard let since = triggerSince, t - since >= 0.08 else { return }
        triggerSince = nil

        // The run began when the car first moved, a little before it crossed the threshold.
        var t0 = since - 0.05
        for i in recent(0.5, before: since).reversed() where hypot(quick[i].x, quick[i].y) < 0.03 {
            t0 = samples[i].t
            break
        }
        begin(.launch, at: t0, speed: 0)
    }

    private func detectRolling(at t: Double) {
        guard axis != nil, speed > 8, longG > 0.25 else { triggerSince = nil; return }
        if triggerSince == nil { triggerSince = t }
        guard let since = triggerSince, t - since >= 0.3 else { return }
        triggerSince = nil
        var t0 = since
        for i in recent(1.5, before: since).reversed() where project(quick[i]).0 < 0.08 {
            t0 = samples[i].t
            break
        }
        begin(.rolling, at: t0, speed: speed)
    }

    private func begin(_ kind: RunResult.Kind, at t0: Double, speed v0: Double) {
        // Rolling pulls start at an estimated speed that GPS will correct; launches at zero.
        let prior = kind == .launch ? (v0, 0.001) : (v0, 1.5)
        run = Run(kind: kind, t0: t0, fit: Fit(v0: v0, scale: 1, bias: 0, reference: t0, v0Prior: prior))
        phase = .running
        liveSplits = [:]
        liveRollout = nil
        endSince = nil
        runTime = 0
        runDistance = 0
        if kind == .launch { lockAxis(from: t0, to: samples.last!.t) }
        rebuildRun()
        refit()
    }

    // MARK: During a run

    private func advanceRun(_ sample: MotionSample) {
        guard var current = run else { return }
        let elapsed = sample.t - current.t0
        if current.kind == .launch && elapsed < 0.5 {
            // The first half second of a launch is the clearest look at which way is forward.
            lockAxis(from: current.t0, to: sample.t)
            rebuildRun()
            current = run!
        } else {
            append(sample, to: &current)
            run = current
        }

        let v = currentSpeed()
        if let previousDistance = runDistance, let t = runTime {
            current.distance = previousDistance + (v + speed) / 2 * max(0, elapsed - t)
        }
        current.maxSpeed = max(current.maxSpeed, v)
        current.peakG = max(current.peakG, longG)
        run = current
        speed = v
        runTime = elapsed
        runDistance = current.distance
        noteLiveSplits(current)

        // The run is over once the driver lifts or brakes, or the speed has clearly peaked.
        let slowing = longG < -0.2 || v < current.maxSpeed - 4
        if slowing {
            if endSince == nil { endSince = sample.t }
        } else {
            endSince = nil
        }
        if let end = endSince, sample.t - end >= 0.3 || v < current.maxSpeed - 4 {
            finishRun(endingAt: end)
            phase = .moving
        } else if elapsed > 90 {
            finishRun(endingAt: sample.t)
            phase = .moving
        }
    }

    private func noteLiveSplits(_ current: Run) {
        guard let t = runTime, let d = runDistance else { return }
        if liveRollout == nil && d >= 0.3048 && current.kind == .launch { liveRollout = t }
        for split in SplitDef.all where liveSplits[split.id] == nil {
            switch split.kind {
            case .speed where split.from == 0 && current.kind == .launch:
                if speed >= split.to { liveSplits[split.id] = t }
            case .distance where current.kind == .launch:
                if d >= split.to { liveSplits[split.id] = t }
            default:
                break
            }
        }
    }

    private func currentSpeed() -> Double {
        guard let run, let t = run.times.last, let integral = run.integral.last else { return speed }
        let v = run.fit.speed(integral: integral, at: t)
        return run.kind == .launch ? max(0, v) : v
    }

    private func append(_ sample: MotionSample, to run: inout Run) {
        let a = project((x: sample.x - bias.x, y: sample.y - bias.y)).0
        let previousT = run.times.last ?? run.t0
        let previousA = run.along.last ?? a
        let previousI = run.integral.last ?? 0
        run.times.append(sample.t)
        run.along.append(a)
        run.integral.append(previousI + (a + previousA) / 2 * max(0, sample.t - previousT))
    }

    private func rebuildRun() {
        guard var current = run else { return }
        current.times = []; current.along = []; current.integral = []
        for i in indices(from: current.t0) { append(samples[i], to: &current) }
        run = current
    }

    private func refit() {
        guard var current = run, let end = current.times.last else { return }
        let window = fixes.filter { $0.t >= current.t0 - 0.5 && $0.t <= end + 0.5 }
        current.fixCount = window.count
        // One or two GPS readings can't show how late GPS runs, and a late one would drag the
        // estimate down, so the first seconds of a launch go on the accelerometer alone.
        let usable = window.filter { $0.t - gpsLatency >= current.t0 }
        guard current.kind == .rolling || usable.count >= 3 else { run = current; return }
        let latency = usable.count >= 3
            ? Fit.bestLatency(times: current.times, integral: current.integral, fixes: window,
                              reference: current.t0, v0Prior: current.fit.v0Prior)
            : gpsLatency
        current.fit = Fit.solve(times: current.times, integral: current.integral, fixes: window,
                                reference: current.t0, v0Prior: current.fit.v0Prior, latency: latency)
        run = current
    }

    // MARK: Finishing

    private func finishRun(endingAt tEnd: Double) {
        defer { run = nil; runTime = nil; runDistance = nil; endSince = nil }
        guard var current = run else { return }
        rebuildRun()
        current = run!
        let cut = current.times.firstIndex { $0 > tEnd } ?? current.times.count
        guard cut > 10 else { return }
        let times = Array(current.times[..<cut])
        let integral = Array(current.integral[..<cut])
        let along = Array(current.along[..<cut])
        let window = fixes.filter { $0.t >= current.t0 - 0.5 && $0.t <= tEnd + 0.5 }

        var latency = gpsLatency
        if window.count >= 5 {
            latency = Fit.bestLatency(times: times, integral: integral, fixes: window,
                                      reference: current.t0, v0Prior: current.fit.v0Prior)
            gpsLatency += 0.5 * (latency - gpsLatency)
        }
        let fit = Fit.solve(times: times, integral: integral, fixes: window, reference: current.t0,
                            v0Prior: current.fit.v0Prior, latency: latency)
        var v = zip(times, integral).map { fit.speed(integral: $1, at: $0) }
        if current.kind == .launch { v = v.map { max(0, $0) } }
        let d = cumulativeDistance(times: times, speeds: v)

        let results = measure(kind: current.kind, t0: current.t0, times: times, speeds: v, distances: d)
        let peak = along.reduce(-Double.infinity) { max($0, $1) }
        guard !results.isEmpty else { return }
        guard current.kind != .launch || current.peakG >= minimumLaunchG else { return }

        let result = RunResult(
            kind: current.kind, results: results, maxSpeed: v.max() ?? 0, peakG: max(current.peakG, min(peak, 3)),
            distance: d.last ?? 0, duration: (times.last ?? current.t0) - current.t0,
            elevationChange: elevationChange(from: current.t0, to: tEnd),
            trace: trace(t0: current.t0, times: times, speeds: v, along: along), source: source)
        onRun?(result)
    }

    private func measure(kind: RunResult.Kind, t0: Double, times: [Double], speeds v: [Double],
                         distances d: [Double]) -> [SplitResult] {
        let rollout = crossing(of: 0.3048, in: d, times: times)
        var out: [SplitResult] = []
        for split in SplitDef.all {
            switch split.kind {
            case .speed where split.from == 0:
                guard kind == .launch, let tc = crossing(of: split.to, in: v, times: times) else { continue }
                out.append(SplitResult(split: split, time: tc - t0, timeWithRollout: rollout.map { tc - $0 },
                                       finishSpeed: nil, distance: nil))
            case .speed:
                // A rolling split only counts if the run started below its lower speed.
                guard let first = v.first, first < split.from - 1,
                      let a = crossing(of: split.from, in: v, times: times),
                      let b = crossing(of: split.to, in: v, times: times) else { continue }
                out.append(SplitResult(split: split, time: b - a, timeWithRollout: nil, finishSpeed: nil, distance: nil))
            case .distance:
                guard kind == .launch, let tc = crossing(of: split.to, in: d, times: times) else { continue }
                out.append(SplitResult(split: split, time: tc - t0, timeWithRollout: rollout.map { tc - $0 },
                                       finishSpeed: interpolate(times: times, values: v, at: tc), distance: nil))
            case .braking:
                continue
            }
        }
        return out
    }

    // MARK: Braking

    private func trackBraking(at t: Double) {
        if longG < -0.3 && speed > 15 {
            if brakeStart == nil { brakeStart = t }
            brakeResume = nil
        } else if brakeStart != nil && longG > 0.1 {
            if brakeResume == nil { brakeResume = t }
            if let resume = brakeResume, t - resume > 1 { brakeStart = nil; brakeResume = nil }
        }
    }

    private func finishBraking(stoppedAt stillStart: Double) {
        defer { brakeStart = nil; brakeResume = nil }
        guard let start = brakeStart, stillStart - start < 25, axis != nil else { return }

        // The car stopped where the deceleration ended, a moment before stillness was noticed.
        // Unsmoothed samples, so the smoothing lag doesn't add to the time.
        var tStop = stillStart
        for i in recent(3, before: stillStart).reversed()
        where project((x: samples[i].x - bias.x, y: samples[i].y - bias.y)).0 < -0.15 {
            tStop = samples[i].t + 0.01
            break
        }
        let from = start - 4
        var segment = Run(kind: .braking, t0: from, fit: Fit(v0: 0, scale: 1, bias: 0, reference: tStop, v0Prior: (0, 0.001)))
        for i in indices(from: from) where samples[i].t <= tStop { append(samples[i], to: &segment) }
        guard segment.times.count > 50, let stopIntegral = segment.integral.last else { return }
        // Measure the integral from the stop, where the speed is known to be zero.
        let integral = segment.integral.map { $0 - stopIntegral }
        let window = fixes.filter { $0.t >= from - 0.5 && $0.t <= tStop + 0.5 }
        let fit = Fit.solve(times: segment.times, integral: integral, fixes: window, reference: tStop,
                            v0Prior: (0, 0.001), latency: gpsLatency)
        let v = zip(segment.times, integral).map { max(0, fit.speed(integral: $1, at: $0)) }

        var results: [SplitResult] = []
        for split in SplitDef.all where split.kind == .braking {
            // The last time the speed fell through the split's starting speed.
            guard let first = v.first, first >= split.from,
                  let i = v.indices.last(where: { v[$0] >= split.from }), i + 1 < v.count else { continue }
            let fraction = (v[i] - split.from) / max(v[i] - v[i + 1], 1e-9)
            let tc = segment.times[i] + fraction * (segment.times[i + 1] - segment.times[i])
            var distance = 0.0
            for j in (i + 1)..<v.count {
                let t1 = j == i + 1 ? tc : segment.times[j - 1]
                let v1 = j == i + 1 ? split.from : v[j - 1]
                distance += (v1 + v[j]) / 2 * (segment.times[j] - t1)
            }
            results.append(SplitResult(split: split, time: tStop - tc, timeWithRollout: nil, finishSpeed: nil, distance: distance))
        }
        guard !results.isEmpty else { return }
        let d = cumulativeDistance(times: segment.times, speeds: v)
        onRun?(RunResult(
            kind: .braking, results: results, maxSpeed: v.max() ?? 0,
            peakG: -(segment.along.min() ?? 0), distance: d.last ?? 0, duration: tStop - from,
            elevationChange: elevationChange(from: from, to: tStop),
            trace: trace(t0: from, times: segment.times, speeds: v, along: segment.along), source: source))
    }

    // MARK: Which way is forward

    private func project(_ a: (x: Double, y: Double)) -> (Double, Double) {
        guard let axis else { return (0, 0) }
        return (a.x * axis.x + a.y * axis.y, a.y * axis.x - a.x * axis.y)
    }

    /// Forward is the average direction of acceleration over a launch's first moments.
    private func lockAxis(from t0: Double, to t1: Double) {
        var sx = 0.0, sy = 0.0
        for i in indices(from: t0) where samples[i].t <= t1 {
            sx += samples[i].x - bias.x
            sy += samples[i].y - bias.y
        }
        let n = hypot(sx, sy)
        if n > 1e-6 { axis = (sx / n, sy / n) }
    }

    /// While driving, compare GPS speed changes with the accelerometer to find forward.
    private func learnAxis(from a: SpeedFix, to b: SpeedFix) {
        guard phase != .running else { return }
        let dt = b.t - a.t
        guard dt > 0.5, dt < 1.6 else { return }
        let gpsG = (b.speed - a.speed) / dt / standardGravity
        guard abs(gpsG) > 0.08 else { return }
        var sx = 0.0, sy = 0.0, n = 0.0
        for i in indices(from: a.t - gpsLatency) where samples[i].t <= b.t - gpsLatency {
            sx += samples[i].x - bias.x; sy += samples[i].y - bias.y; n += 1
        }
        guard n > 20 else { return }
        let m = hypot(sx, sy) / n
        guard m > 0.05 else { return }
        let sign = gpsG > 0 ? 1.0 : -1.0
        let dir = (x: sx / n / m * sign, y: sy / n / m * sign)
        if let axis {
            let x = axis.x * 0.7 + dir.x * 0.3, y = axis.y * 0.7 + dir.y * 0.3, len = hypot(x, y)
            self.axis = (x / len, y / len)
        } else {
            axis = dir
        }
    }

    // MARK: Helpers

    private func recent(_ seconds: Double, before t: Double) -> [Int] {
        var out: [Int] = []
        var i = samples.count - 1
        while i >= 0 && samples[i].t > t { i -= 1 }
        while i >= 0 && samples[i].t >= t - seconds { out.append(i); i -= 1 }
        return out.reversed()
    }

    private func indices(from t: Double) -> Range<Int> {
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        return lo..<samples.count
    }

    private func trim(now: Double) {
        guard samples.count > 16_000, phase != .running else { return }
        let keepFrom = indices(from: now - 60).lowerBound
        samples.removeFirst(keepFrom)
        quick.removeFirst(keepFrom)
        fixes.removeAll { $0.t < now - 60 }
        altitudes.removeAll { $0.t < now - 120 }
    }

    private func elevationChange(from t0: Double, to t1: Double) -> Double? {
        guard let a = altitudes.last(where: { $0.t <= t0 + 0.5 }) ?? altitudes.first,
              let b = altitudes.last(where: { $0.t <= t1 + 0.5 }),
              b.t - a.t > (t1 - t0) * 0.5 else { return nil }
        return b.metres - a.metres
    }

    private func trace(t0: Double, times: [Double], speeds: [Double], along: [Double]) -> [TracePoint] {
        var out: [TracePoint] = []
        var next = times.first ?? t0
        for i in times.indices where times[i] >= next {
            out.append(TracePoint(t: times[i] - t0, v: speeds[i], a: along[i]))
            next = times[i] + 0.05
        }
        return out
    }
}

// MARK: - Fitting speed to GPS

/// speed(t) = v₀ + scale·g·I(t) − bias·g·(t − reference), where I is the integrated acceleration.
struct Fit {
    var v0: Double
    var scale: Double
    var bias: Double
    var reference: Double
    var v0Prior: (Double, Double)

    func speed(integral: Double, at t: Double) -> Double {
        v0 + scale * standardGravity * integral - bias * standardGravity * (t - reference)
    }

    /// Weighted least squares with Gaussian priors on all three parameters.
    static func solve(times: [Double], integral: [Double], fixes: [SpeedFix], reference: Double,
                      v0Prior: (Double, Double), latency: Double) -> Fit {
        let scalePrior = (1.0, 0.03), biasPrior = (0.0, 0.01)
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var r = [0.0, 0.0, 0.0]
        for (index, prior) in [v0Prior, scalePrior, biasPrior].enumerated() {
            let w = 1 / (prior.1 * prior.1)
            m[index][index] += w
            r[index] += w * prior.0
        }
        for fix in fixes {
            let t = fix.t - latency
            // Readings from outside the samples can't be compared with them.
            guard let first = times.first, let last = times.last, t >= first, t <= last + 0.2 else { continue }
            let i = interpolate(times: times, values: integral, at: t)
            let h = [1, standardGravity * i, -standardGravity * (t - reference)]
            let sigma = fix.accuracy > 0 ? max(fix.accuracy, 0.15) : 0.5
            let w = 1 / (sigma * sigma)
            for a in 0..<3 {
                r[a] += w * h[a] * fix.speed
                for b in 0..<3 { m[a][b] += w * h[a] * h[b] }
            }
        }
        let p = solve3(m, r) ?? [v0Prior.0, 1, 0]
        return Fit(v0: p[0], scale: p[1], bias: p[2], reference: reference, v0Prior: v0Prior)
    }

    /// The GPS delay (0–0.5 s) that makes the fixes agree best with the accelerometer.
    static func bestLatency(times: [Double], integral: [Double], fixes: [SpeedFix], reference: Double,
                            v0Prior: (Double, Double)) -> Double {
        var best = (latency: 0.0, error: Double.infinity)
        for step in 0...10 {
            let latency = Double(step) * 0.05
            let fit = solve(times: times, integral: integral, fixes: fixes, reference: reference, v0Prior: v0Prior, latency: latency)
            var error = 0.0
            for fix in fixes {
                let t = fix.t - latency
                guard let first = times.first, t >= first, t <= times.last! else { continue }
                let e = fit.speed(integral: interpolate(times: times, values: integral, at: t), at: t) - fix.speed
                error += e * e
            }
            if error < best.error { best = (latency, error) }
        }
        return best.latency
    }

    private static func solve3(_ m: [[Double]], _ r: [Double]) -> [Double]? {
        var a = m, b = r
        for col in 0..<3 {
            guard let pivot = (col..<3).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot); b.swapAt(col, pivot)
            for row in 0..<3 where row != col {
                let f = a[row][col] / a[col][col]
                for k in 0..<3 { a[row][k] -= f * a[col][k] }
                b[row] -= f * b[col]
            }
        }
        return (0..<3).map { b[$0] / a[$0][$0] }
    }
}

// MARK: - Series helpers

func interpolate(times: [Double], values: [Double], at t: Double) -> Double {
    guard let first = times.first, let last = times.last else { return 0 }
    if t <= first { return values[0] }
    if t >= last { return values[values.count - 1] }
    var lo = 0, hi = times.count - 1
    while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if times[mid] <= t { lo = mid } else { hi = mid }
    }
    let f = (t - times[lo]) / max(times[hi] - times[lo], 1e-9)
    return values[lo] + f * (values[hi] - values[lo])
}

/// The first time a rising series reaches `level`, interpolated between samples.
func crossing(of level: Double, in values: [Double], times: [Double]) -> Double? {
    guard let i = values.firstIndex(where: { $0 >= level }) else { return nil }
    guard i > 0 else { return times[0] }
    let f = (level - values[i - 1]) / max(values[i] - values[i - 1], 1e-9)
    return times[i - 1] + f * (times[i] - times[i - 1])
}

func cumulativeDistance(times: [Double], speeds: [Double]) -> [Double] {
    var d = [Double](repeating: 0, count: times.count)
    for i in times.indices.dropFirst() {
        d[i] = d[i - 1] + (speeds[i] + speeds[i - 1]) / 2 * (times[i] - times[i - 1])
    }
    return d
}
