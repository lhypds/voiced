import Foundation

/// What the voiced service tells the phone about the Claude Code runs that Run-mode sentences
/// start, and what the phone asks of them; modelled on ~/code/tm's run events. A copy of
/// core/VoicedCore/Sources/VoicedCore/PhoneInput/ClaudeRunEvents.swift, so the service builds
/// without WhisperKit; keep the two in step.
///
/// The Mac sends events down the same connection the phone sends sentences up, one JSON object
/// per line: a `snapshot` of every run it keeps whenever the phone connects, then `run` for a
/// run's state, `item` for a transcript item added or replaced at an index, `delta` for text
/// appended to one, and `remove` for a run it no longer keeps.

/// One run of Claude Code for one sentence.
struct ClaudeRun: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        /// Waiting for the run before it to finish.
        case queued
        case running
        case done
        case failed
        case stopped

        var isGoing: Bool { self == .queued || self == .running }
    }

    /// A tool Claude wants to use and may not without asking: the phone allows or denies it.
    struct Pending: Codable, Equatable, Sendable {
        var id: String
        var tool: String
        var summary: String

        init(id: String, tool: String, summary: String) {
            self.id = id
            self.tool = tool
            self.summary = summary
        }
    }

    var id: String
    /// The transcript line the sentence was, on the phone that sent it; nil from older phones.
    var line: String?
    var text: String
    var folder: String
    var state: State
    /// Seconds since 1970.
    var startedAt: Double?
    var endedAt: Double?
    var pending: Pending?
    /// Left out of `run` events, which carry only the state.
    var items: [ClaudeRunItem]?

    init(id: String, line: String?, text: String, folder: String, state: State, startedAt: Double? = nil,
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
    var activeTool: ClaudeRunItem? {
        guard state == .running, let last = items?.last, last.kind == .tool, last.done != true else { return nil }
        return last
    }
}

/// One entry of a run's transcript.
struct ClaudeRunItem: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Claude's text, written as it streams.
        case text
        /// A tool call, `done` once its result is in.
        case tool
        /// How the run ended: `durationMs`, `turns`, and `isError` with the reason as `text`.
        case result
        /// Something went wrong outside Claude, such as claude not starting.
        case error
    }

    var kind: Kind
    var text: String?
    var name: String?
    var summary: String?
    var done: Bool?
    var isError: Bool?
    var result: String?
    var durationMs: Double?
    var turns: Int?

    init(kind: Kind, text: String? = nil, name: String? = nil, summary: String? = nil, done: Bool? = nil,
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
struct ClaudeRunEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case snapshot
        case run
        case item
        case delta
        case remove
    }

    var type: Kind
    /// `snapshot`: every run, with its items.
    var runs: [ClaudeRun]?
    /// `run`: the run's state, without items.
    var run: ClaudeRun?
    /// `item`, `delta`, `remove`: which run.
    var id: String?
    /// `item`, `delta`: the item's index.
    var i: Int?
    var item: ClaudeRunItem?
    var text: String?

    init(type: Kind, runs: [ClaudeRun]? = nil, run: ClaudeRun? = nil, id: String? = nil, i: Int? = nil,
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
    func apply(to runs: inout [String: ClaudeRun]) {
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
struct ClaudeRunCommand: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case stop
        case allow
        case deny
    }

    var command: Action
    var run: String
    /// `allow`, `deny`: the pending request answered.
    var pending: String?

    init(command: Action, run: String, pending: String? = nil) {
        self.command = command
        self.run = run
        self.pending = pending
    }
}
