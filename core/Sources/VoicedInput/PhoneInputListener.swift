import Foundation
import Network

/// Advertises the service over Bonjour under the Mac's name, accepts connections from the iPhone
/// app and hands every sentence received to `onText`, on the main actor.
@MainActor
final class PhoneInputListener {
    var onText: (String) -> Void = { _ in }
    /// Called when the listener can no longer accept connections.
    var onFailure: (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: "VoicedInput.PhoneInputListener")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start() throws {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: Host.current().localizedName, type: PhoneInputMessages.serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.update(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func update(_ state: NWListener.State) {
        switch state {
        case .ready:
            log("Listening on port \(listener?.port.map { "\($0.rawValue)" } ?? "?") as \(PhoneInputMessages.serviceType)")
        case .failed(let failure):
            onFailure(failure.localizedDescription)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let peer = connection.endpoint.debugDescription
        connections[id] = connection
        log("Connected: \(peer) (\(connections.count) open)")
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(id, peer: peer) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, decoder: PhoneInputMessages.Decoder())
    }

    private nonisolated func receive(on connection: NWConnection, decoder: PhoneInputMessages.Decoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var decoder = decoder
            let messages = data.map { decoder.feed($0) } ?? []
            if !messages.isEmpty {
                Task { @MainActor in messages.forEach { self?.onText($0.text) } }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receive(on: connection, decoder: decoder)
            }
        }
    }

    private func drop(_ id: ObjectIdentifier, peer: String) {
        guard connections.removeValue(forKey: id) != nil else { return }
        log("Disconnected: \(peer) (\(connections.count) open)")
    }
}

func log(_ message: String) {
    let time = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.colon))
    print("[\(time)] \(message)")
    fflush(stdout)
}
