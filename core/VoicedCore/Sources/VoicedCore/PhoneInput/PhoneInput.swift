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
        /// The transcript line the sentence is, so the Mac's run for it shows under that line.
        public var line: String?
        /// For `claude`: the earlier requests of the same record and what Claude concluded, oldest
        /// first, which the Mac gives Claude along with this one.
        public var history: [ClaudeExchange]?

        public init(text: String, mode: Mode = .type, folder: String? = nil, line: String? = nil, history: [ClaudeExchange]? = nil) {
            self.text = text
            self.mode = mode
            self.folder = folder
            self.line = line
            self.history = history
        }

        public init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)) ?? .type
            folder = try? container.decodeIfPresent(String.self, forKey: .folder)
            line = try? container.decodeIfPresent(String.self, forKey: .line)
            history = try? container.decodeIfPresent([ClaudeExchange].self, forKey: .history)
        }
    }

    /// The bytes sent for one sentence: its message as JSON, ended by a line feed. JSON escapes
    /// any line break inside the text, so a line feed only ever ends a message.
    public static func encode(_ text: String, mode: Mode = .type, folder: String? = nil, line: String? = nil,
                              history: [ClaudeExchange]? = nil) -> Data {
        var data = (try? JSONEncoder().encode(Message(text: text, mode: mode, folder: folder, line: line, history: history))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The bytes sent for a command to one of the Mac's Claude Code runs.
    public static func encode(_ command: ClaudeRunCommand) -> Data {
        var data = (try? JSONEncoder().encode(command)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Collects bytes from the Mac and hands back the run events completed by them.
    public struct EventDecoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func feed(_ data: Data) -> [ClaudeRunEvent] {
            buffer.append(data)
            var events: [ClaudeRunEvent] = []
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<end]
                buffer.removeSubrange(buffer.startIndex...end)
                if let event = try? JSONDecoder().decode(ClaudeRunEvent.self, from: line) { events.append(event) }
            }
            return events
        }
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

/// The system a machine running the voiced service has, from the `os` key of its Bonjour TXT
/// record.
public enum MachinePlatform: Sendable {
    case mac
    case windows

    init?(txt value: String?) {
        switch value {
        case "macos": self = .mac
        case "windows": self = .windows
        default: return nil
        }
    }

    /// The system's name, the same in every language.
    public var name: String {
        switch self {
        case .mac: "macOS"
        case .windows: "Windows"
        }
    }
}

/// What a machine's Bonjour TXT record says about it, for the list of machines: its system, host
/// name and addresses on the local network. Each is nil when the service does not say, as older
/// ones do not.
public struct MachineInfo: Equatable, Sendable {
    public var platform: MachinePlatform?
    public var host: String?
    /// IPv4, comma-separated when there are several.
    public var ip: String?

    init(txt: NWTXTRecord) {
        platform = MachinePlatform(txt: txt["os"])
        host = txt["host"].flatMap { $0.isEmpty ? nil : $0 }
        ip = txt["ip"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The parts known, in order: system, host name, address.
    public var parts: [String] {
        [platform?.name, host, ip].compactMap { $0 }
    }
}

/// The phone's side: finds a machine (Mac or Windows) running the voiced service on the local
/// network, keeps a connection to it and sends it sentences. Connects to the machine chosen by
/// name, or with none chosen to the first found, by name, and looks again whenever the connection
/// ends. A sentence sent while no machine is connected is dropped rather than typed late. The
/// machine tells it over the same connection how the Claude Code runs of Run sentences go.
@MainActor
public final class PhoneInputSender: ObservableObject {
    /// The name of the Mac sentences go to; nil while none is connected.
    @Published public private(set) var connectedName: String?
    /// The names of the machines found on the network, sorted.
    @Published public private(set) var availableNames: [String] = []
    /// What each machine found says about itself, by name; kept for machines no longer found, so a
    /// chosen machine that is away still shows what it was.
    @Published public private(set) var machines: [String: MachineInfo] = [:]
    /// Whether the sender is looking for, or connected to, a Mac.
    @Published public private(set) var isActive = false
    /// The Mac's Claude Code runs, by id, as last heard; replaced whenever a connection opens.
    @Published public private(set) var runs: [String: ClaudeRun] = [:]
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
        // With the TXT record, which says what system the machine has, its host name and address.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PhoneInput.serviceType, domain: nil), using: .tcp)
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

    /// Looks for machines again from scratch, for a machine that has just started its service or
    /// one that went away without saying so. A machine already connected stays connected; a
    /// connection still trying to open is given up and tried again once machines are found.
    public func refresh() {
        guard isActive else { return }
        retry?.cancel()
        retry = nil
        browser?.cancel()
        browser = nil
        results = []
        availableNames = []
        if let connection, connectedName == nil {
            connection.cancel()
            dropConnection()
        }
        start()
    }

    /// The system of the machine called `name`, when it said.
    public func platform(of name: String?) -> MachinePlatform? {
        name.flatMap { machines[$0]?.platform }
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
    /// runs it in `claude` mode, with `history`, the conversation so far, for Claude to refer to.
    /// Returns false when no Mac is connected, so nothing went out.
    @discardableResult
    public func send(_ text: String, mode: PhoneInput.Mode = .type, folder: String? = nil, line: String? = nil,
                     history: [ClaudeExchange]? = nil) -> Bool {
        guard let connection, connectedName != nil else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        connection.send(content: PhoneInput.encode(trimmed, mode: mode, folder: mode == .claude ? folder : nil,
                                                   line: mode == .claude ? line : nil,
                                                   history: mode == .claude && history?.isEmpty == false ? history : nil),
                        completion: .contentProcessed { _ in })
        return true
    }

    /// Stops a run, or allows or denies the tool it waits on. Returns false when no Mac is connected.
    @discardableResult
    public func send(_ command: ClaudeRunCommand) -> Bool {
        guard let connection, connectedName != nil else { return false }
        connection.send(content: PhoneInput.encode(command), completion: .contentProcessed { _ in })
        return true
    }

    /// The latest run for a transcript line.
    public func latestRun(forLine line: String) -> ClaudeRun? {
        runs.values.filter { $0.line == line }.max { ($0.startedAt ?? .infinity) < ($1.startedAt ?? .infinity) }
    }

    private func browsed(_ results: Set<NWBrowser.Result>, by browser: NWBrowser) {
        guard self.browser === browser else { return }
        self.results = results.sorted { Self.name(of: $0.endpoint) < Self.name(of: $1.endpoint) }
        let names = self.results.map { Self.name(of: $0.endpoint) }
        if names != availableNames { availableNames = names }
        var machines = self.machines
        for result in self.results {
            if case .bonjour(let txt) = result.metadata {
                machines[Self.name(of: result.endpoint)] = MachineInfo(txt: txt)
            }
        }
        if machines != self.machines { self.machines = machines }
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
        receive(on: connection, decoder: PhoneInput.EventDecoder())
    }

    /// Reads the Mac's run events until the connection ends.
    private nonisolated func receive(on connection: NWConnection, decoder: PhoneInput.EventDecoder) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var decoder = decoder
            let events = data.map { decoder.feed($0) } ?? []
            if !events.isEmpty {
                Task { @MainActor in self?.apply(events, from: connection) }
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receive(on: connection, decoder: decoder)
            }
        }
    }

    private func apply(_ events: [ClaudeRunEvent], from connection: NWConnection) {
        guard self.connection === connection else { return }
        var runs = self.runs
        for event in events { event.apply(to: &runs) }
        self.runs = runs
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
