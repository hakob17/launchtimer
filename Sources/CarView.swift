import SwiftUI

struct CarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        Text("Open in the car's browser").font(.headline)
                        Text(AppModel.carPageURL)
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        Text("Big speed, timer, g-meter and your results on the car's screen — Tesla, or any car with a web browser.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = "https://" + AppModel.carPageURL
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }

                    Card {
                        Text("Pairing code").font(.headline)
                        Text("Enter it once on the car page.").font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Text(PairCode.formatted(model.pairCode))
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("New code") { model.newPairCode() }.buttonStyle(.bordered)
                        }
                        HStack {
                            Circle().fill(model.carsWatching > 0 ? Color.green : Color.gray).frame(width: 10, height: 10)
                            Text("Car screen")
                            Spacer()
                            Text(model.carsWatching > 0 ? "Connected" : "Not connected")
                                .foregroundStyle(.secondary).font(.subheadline)
                        }
                    }

                    Card {
                        Text("How it works").font(.headline)
                        Text("The phone does the timing. It sends small updates — speed, g-force and results — to the car page through the internet, ten times a second while the car page is open. It uses very little data, and nothing is stored.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Car screen")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var board: Leaderboard

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Units", selection: $model.units) {
                        Text("mph, feet").tag(Units.imperial)
                        Text("km/h, metres").tag(Units.metric)
                    }
                    Toggle("1-ft rollout", isOn: $model.showRollout)
                } footer: {
                    Text("Drag strips and most magazines start the clock after the car has rolled one foot, which makes times about 0.2 s quicker. Turn this off to time from the very first movement.")
                }

                Section {
                    NavigationLink {
                        CarPickerView()
                    } label: {
                        LabeledContent("Your car", value: board.car?.title ?? "Choose")
                    }
                    HStack {
                        LabeledContent("Driver name", value: board.handle)
                        Button("New") { board.newHandle() }.buttonStyle(.bordered)
                    }
                    Toggle("Post runs automatically", isOn: $board.autoPost)
                        .disabled(board.car == nil || !board.acceptedTerms)
                } header: {
                    Text("Leaderboard")
                } footer: {
                    Text(board.acceptedTerms
                         ? "New runs go on the leaderboard as soon as they're saved. Driver names are generated so boards stay friendly."
                         : "Post a run once from its details to turn this on. Driver names are generated so boards stay friendly.")
                }

                Section {
                    Button {
                        model.demoRunning ? model.endDemo() : model.playDemo()
                    } label: {
                        Label(model.demoRunning ? "Stop demo" : "Play demo run", systemImage: model.demoRunning ? "stop.fill" : "play.fill")
                    }
                } footer: {
                    Text("Plays a simulated launch and stop, so you can see the timer and the car screen without driving.")
                }

                Section("About") {
                    Text("Launch Timer uses the iPhone's GPS, motion sensors and barometer. Runs stay on this phone unless you post them to the leaderboard.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("Privacy policy", destination: URL(string: "https://hakob17.github.io/launchtimer/privacy.html")!)
                    Text("Only time runs on a closed course or drag strip.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Link("Report a problem", destination: URL(string: "https://github.com/hakob17/launchtimer/issues")!)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
