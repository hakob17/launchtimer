import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var board: Leaderboard

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All cars", myModel = "My model", country = "My country"
        var id: String { rawValue }
    }

    @State private var metric = Board.all[0]
    @State private var scope = Scope.all
    @State private var entries: [BoardEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var reported: BoardEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Board", selection: $metric) {
                        ForEach(Board.all) { Text($0.label).tag($0) }
                    }
                    Picker("Show", selection: $scope) {
                        ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(metric.note + ". Each driver's best per car. ✓ = posted from a verified iPhone.")
                }

                if let car = board.car {
                    Section("You") {
                        LabeledContent("Driver", value: board.handle)
                        LabeledContent("Car", value: car.title)
                    }
                } else {
                    Section {
                        NavigationLink("Choose your car to post runs") { CarPickerView() }
                    }
                }

                Section {
                    if loading && entries.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else if entries.isEmpty {
                        Text(scope == .myModel && board.car == nil ? "Choose your car to see its board." : "No results yet. Be the first!")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        EntryRow(rank: index + 1, entry: entry, unit: metric.unit, units: model.units,
                                 mine: entry.handle == board.handle && entry.model == board.car?.model)
                            .swipeActions {
                                Button("Report") { reported = entry }.tint(.orange)
                                Button("Hide") { board.hide(entry); entries.removeAll { $0.driverKey == entry.driverKey } }
                            }
                            .contextMenu {
                                Button("Report", systemImage: "flag") { reported = entry }
                                Button("Hide this driver", systemImage: "eye.slash") {
                                    board.hide(entry); entries.removeAll { $0.driverKey == entry.driverKey }
                                }
                            }
                    }
                }
            }
            .navigationTitle("Leaderboard")
            .refreshable { await load() }
            .task(id: "\(metric.id)|\(scope.rawValue)|\(board.car?.model ?? "")") { await load() }
            .confirmationDialog("Report this result?", isPresented: .constant(reported != nil), titleVisibility: .visible, presenting: reported) { entry in
                Button("Report as fake or offensive", role: .destructive) {
                    Task { await board.report(entry); board.hide(entry); entries.removeAll { $0.id == entry.id }; reported = nil }
                }
                Button("Cancel", role: .cancel) { reported = nil }
            } message: { _ in
                Text("Results reported by several drivers are removed. It's also hidden for you.")
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            switch scope {
            case .all: entries = try await board.board(metric.id)
            case .myModel:
                guard let car = board.car else { entries = []; return }
                entries = try await board.board(metric.id, make: car.make, model: car.model)
            case .country:
                entries = try await board.board(metric.id, country: board.country)
            }
            error = nil
        } catch {
            self.error = "Couldn't load the leaderboard. Check your connection and pull to refresh."
        }
    }
}

