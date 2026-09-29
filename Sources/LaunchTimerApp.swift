import SwiftUI

@main
struct LaunchTimerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(.orange)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.becameActive() } else { model.resignedActive() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            DashView().tabItem { Label("Timer", systemImage: "gauge.with.dots.needle.67percent") }
            RunsView().tabItem { Label("Runs", systemImage: "list.bullet.rectangle") }
            CarView().tabItem { Label("Car screen", systemImage: "car.fill") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .fullScreenCover(isPresented: .constant(!model.acceptedSafety)) { SafetyView() }
    }
}

// MARK: - Formatting

enum Format {
    static func time(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }
    static func speed(_ metresPerSecond: Double, _ units: Units) -> String {
        String(format: "%.0f", units.speed(metresPerSecond))
    }
    static func g(_ value: Double) -> String { String(format: "%.2f g", value) }

    /// The time for a split as the user has chosen to see it (with or without rollout).
    static func time(of result: SplitResult, rollout: Bool) -> String {
        time(rollout ? (result.timeWithRollout ?? result.time) : result.time)
    }

    static func detail(of result: SplitResult, _ units: Units) -> String? {
        if let v = result.finishSpeed { return "@ \(speed(v, units)) \(units.speedLabel)" }
        if let d = result.distance { return String(format: "%.1f %@", units.distance(d), units.distanceLabel) }
        return nil
    }
}

// MARK: - Safety

struct SafetyView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "flag.checkered.2.crossed").font(.system(size: 56)).foregroundStyle(.orange)
            Text("Track use only").font(.largeTitle.bold())
            Text("Launch Timer measures acceleration and braking. Only do timed runs on a closed course or drag strip, never on public roads, and follow the rules of the venue.")
            Text("Mount your phone firmly before a run and don't touch it while driving. Set it up while parked.")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.acceptedSafety = true
            } label: {
                Text("I understand").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
    }
}

// MARK: - Shared pieces

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

/// A g-meter: longitudinal up (accelerating) and down (braking), lateral left and right.
struct GMeter: View {
    let longG: Double
    let latG: Double
    let trail: [(Double, Double)]
    var range = 1.2

    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2 - 4
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func point(_ lon: Double, _ lat: Double) -> CGPoint {
                CGPoint(x: c.x + lat / range * r, y: c.y - lon / range * r)
            }
            for ring in [0.5, 1.0] {
                let rr = ring / range * r
                context.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                               with: .color(.white.opacity(0.2)), lineWidth: 1)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
            context.stroke(cross, with: .color(.white.opacity(0.12)), lineWidth: 1)
            for (i, p) in trail.enumerated() {
                let q = point(p.0, p.1)
                let alpha = Double(i) / Double(max(trail.count, 1)) * 0.5
                context.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)), with: .color(.orange.opacity(alpha)))
            }
            let q = point(longG, latG)
            context.fill(Path(ellipseIn: CGRect(x: q.x - 9, y: q.y - 9, width: 18, height: 18)), with: .color(.orange))
        }
        .overlay(alignment: .topTrailing) {
            Text(Format.g(hypot(longG, latG))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityLabel("G-meter, \(Format.g(longG)) forward, \(Format.g(latG)) sideways")
    }
}
