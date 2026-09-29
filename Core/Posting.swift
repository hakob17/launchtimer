import Foundation

/// A run in the shape the leaderboard server checks (api/src/validate.js): results by split id,
/// and the full speed trace so the server can recompute every time itself.
enum Posting {
    static func run(_ run: RunResult) -> [String: Any] {
        var out: [String: Any] = [
            "id": run.id.uuidString,
            "kind": run.kind.rawValue,
            "date": (run.date.timeIntervalSince1970 * 1000).rounded(),
            "source": run.source,
            "results": run.results.map { r -> [String: Any] in
                var item: [String: Any] = ["id": r.split.id, "time": round3(r.time)]
                if let t = r.timeWithRollout { item["rollout"] = round3(t) }
                if let d = r.distance { item["distance"] = round3(d) }
                return item
            },
            "trace": run.trace.map { [round3($0.t), round3($0.v), round3($0.a)] },
        ]
        if let grade = run.grade { out["grade"] = round3(grade) }
        return out
    }

    /// The boards a run can go on, and the value each would show.
    static func boardValues(_ run: RunResult) -> [(metric: String, value: Double)] {
        guard run.source == "iPhone" else { return [] }
        var out: [(String, Double)] = []
        for board in Board.all {
            guard let r = run.result(board.id) else { continue }
            switch board.id {
            case "0-60mph", "quarter": if let t = r.timeWithRollout { out.append((board.id, t)) }
            case "60-0mph": if let d = r.distance { out.append((board.id, d)) }
            default: out.append((board.id, r.time))
            }
        }
        return out
    }

    private static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

/// The leaderboards. US launch times use the 1-ft rollout, metric ones don't — each follows
/// its home convention, so times compare with magazines and drag slips.
struct Board: Identifiable, Hashable {
    let id: String
    let label: String
    /// "s" for seconds, "m" for metres.
    let unit: String
    let note: String

    static let all: [Board] = [
        Board(id: "0-60mph", label: "0–60 mph", unit: "s", note: "With 1-ft rollout"),
        Board(id: "0-100kmh", label: "0–100 km/h", unit: "s", note: "From the first movement"),
        Board(id: "quarter", label: "¼ mile", unit: "s", note: "With 1-ft rollout"),
        Board(id: "60-130mph", label: "60–130 mph", unit: "s", note: "Rolling"),
        Board(id: "100-200kmh", label: "100–200 km/h", unit: "s", note: "Rolling"),
        Board(id: "60-0mph", label: "60–0 mph", unit: "m", note: "Braking distance"),
    ]
}
