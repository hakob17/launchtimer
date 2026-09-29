import Foundation
import DeviceCheck
import CryptoKit

/// The car a driver posts results for. Make and model come from NHTSA's vehicle list; the trim
/// is typed ("Plaid", "SRT Hellcat").
struct Car: Codable, Hashable {
    var make: String
    var model: String
    var year: Int
    var trim: String

    var title: String { "\(year) \(make) \(model)" + (trim.isEmpty ? "" : " \(trim)") }
}

/// A row on a board.
struct BoardEntry: Codable, Identifiable, Hashable {
    let id: Int
    let handle: String
    let make: String
    let model: String
    let year: Int
    let trim: String
    let country: String?
    let value: Double
    let verified: Int
    let created: Double

    var carTitle: String { "\(year) \(make) \(model)" + (trim.isEmpty ? "" : " \(trim)") }
    /// Used to hide a driver locally.
    var driverKey: String { "\(handle)|\(make)|\(model)" }
}

struct Rank: Codable, Hashable {
    let rank: Int
    let of: Int
}

/// What the server said about one posted result.
struct PostedResult: Codable, Hashable {
    let metric: String
    let value: Double
    let verified: Bool
    let overall: Rank
    let model: Rank
    let country: Rank?
}

/// Talks to the leaderboard API (api/src/index.js). Posts are signed with an App Attest key
/// when the device supports it, which marks them verified; the server also recomputes every
/// time from the run's speed trace.
@MainActor
final class Leaderboard: ObservableObject {
    /// LT_API overrides the server for tests (tests/post-check).
    static let baseURL = URL(string: ProcessInfo.processInfo.environment["LT_API"] ?? "https://launchtimer-api.hakob-hakobyan173.workers.dev")!

    static let adjectives = ["Amber", "Arctic", "Atomic", "Blazing", "Bold", "Cobalt", "Cosmic", "Crimson", "Electric", "Emerald",
                             "Fierce", "Golden", "Granite", "Hyper", "Iron", "Jade", "Lunar", "Midnight", "Neon", "Nitro",
                             "Obsidian", "Onyx", "Quantum", "Rapid", "Rocket", "Scarlet", "Silver", "Solar", "Sonic", "Stealth",
                             "Storm", "Swift", "Thunder", "Titan", "Turbo", "Velvet", "Violet", "Volt", "Wild", "Zen"]
    static let animals = ["Badger", "Bison", "Cheetah", "Cobra", "Condor", "Coyote", "Dragon", "Eagle", "Falcon", "Ferret",
                          "Fox", "Gazelle", "Hawk", "Hornet", "Jaguar", "Kestrel", "Lynx", "Mako", "Mamba", "Marlin",
                          "Mustang", "Orca", "Osprey", "Otter", "Panther", "Puma", "Raptor", "Raven", "Rhino", "Shark",
                          "Stallion", "Stingray", "Tiger", "Viper", "Wasp", "Wolf", "Wolverine", "Yak", "Zebra", "Kraken"]

    @Published var car: Car? { didSet { save(car, "lb.car") } }
    @Published private(set) var handle: String
    @Published var autoPost: Bool { didSet { UserDefaults.standard.set(autoPost, forKey: "lb.autoPost") } }
    @Published var acceptedTerms: Bool { didSet { UserDefaults.standard.set(acceptedTerms, forKey: "lb.terms") } }
    /// Results the server returned, by run id.
    @Published private(set) var posted: [String: [PostedResult]]
    @Published private(set) var posting: Set<String> = []
    @Published private(set) var hiddenDrivers: Set<String>

