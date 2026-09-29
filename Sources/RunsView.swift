import SwiftUI
import Charts

struct RunsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.runs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "stopwatch").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("No runs yet").font(.title3.bold())
                        Text("Runs are saved automatically. To see how it works, play the demo in Settings.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding(32)
                } else {
                    List {
                        ForEach(model.runs) { run in
                            NavigationLink(value: run) { RunRow(run: run) }
                        }
                        .onDelete { offsets in offsets.map { model.runs[$0] }.forEach(model.delete) }
                    }
                }
            }
            .navigationTitle("Runs")
            .navigationDestination(for: RunResult.self) { RunDetailView(run: $0) }
        }
    }
}

struct RunRow: View {
    @EnvironmentObject private var model: AppModel
    let run: RunResult

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(run.date.formatted(date: .abbreviated, time: .shortened) + (run.source == "iPhone" ? "" : " · \(run.source)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let headline = run.headline(for: model.units) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.time(of: headline, rollout: model.showRollout)).font(.headline.monospacedDigit())
                    Text(headline.split.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var title: String {
        switch run.kind {
        case .launch: return "Launch · \(Format.speed(run.maxSpeed, model.units)) \(model.units.speedLabel)"
        case .rolling: return "Rolling pull"
        case .braking: return "Braking"
        }
    }
}

struct RunDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let run: RunResult

    var body: some View {
        List {
            Section {
                ForEach(run.results) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(result.split.label)
                            Spacer()
                            if let detail = Format.detail(of: result, model.units) {
                                Text(detail).foregroundStyle(.secondary)
                            }
                            Text(Format.time(of: result, rollout: model.showRollout)).monospacedDigit().bold()
                        }
                        if let rollout = result.timeWithRollout {
                            Text(model.showRollout
                                 ? "Without 1-ft rollout: \(Format.time(result.time))"
                                 : "With 1-ft rollout: \(Format.time(rollout))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(run.kind == .braking ? "Braking" : "Times")
            }

            Section("Speed") {
                Chart {
                    ForEach(Array(run.trace.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Time", point.t), y: .value("Speed", model.units.speed(point.v)))
                            .foregroundStyle(.orange)
                    }
                }
                .chartXAxisLabel("seconds")
                .chartYAxisLabel(model.units.speedLabel)
                .frame(height: 200)
                .padding(.vertical, 8)
            }

            Section("Details") {
                if run.kind != .braking {
                    row("Top speed", "\(Format.speed(run.maxSpeed, model.units)) \(model.units.speedLabel)")
                    row("Distance", String(format: "%.0f %@", model.units.distance(run.distance), model.units.distanceLabel))
                }
                row(run.kind == .braking ? "Peak braking" : "Peak acceleration", Format.g(run.peakG))
                if let grade = run.grade {
                    row("Slope", String(format: "%+.1f%%", grade * 100))
                }
                row("Measured with", run.source)
                row("Date", run.date.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                ShareLink(item: summary) { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) {
                    model.delete(run)
                    dismiss()
                } label: {
                    Label("Delete run", systemImage: "trash")
                }
            }
        }
        .navigationTitle(run.kind == .braking ? "Braking" : "Run")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).monospacedDigit() }
    }

    private var summary: String {
        let lines = run.results.filter { SplitDef.shown(in: model.units).contains($0.split) }.map {
            "\($0.split.label): \(Format.time(of: $0, rollout: model.showRollout))" + (Format.detail(of: $0, model.units).map { " \($0)" } ?? "")
        }
        return (lines + ["Timed with Launch Timer"]).joined(separator: "\n")
    }
}
