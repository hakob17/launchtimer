import Foundation

/// Sends the live dashboard to the car's browser through the relay, as the "phone" side of a
/// pairing code. The car can't reach the phone directly (its browser refuses private
/// addresses), so both ends meet at the relay. Only small JSON messages go over it.
///
/// Phone → car: {"type":"live",…} ten times a second while a car watches, {"type":"runs",…}.
/// Car → phone: {"type":"hello"} asks for the run history. The relay adds {"type":"cars"}.
final class CarLink: NSObject, URLSessionWebSocketDelegate {
    static let relayURL = "wss://teslanav-relay.hakob-hakobyan173.workers.dev/ws"

    /// Called on the main queue.
    var onCars: ((Int) -> Void)?
    var onHello: (() -> Void)?
    var onConnected: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "launchtimer.carlink")
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var room = ""
    private var stopped = true
    private var ping: DispatchSourceTimer?
    private var busy = false

    func connect(room: String) {
        queue.async {
            guard self.stopped || self.room != room else { return }
            self.room = room
            self.stopped = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.open()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.ping?.cancel()
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
        }
    }

    /// Live messages are dropped while the previous one is still being sent: only the latest
    /// matters.
    func sendLive(_ object: [String: Any]) {
        queue.async {
            guard let task = self.task, !self.busy, let text = Self.encode(object) else { return }
            self.busy = true
            task.send(.string(text)) { _ in self.queue.async { self.busy = false } }
        }
    }

    func send(_ object: [String: Any]) {
        queue.async {
            guard let text = Self.encode(object) else { return }
            self.task?.send(.string(text)) { _ in }
        }
    }

    private static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Connection

    private func open() {
        guard !stopped, var url = URLComponents(string: Self.relayURL) else { return }
        url.queryItems = [URLQueryItem(name: "room", value: room), URLQueryItem(name: "role", value: "phone")]
        guard let target = url.url else { return }
        let task = session.webSocketTask(with: target)
        self.task = task
        busy = false
        task.resume()
        receive(on: task)
        ping?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { task.sendPing { _ in } }
        timer.resume()
        ping = timer
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === task else { return }
                switch result {
                case .success(.string(let text)):
                    if let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(object)
                    }
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure:
                    self.dropped(task)
                }
            }
        }
    }

    private func handle(_ object: [String: Any]) {
        switch object["type"] as? String {
        case "cars":
            let count = object["count"] as? Int ?? 0
            DispatchQueue.main.async { self.onCars?(count) }
        case "hello":
            DispatchQueue.main.async { self.onHello?() }
        default:
            break
        }
    }

    private func dropped(_ task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        self.task = nil
        DispatchQueue.main.async { self.onConnected?(false); self.onCars?(0) }
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 2) { self.open() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async {
            guard self.task === webSocketTask else { return }
            DispatchQueue.main.async { self.onConnected?(true) }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.dropped(webSocketTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        queue.async { self.dropped(ws) }
    }
}
