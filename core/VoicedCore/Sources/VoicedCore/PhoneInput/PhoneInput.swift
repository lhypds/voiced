import Foundation
import Network

/// Typing on the Mac with the phone's voice: the iPhone app sends each sentence it commits to a
/// Mac on the same network, and the voiced service (core/) types it wherever the cursor is,
/// such as a terminal prompt. The Mac advertises itself over Bonjour; the phone finds it and
/// connects over TCP. The service keeps a copy of the decoding side; keep the two in step.
///
/// Each message is one JSON object on a line of its own, so later versions can add fields that
/// older ones ignore.
public enum PhoneInput {
    /// The Bonjour service type the Mac advertises and the phone browses for.
    public static let serviceType = "_voiced-input._tcp"

    /// What the Mac does with a sentence, chosen on the phone ("Send to Mac" → mode).
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Typed at the cursor, such as a terminal prompt, and left there to check or add to.
        case type
        /// Typed at the cursor and followed by Return, which sends it at a prompt.
        case typeAndReturn
        /// Carried out by Claude Code in a Terminal window on the Mac.
        case claude

        public var id: String { rawValue }
    }

    public struct Message: Codable, Equatable, Sendable {
        public var text: String
        /// Missing from phones older than the modes, and unknown for modes added later: both
        /// are typed at the cursor.
        public var mode: Mode
        /// The Mac folder Claude Code runs in, for `claude`, set on the phone; `~` stands for the
        /// home folder. Missing or empty: the home folder.
        public var folder: String?

        public init(text: String, mode: Mode = .type, folder: String? = nil) {
            self.text = text
            self.mode = mode
            self.folder = folder
        }

        public init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)) ?? .type
            folder = try? container.decodeIfPresent(String.self, forKey: .folder)
        }
    }

    /// The bytes sent for one sentence: its message as JSON, ended by a line feed. JSON escapes
    /// any line break inside the text, so a line feed only ever ends a message.
    public static func encode(_ text: String, mode: Mode = .type, folder: String? = nil) -> Data {
        var data = (try? JSONEncoder().encode(Message(text: text, mode: mode, folder: folder))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Collects received bytes and hands back the messages completed by them. A message split
    /// across reads waits in the buffer for its end; a line that is not a message is dropped.
    public struct Decoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func feed(_ data: Data) -> [Message] {
            buffer.append(data)
            var messages: [Message] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                if let message = try? JSONDecoder().decode(Message.self, from: line) {
                    messages.append(message)
                }
            }
            return messages
        }
    }

    /// What is typed for a received sentence. Sentences typed one after another must not run
    /// together: one ending in a Latin letter or ASCII punctuation is followed by a space, while
    /// Chinese and Japanese, written without spaces, are typed as they are. Nothing is added
    /// when Return follows, which ends the line anyway.
    public static func typedText(for text: String, pressesReturn: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pressesReturn, let last = trimmed.unicodeScalars.last, last.isASCII else { return trimmed }
        return trimmed + " "
    }
}

/// The phone's side: finds a Mac running Voiced on the local network, keeps a connection to it
/// and sends it sentences. Connects to the Mac chosen by name, or with none chosen to the first
/// found, by name, and looks again whenever the connection ends. A sentence sent while no Mac is
/// connected is dropped rather than typed late.
@MainActor
public final class PhoneInputSender: ObservableObject {
    /// The name of the Mac sentences go to; nil while none is connected.
    @Published public private(set) var connectedName: String?
    /// The names of the Macs found on the network, sorted.
    @Published public private(set) var availableNames: [String] = []
    /// Whether the sender is looking for, or connected to, a Mac.
    @Published public private(set) var isActive = false
    /// The Mac to connect to, by its Bonjour name; nil for the first found. While the chosen Mac
    /// is not on the network nothing is connected, rather than sending to another Mac.
    public var preferredName: String? {
        didSet {
            guard preferredName != oldValue else { return }
            if let connection, let preferredName, connectionName != preferredName {
                connection.cancel()
                dropConnection()
            }
            connectIfIdle()
        }
    }

    private let queue = DispatchQueue(label: "Voiced.PhoneInputSender")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// The name of the Mac `connection` goes to, from before it is ready.
    private var connectionName: String?
    private var results: [NWBrowser.Result] = []
    private var retry: Task<Void, Never>?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        isActive = true
        let browser = NWBrowser(for: .bonjour(type: PhoneInput.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.browsed(results, by: browser) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor in self?.restartBrowser(browser) }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        isActive = false
        retry?.cancel()
        retry = nil
        browser?.cancel()
        browser = nil
        results = []
        availableNames = []
        connection?.cancel()
        dropConnection()
    }

    /// Sends one sentence, for the Mac to handle as `mode` says; `folder` is where Claude Code
    /// runs it in `claude` mode. Returns false when no Mac is connected, so nothing went out.
    @discardableResult
    public func send(_ text: String, mode: PhoneInput.Mode = .type, folder: String? = nil) -> Bool {
        guard let connection, connectedName != nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        connection.send(content: PhoneInput.encode(trimmed, mode: mode, folder: mode == .claude ? folder : nil), completion: .contentProcessed { _ in })
        return true
    }

    private func browsed(_ results: Set<NWBrowser.Result>, by browser: NWBrowser) {
        guard self.browser === browser else { return }
        self.results = results.sorted { Self.name(of: $0.endpoint) < Self.name(of: $1.endpoint) }
        let names = self.results.map { Self.name(of: $0.endpoint) }
        if names != availableNames { availableNames = names }
        connectIfIdle()
    }

    private func restartBrowser(_ failed: NWBrowser) {
        guard browser === failed else { return }
        browser?.cancel()
        browser = nil
        scheduleRetry { $0.start() }
    }

    private func connectIfIdle() {
        guard isActive, connection == nil else { return }
        let result = preferredName.map { name in results.first { Self.name(of: $0.endpoint) == name } } ?? results.first
        guard let result else { return }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        let name = Self.name(of: result.endpoint)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.update(connection, name: name, state: state) }
        }
        self.connection = connection
        connectionName = name
        connection.start(queue: queue)
        watchForClose(connection)
    }

    /// The Mac never sends anything, so a receive only completes when the connection ends.
    private nonisolated func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.watchForClose(connection)
            }
        }
    }

    private func update(_ connection: NWConnection, name: String, state: NWConnection.State) {
        guard self.connection === connection else { return }
        switch state {
        case .ready:
            connectedName = name
        case .failed, .cancelled, .waiting:
            connection.cancel()
            dropConnection()
            scheduleRetry { $0.connectIfIdle() }
        default:
            break
        }
    }

    private func dropConnection() {
        connection = nil
        connectionName = nil
        connectedName = nil
    }

    private func scheduleRetry(_ action: @escaping @MainActor (PhoneInputSender) -> Void) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isActive else { return }
            action(self)
        }
    }

    private static func name(of endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint { return name }
        return endpoint.debugDescription
    }
}
