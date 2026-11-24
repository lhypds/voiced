import VoicedCore
import AppKit
import Foundation
import Network

/// The Mac's side of phone input: advertises Voiced over Bonjour under the Mac's name, accepts
/// connections from the iPhone app and hands every sentence received to `onText`.
@MainActor
final class PhoneInputReceiver: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var connectionCount = 0
    @Published private(set) var error: String?

    var onText: (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: "Voiced.PhoneInputReceiver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func start() {
        guard listener == nil else { return }
        error = nil
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: Host.current().localizedName, type: PhoneInput.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.update(listener, state: state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
        connectionCount = 0
        isListening = false
    }

    private func update(_ listener: NWListener, state: NWListener.State) {
        guard self.listener === listener else { return }
        switch state {
        case .ready:
            isListening = true
            error = nil
        case .failed(let failure):
            error = failure.localizedDescription
            stop()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connectionCount = connections.count
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, decoder: PhoneInput.Decoder())
    }

    private nonisolated func receive(on connection: NWConnection, decoder: PhoneInput.Decoder) {
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

    private func drop(_ id: ObjectIdentifier) {
        connections[id] = nil
        connectionCount = connections.count
    }
}