    let deviceID: String
    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "lb.device") { deviceID = id } else {
            deviceID = UUID().uuidString
            d.set(deviceID, forKey: "lb.device")
        }
        handle = d.string(forKey: "lb.handle") ?? Leaderboard.randomHandle()
        car = (d.data(forKey: "lb.car")).flatMap { try? JSONDecoder().decode(Car.self, from: $0) }
        autoPost = d.bool(forKey: "lb.autoPost")
        acceptedTerms = d.bool(forKey: "lb.terms")
        posted = (d.data(forKey: "lb.posted")).flatMap { try? JSONDecoder().decode([String: [PostedResult]].self, from: $0) } ?? [:]
        hiddenDrivers = Set(d.stringArray(forKey: "lb.hidden") ?? [])
        d.set(handle, forKey: "lb.handle")
    }

    static func randomHandle() -> String {
        "\(adjectives.randomElement()!) \(animals.randomElement()!) \(Int.random(in: 1...99))"
    }

    func newHandle() {
        handle = Self.randomHandle()
        defaults.set(handle, forKey: "lb.handle")
    }

    var country: String? { Locale.current.region?.identifier }

    // MARK: Posting

    /// Whether this run has anything a board takes.
    func canPost(_ run: RunResult) -> Bool { !Posting.boardValues(run).isEmpty }

    @discardableResult
    func post(_ run: RunResult) async throws -> [PostedResult] {
        guard let car else { throw LeaderboardError.message("Choose your car first, in Settings.") }
        let key = run.id.uuidString
        posting.insert(key)
        defer { posting.remove(key) }

        var body: [String: Any] = [:]
        let payload: [String: Any] = [
            "device": deviceID, "handle": handle, "country": country as Any,
            "car": ["make": car.make, "model": car.model, "year": car.year, "trim": car.trim],
            "run": Posting.run(run),
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        body["payload"] = String(data: payloadData, encoding: .utf8)
        if let assertion = try? await assertion(for: payloadData) { body["assertion"] = assertion }

        struct Response: Decodable { let ok: Bool?; let error: String?; let results: [PostedResult]? }
        let response: Response = try await request("v1/runs", body: body)
        guard let results = response.results else { throw LeaderboardError.message(response.error ?? "The server refused the run.") }
        posted[key] = results
        save(posted, "lb.posted")
        return results
    }

    func board(_ metric: String, make: String? = nil, model: String? = nil, country: String? = nil) async throws -> [BoardEntry] {
        var items = [URLQueryItem(name: "metric", value: metric), URLQueryItem(name: "limit", value: "100")]
        if let make { items.append(URLQueryItem(name: "make", value: make)) }
        if let model { items.append(URLQueryItem(name: "model", value: model)) }
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        struct Response: Decodable { let entries: [BoardEntry]?; let error: String? }
        let response: Response = try await request("v1/board", query: items)
        guard let entries = response.entries else { throw LeaderboardError.message(response.error ?? "Couldn't load the board.") }
        return entries.filter { !hiddenDrivers.contains($0.driverKey) }
    }

    func report(_ entry: BoardEntry) async {
        struct Response: Decodable { let ok: Bool? }
        let _: Response? = try? await request("v1/report", body: ["entry": entry.id, "device": deviceID])
    }

    func hide(_ entry: BoardEntry) {
        hiddenDrivers.insert(entry.driverKey)
        defaults.set(Array(hiddenDrivers), forKey: "lb.hidden")
    }

    // MARK: App Attest

    /// Signs a post with this install's attested key, attesting it first if needed. Returns nil
    /// where App Attest isn't available (Simulator, older devices); such posts aren't verified.
    private func assertion(for payload: Data) async throws -> String? {
        let service = DCAppAttestService.shared
        guard service.isSupported else { return nil }
        let keyID = try await attestedKey(service)
        let hash = Data(SHA256.hash(data: payload))
        do {
            return try await service.generateAssertion(keyID, clientDataHash: hash).base64EncodedString()
        } catch {
            // A key the system no longer knows (restored backup, reinstall): start over once.
            defaults.removeObject(forKey: "lb.attestedKey")
            let fresh = try await attestedKey(service)
            return try await service.generateAssertion(fresh, clientDataHash: hash).base64EncodedString()
        }
    }

    private func attestedKey(_ service: DCAppAttestService) async throws -> String {
        if let key = defaults.string(forKey: "lb.attestedKey") { return key }
        struct Challenge: Decodable { let challenge: String }
        let challenge: Challenge = try await request("v1/challenge")
        let keyID = try await service.generateKey()
        let hash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        let attestation = try await service.attestKey(keyID, clientDataHash: hash)
        struct Response: Decodable { let ok: Bool?; let error: String? }
        let response: Response = try await request("v1/attest", body: [
            "device": deviceID, "keyId": keyID, "attestation": attestation.base64EncodedString(),
            "challenge": challenge.challenge,
        ])
        guard response.ok == true else { throw LeaderboardError.message(response.error ?? "Attestation failed.") }
        defaults.set(keyID, forKey: "lb.attestedKey")
        return keyID
    }

    // MARK: HTTP

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

enum LeaderboardError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Makes and models from NHTSA's vPIC database (public domain, no key).
enum CarCatalog {
    /// The makes most people will look for; any other can be typed.
    static let makes = ["Acura", "Alfa Romeo", "Aston Martin", "Audi", "Bentley", "BMW", "Bugatti", "Buick", "BYD", "Cadillac",
                        "Chevrolet", "Chrysler", "Dodge", "Ferrari", "Fiat", "Ford", "Genesis", "GMC", "Honda", "Hyundai",
                        "Infiniti", "Jaguar", "Jeep", "Kia", "Koenigsegg", "Lamborghini", "Land Rover", "Lexus", "Lotus",
                        "Lucid", "Maserati", "Mazda", "McLaren", "Mercedes-Benz", "Mini", "Mitsubishi", "Nissan", "Polestar",
                        "Porsche", "Ram", "Rimac", "Rivian", "Rolls-Royce", "Subaru", "Tesla", "Toyota", "Volkswagen", "Volvo"]

    static func models(make: String, year: Int) async throws -> [String] {
        let escaped = make.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? make
        let url = URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/GetModelsForMakeYear/make/\(escaped)/modelyear/\(year)?format=json")!
        struct Response: Decodable {
            struct Item: Decodable { let Model_Name: String }
            let Results: [Item]
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        let names = try JSONDecoder().decode(Response.self, from: data).Results.map(\.Model_Name)
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
