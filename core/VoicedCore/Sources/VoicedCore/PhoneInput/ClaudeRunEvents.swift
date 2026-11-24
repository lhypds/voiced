import Foundation

/// What the voiced service tells the phone about the Claude Code runs that Run-mode sentences
/// start, and what the phone asks of them; modelled on ~/code/tm's run events. The service keeps
/// a copy (core/Sources/VoicedInput/ClaudeRunEvents.swift); keep the two in step.
///
/// The Mac sends events down the same connection the phone sends sentences up, one JSON object
/// per line: a `snapshot` of every run it keeps whenever the phone connects, then `run` for a
/// run's state, `item` for a transcript item added or replaced at an index, `delta` for text
/// appended to one, and `remove` for a run it no longer keeps.

/// One run of Claude Code for one sentence.
public struct ClaudeRun: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Waiting for the run before it to finish.
        case queued
        case running
        case done
        case failed
        case stopped

        public var isGoing: Bool { self == .queued || self == .running }
    }

    /// A tool Claude wants to use and may not without asking: the phone allows or denies it.
    public struct Pending: Codable, Equatable, Sendable {
        public var id: String
        public var tool: String
        public var summary: String

        public init(id: String, tool: String, summary: String) {
            self.id = id
            self.tool = tool
            self.summary = summary
        }
    }

    public var id: String
    /// The transcript line the sentence was, on the phone that sent it; nil from older phones.
    public var line: String?
    public var text: String
    public var folder: String
    public var state: State
    /// Seconds since 1970.
    public var startedAt: Double?
    public var endedAt: Double?
    public var pending: Pending?
    /// Left out of `run` events, which carry only the state.
    public var items: [ClaudeRunItem]?

    public init(id: String, line: String?, text: String, folder: String, state: State, startedAt: Double? = nil,
                endedAt: Double? = nil, pending: Pending? = nil, items: [ClaudeRunItem]? = []) {
        self.id = id
        self.line = line
        self.text = text
        self.folder = folder
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pending = pending
        self.items = items
    }

    /// The tool in use right now: the last one called and not yet finished.
    public var activeTool: ClaudeRunItem? {
        guard state == .running, let last = items?.last, last.kind == .tool, last.done != true else { return nil }
        return last
    }
}

/// One entry of a run's transcript.
public struct ClaudeRunItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Claude's text, written as it streams.
        case text
        /// A tool call, `done` once its result is in.
        case tool
        /// How the run ended: `durationMs`, `turns`, and `isError` with the reason as `text`.
        case result
        /// Something went wrong outside Claude, such as claude not starting.
        case error
    }

    public var kind: Kind
    public var text: String?
    public var name: String?
    public var summary: String?
    public var done: Bool?
    public var isError: Bool?
    public var result: String?
    public var durationMs: Double?
    public var turns: Int?

    public init(kind: Kind, text: String? = nil, name: String? = nil, summary: String? = nil, done: Bool? = nil,
                isError: Bool? = nil, result: String? = nil, durationMs: Double? = nil, turns: Int? = nil) {
        self.kind = kind
        self.text = text
        self.name = name
        self.summary = summary
        self.done = done
        self.isError = isError
        self.result = result
        self.durationMs = durationMs
        self.turns = turns
    }
}

/// One event from the Mac.
public struct ClaudeRunEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case snapshot
        case run
        case item
        case delta
        case remove
    }

    public var type: Kind
    /// `snapshot`: every run, with its items.
    public var runs: [ClaudeRun]?
    /// `run`: the run's state, without items.
    public var run: ClaudeRun?
    /// `item`, `delta`, `remove`: which run.
    public var id: String?
    /// `item`, `delta`: the item's index.
    public var i: Int?
    public var item: ClaudeRunItem?
    public var text: String?

    public init(type: Kind, runs: [ClaudeRun]? = nil, run: ClaudeRun? = nil, id: String? = nil, i: Int? = nil,
                item: ClaudeRunItem? = nil, text: String? = nil) {
        self.type = type
        self.runs = runs
        self.run = run
        self.id = id
        self.i = i
        self.item = item
        self.text = text
    }

    /// Applies the event to the runs kept by id.
    public func apply(to runs: inout [String: ClaudeRun]) {
        switch type {
        case .snapshot:
            runs = Dictionary((self.runs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        case .run:
            guard var state = run else { return }
            state.items = runs[state.id]?.items ?? []
            runs[state.id] = state
        case .item:
            guard let id, let i, let item, var run = runs[id] else { return }
            var items = run.items ?? []
            if i < items.count { items[i] = item } else if i == items.count { items.append(item) } else { return }
            run.items = items
            runs[id] = run
        case .delta:
            guard let id, let i, let text, var run = runs[id], var items = run.items, i < items.count else { return }
            items[i].text = (items[i].text ?? "") + text
            run.items = items
            runs[id] = run
        case .remove:
            guard let id else { return }
            runs[id] = nil
        }
    }
}

/// What the phone asks of a run: stop it, or answer the tool it is waiting on.
public struct ClaudeRunCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case stop
        case allow
        case deny
    }

    public var command: Action
    public var run: String
    /// `allow`, `deny`: the pending request answered.
    public var pending: String?

    public init(command: Action, run: String, pending: String? = nil) {
        self.command = command
        self.run = run
        self.pending = pending
    }
}
