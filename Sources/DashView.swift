import SwiftUI
import CoreLocation

struct DashView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusChip
                if model.authorization == .denied || model.authorization == .restricted {
                    locationWarning
                }
                speedBlock
                splitGrid
                Card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("G-meter").font(.headline)
                            Text("Peak accel \(Format.g(model.peakLong))").font(.subheadline.monospacedDigit())
                            Text("Peak lateral \(Format.g(model.peakLat))").font(.subheadline.monospacedDigit())
                        }
                        .foregroundStyle(.secondary)
                        Spacer()
                        GMeter(longG: model.live.longG, latG: model.live.latG, trail: model.trail)
                            .frame(width: 150, height: 150)
                    }
                }
                if let run = model.latestRun {
                    NavigationLink(value: run) { LatestRunCard(run: run) }.buttonStyle(.plain)
                }
                tips
            }
            .padding(16)
        }
        .navigationDestinationWrapper()
    }

    private var statusChip: some View {
        let (text, color): (String, Color) = {
            if model.demoRunning && model.live.phase != .running { return ("Demo — watch the launch", .purple) }
            switch model.live.phase {
            case .calibrating: return ("Hold still to calibrate", .yellow)
            case .ready: return ("Ready — launch when you want", .green)
            case .running: return ("Timing…", .orange)
            case .moving: return ("Driving — stop to time a launch", .blue)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text).font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(color.opacity(0.18)))
        .frame(maxWidth: .infinity)
    }

    private var locationWarning: some View {
        Card {
            Label("Location is off", systemImage: "location.slash").font(.headline)
            Text("GPS keeps the timing accurate. Without it, times drift.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Open Settings") { model.requestLocation() }.buttonStyle(.bordered)
        }
    }

    private var speedBlock: some View {
        VStack(spacing: 0) {
            Text(Format.speed(model.live.speed, model.units))
                .font(.system(size: 112, weight: .heavy, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .minimumScaleFactor(0.5)
            Text(model.units.speedLabel).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            if let t = model.live.runTime {
                Text(String(format: "%.2f", t))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            } else if let run = model.latestRun, let headline = run.headline(for: model.units) {
                Text("\(headline.split.label)  \(Format.time(of: headline, rollout: model.showRollout))")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var splitGrid: some View {
        let splits = SplitDef.shown(in: model.units).filter { $0.kind != .braking }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(splits) { split in
                let value: String = {
                    if model.live.phase == .running {
                        return model.displayedSplits(model.live)[split.id].map(Format.time) ?? "—"
                    }
                    guard let result = model.latestRun?.result(split.id) else { return "—" }
                    return Format.time(of: result, rollout: model.showRollout)
                }()
                VStack(spacing: 4) {
                    Text(split.label).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.headline.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    private var tips: some View {
        Card {
            Text("How to time a run").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Mount the phone firmly — any angle works, but it must not move.")
                Text("2. Stop and wait for “Ready”.")
                Text("3. Launch. Timing starts on the first movement and stops when you lift.")
                Text("4. For braking, get above 60 mph (100 km/h) and brake to a full stop.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("Accuracy: typically within a tenth of a second on a flat, straight road with a good GPS signal.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct LatestRunCard: View {
    @EnvironmentObject private var model: AppModel
    let run: RunResult

    var body: some View {
        Card {
            HStack {
                Text(run.kind == .braking ? "Last stop" : "Last run").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            ForEach(run.results.filter { SplitDef.shown(in: model.units).contains($0.split) }) { result in
                HStack {
                    Text(result.split.label)
                    Spacer()
                    if let detail = Format.detail(of: result, model.units) {
                        Text(detail).foregroundStyle(.secondary)
                    }
                    Text(Format.time(of: result, rollout: model.showRollout)).monospacedDigit().bold()
                }
                .font(.subheadline)
            }
            if let grade = run.grade, abs(grade) > 0.01 {
                Label(String(format: "%.1f%% %@ — not comparable with flat runs", abs(grade) * 100, grade < 0 ? "downhill" : "uphill"),
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.yellow)
            }
        }
    }
}

private extension View {
    /// The dashboard lives in a NavigationStack so the last-run card can open its details.
    func navigationDestinationWrapper() -> some View {
        NavigationStack {
            self
                .navigationTitle("Launch Timer")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: RunResult.self) { RunDetailView(run: $0) }
        }
    }
}