private struct EntryRow: View {
    let rank: Int
    let entry: BoardEntry
    let unit: String
    let units: Units
    let mine: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.headline.monospacedDigit())
                .frame(width: 34)
                .foregroundStyle(rank <= 3 ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.handle).font(.headline)
                    if entry.verified == 1 { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.caption) }
                    if mine { Text("You").font(.caption2.bold()).padding(.horizontal, 5).background(Capsule().fill(.orange.opacity(0.3))) }
                }
                Text(entry.carTitle + (entry.country.map { " · \(flag($0))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.headline.monospacedDigit())
        }
    }

    private var value: String {
        unit == "m" ? String(format: "%.1f %@", units.distance(entry.value), units.distanceLabel) : String(format: "%.2f s", entry.value)
    }

    private func flag(_ country: String) -> String {
        country.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}

// MARK: - Choosing a car

struct CarPickerView: View {
    @EnvironmentObject private var board: Leaderboard
    @Environment(\.dismiss) private var dismiss

    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var make = ""
    @State private var customMake = ""
    @State private var models: [String] = []
    @State private var model = ""
    @State private var customModel = ""
    @State private var trim = ""
    @State private var loading = false

    private var chosenMake: String { make == "Other" ? customMake.trimmingCharacters(in: .whitespaces) : make }
    private var chosenModel: String { models.isEmpty || model == "Other" ? customModel.trimmingCharacters(in: .whitespaces) : model }

    var body: some View {
        Form {
            Section {
                Picker("Year", selection: $year) {
                    ForEach((1990...(Calendar.current.component(.year, from: Date()) + 1)).reversed(), id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("Make", selection: $make) {
                    Text("Choose").tag("")
                    ForEach(CarCatalog.makes, id: \.self) { Text($0).tag($0) }
                    Text("Other").tag("Other")
                }
                if make == "Other" { TextField("Make", text: $customMake) }
                if loading {
                    HStack { Text("Model"); Spacer(); ProgressView() }
                } else if !models.isEmpty {
                    NavigationLink {
                        ModelListView(models: models, selection: $model)
                    } label: {
                        LabeledContent("Model", value: model.isEmpty ? "Choose" : model)
                    }
                }
                if !chosenMake.isEmpty && !loading && (models.isEmpty || model == "Other") {
                    TextField("Model", text: $customModel)
                }
                TextField("Trim (optional), e.g. Plaid, SRT Hellcat", text: $trim)
                    .textInputAutocapitalization(.words)
            } footer: {
                Text("Your car is shown next to your results on the leaderboard. Makes and models come from the US NHTSA vehicle database.")
            }

            Section {
                Button("Save") {
                    board.car = Car(make: chosenMake, model: chosenModel, year: year,
                                    trim: String(trim.trimmingCharacters(in: .whitespaces).prefix(24)))
                    dismiss()
                }
                .disabled(chosenMake.isEmpty || chosenModel.isEmpty)
            }
        }
        .navigationTitle("Your car")
        .onAppear {
            if let car = board.car {
                year = car.year
                make = CarCatalog.makes.contains(car.make) ? car.make : "Other"
                customMake = car.make
                model = car.model
                customModel = car.model
                trim = car.trim
            }
        }
        .task(id: "\(make)|\(year)") {
            guard !make.isEmpty, make != "Other" else { models = []; return }
            loading = true
            models = (try? await CarCatalog.models(make: make, year: year)) ?? []
            loading = false
            if !models.contains(model) && model != "Other" { model = "" }
        }
    }
}

/// A searchable list of models; picking one goes back.
private struct ModelListView: View {
    let models: [String]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List {
            ForEach(models.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } + ["Other"], id: \.self) { name in
                Button {
                    selection = name
                    dismiss()
                } label: {
                    HStack {
                        Text(name == "Other" ? "Other (type it)" : name).foregroundStyle(.primary)
                        Spacer()
                        if selection == name { Image(systemName: "checkmark").foregroundStyle(.orange) }
                    }
                }
                .tint(.primary)
            }
        }
        .searchable(text: $search, prompt: "Search models")
        .navigationTitle("Model")
    }
}

// MARK: - Posting a run

/// "Post to leaderboard" for a run, or its ranks once posted.
struct PostRunSection: View {
    @EnvironmentObject private var board: Leaderboard
    let run: RunResult
    @State private var error: String?
    @State private var askingTerms = false

    var body: some View {
        if board.canPost(run) {
            Section("Leaderboard") {
                if let results = board.posted[run.id.uuidString] {
                    ForEach(results, id: \.metric) { r in
                        HStack {
                            Text(Board.all.first { $0.id == r.metric }?.label ?? r.metric)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("#\(r.overall.rank) of \(r.overall.of)").bold().monospacedDigit()
                                Text("#\(r.model.rank) of \(r.model.of) \(board.car?.model ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if board.car == nil {
                    NavigationLink("Choose your car to post this run") { CarPickerView() }
                } else {
                    Button {
                        if board.acceptedTerms { post() } else { askingTerms = true }
                    } label: {
                        HStack {
                            Label("Post to leaderboard", systemImage: "trophy")
                            if board.posting.contains(run.id.uuidString) { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(board.posting.contains(run.id.uuidString))
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            .alert("Post to the leaderboard?", isPresented: $askingTerms) {
                Button("Post") { board.acceptedTerms = true; post() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your times, your car, your driver name (\(board.handle)) and your country are shown publicly. Only post runs from a closed course or drag strip, and don't use offensive car names — they can be reported and removed.")
            }
        }
    }

    private func post() {
        error = nil
        Task {
            do { try await board.post(run) } catch { self.error = error.localizedDescription }
        }
    }
}
