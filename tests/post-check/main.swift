// Posts a real engine run through the app's Leaderboard client to a local API:
//   (cd api && npx wrangler dev --local --port 8799) &
//   swiftc Core/*.swift Sources/Leaderboard.swift tests/post-check/main.swift -o build/post-check
//   LT_API=http://127.0.0.1:8799 build/post-check
import Foundation

@MainActor func check() async -> Int32 {
    let engine = LaunchEngine()
    var runs: [RunResult] = []
    engine.onRun = { runs.append($0) }
    for e in DemoDrive.events() {
        switch e { case .motion(let m): engine.add(m); case .fix(let f): engine.add(f); case .altitude(let a): engine.add(a) }
    }
    guard let demo = runs.first(where: { $0.kind == .launch }) else { print("FAIL no run"); return 1 }
    // Posted as if measured on a phone (the demo itself is refused).
    let run = RunResult(kind: demo.kind, results: demo.results, maxSpeed: demo.maxSpeed, peakG: demo.peakG, distance: demo.distance,
                        duration: demo.duration, elevationChange: demo.elevationChange, trace: demo.trace, source: "iPhone")
    let board = Leaderboard()
    board.car = Car(make: "Jeep", model: "Grand Cherokee", year: 2021, trim: "Trackhawk")
    do {
        let results = try await board.post(run)
        print("ok   posted:", results.map { "\($0.metric)=\($0.value) #\($0.overall.rank)/\($0.overall.of) verified=\($0.verified)" })
        let entries = try await board.board("0-60mph", make: "Jeep", model: "Grand Cherokee")
        print(entries.contains { $0.model == "Grand Cherokee" && $0.trim == "Trackhawk" } ? "ok   board shows it" : "FAIL not on board")
        let models = try await CarCatalog.models(make: "Tesla", year: 2024)
        print(models.contains("Model 3") ? "ok   NHTSA models: \(models)" : "FAIL NHTSA")
        return 0
    } catch {
        print("FAIL", error.localizedDescription); return 1
    }
}
exit(await check())
