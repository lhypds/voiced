# voiced service

A background service that delivers what Voiced on the iPhone hears: typed at the computer's cursor, such as a terminal prompt, or carried out by Claude Code. The Voiced window does not need to be open: once started, the service keeps listening and handles every sentence a connected iPhone sends. It is written in Rust and runs on macOS and Windows. It does not use `core/VoicedCore`, the Swift library the apps share.

## macOS

```sh
voiced service start     # build if needed, register with launchd, start now and at every login
voiced service restart   # rebuild and restart, after changing the source
voiced service stop      # stop; it no longer starts at login
voiced service status
```

`voiced service build` (or `service/build.sh`) builds a single binary at `service/.build/voiced` and signs it with the fixed identifier `com.local.voiced.input`, so the Accessibility permission survives rebuilds. The service is the launch agent `~/Library/LaunchAgents/com.local.voiced.input.plist`; launchd restarts it if it exits. It logs connections and errors to `~/Library/Logs/VoicedInput.log`.

On the first start macOS asks for the Accessibility permission, which posting the paste needs: allow `voiced` in System Settings → Privacy & Security → Accessibility. Run by hand from a terminal (`service/.build/voiced`, after `voiced service stop` so the phone does not connect to the other copy), the permission is the terminal's.

While the service runs, a black-and-white waveform icon sits in the menu bar. Its menu shows the service's status: the name it is advertised under (the host name), iPhones connected, sentences delivered, and the Accessibility permission, with a link to allow it when missing.

## Windows

From the repository root:

```bat
setup.bat       :: installs the C++ build tools, Rust and, if you want it, Claude Code (with winget)
install.bat     :: installs the voiced command, then builds the service and starts it now and at every login
uninstall.bat   :: stops the service and removes it and the voiced command; the log is kept
```

The `voiced` command on Windows has the same commands as on macOS, for the service alone, the only part of Voiced that runs there (`voiced.ps1` at the repository root, run through `voiced.cmd`):

```bat
voiced service [build|start|stop|restart|status]   :: leave out the action to pick it with the arrow keys
voiced restart                                      :: the same, named the other way round
voiced status
voiced                                              :: the help
```

The service is built in `service\target\release` and runs as a copy in `%LOCALAPPDATA%\voiced`, so a build never has to replace the file of the running service; `voiced service restart` rebuilds, then puts the new copy in place and restarts it. `install.bat` puts the command on PATH through `%LOCALAPPDATA%\voiced\bin`; open a new window after installing to use it.

- `install.bat` allows voiced through Windows Firewall on private networks (it asks for administrator approval), and `uninstall.bat` removes that rule. Without the rule, Windows Firewall asks the first time whether voiced may accept connections: allow it on private networks. The phone needs both the TCP port and Bonjour (UDP 5353).
- Bonjour is done by voiced itself (the `mdns-sd` crate); no Apple Bonjour service is needed.
- Typing needs no permission. Windows does not let it type into an app running as administrator unless voiced runs as administrator too.
- `claude` is looked up on the PATH and in `%USERPROFILE%\.local\bin`, where the native installer puts it; an npm install's `claude.cmd` works too.
- Run mode opens a console window per run in place of Terminal; a later run in the same folder is followed in the same window, which closes three seconds after the last one.
- The service has no window: its icon sits in the notification area, and Quit in the icon's menu stops it until the next login. It starts at login from the `voiced` value under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
- The log is `%LOCALAPPDATA%\voiced\voiced.log`; run logs are kept in `%LOCALAPPDATA%\voiced\runs` while a run is followed.

The Windows build has not been compiled yet on a Windows machine; expect to fix a few compile errors the first time.

## On the iPhone

Turn on "Send to Machine" in Voiced's General settings and pick its mode: Type (typed at the cursor), Type and Return (typed, then Return), or Run (carried out by Claude Code in the "Claude Code folder" set beneath the mode, a path on the computer where `~` is the home folder). Then hold the microphone while speaking: what is said before letting go is sent, whether or not a recording is running. A tap only starts or stops recording and sends nothing. On the same network the phone finds the computer by itself and sends each sentence once it is committed.

## How it works

- The service advertises `_voiced-input._tcp` over Bonjour under the computer's host name (without `.local`), with a TXT record giving its system (`os`) and local IPv4 addresses (`ip`) for the phone's list of machines, and accepts TCP connections. Each sentence arrives as one JSON object on its own line, `{"text":"...","mode":"type"}`, where `mode` is `type`, `typeAndReturn` or `claude` (missing or unknown: `type`) and a `claude` sentence also carries `folder` (missing or empty: the home folder), `line` (the phone's id for the transcript line) and `history`. The format is defined by `PhoneInput` and `ClaudeRunEvents` in `core/VoicedCore`; `src/protocol.rs` is the service's side of it. Keep the two in step.
- A sentence is pasted rather than typed key by key (Command-V, or Ctrl+V on Windows), so an active Chinese or Japanese input method does not compose it again. The clipboard's text is put back half a second later unless something else replaced it meanwhile; an image or file on the clipboard is not kept.
- A sentence ending in a Latin letter or ASCII punctuation gets a trailing space; Chinese and Japanese are typed as they are.
- What happens to a sentence, and the Claude Code folder, are chosen on the phone and sent with it, so the service keeps neither. A folder that does not exist drops the sentence and shows why in the icon's menu.
- In Run mode the service runs Claude Code itself, one `claude -p` per sentence: events on stdout (`--output-format stream-json --include-partial-messages`), the prompt and permission answers on stdin (`--input-format stream-json --permission-prompt-tool stdio`). Runs go one at a time; a later sentence for the same folder continues the conversation (`--continue`), one for another folder starts a new one. The sentence's `history`, the earlier sentences of the same record that were run and what Claude concluded each time, goes before it in an `<earlier_conversation>` block, the latest 20, so a follow-up makes sense even after a restart or in a new conversation. On macOS `claude` and the PATH come from the user's login shell, since launchd starts the service with a bare PATH.
- From the events the service builds a transcript per run: Claude's text as it streams, each tool call with its result, and how the run ended. It sends it to every connected phone down the same connection, one JSON event per line: `snapshot` of the last 20 runs whenever a phone connects, then `run`, `item`, `delta` and `remove`. The phone shows each run under the line it was sent from, and sends back `{"command":"stop"|"allow"|"deny","run":…,"pending":…}`.
- Every event also goes, as it came, to `<cache>/voiced/runs/<run>.jsonl` (`~/Library/Caches` on macOS, `%LOCALAPPDATA%` on Windows), which a terminal window follows (`voiced --claude-follow`): a header with the folder, model and permission mode, the sentence, Claude's text as it is written, each tool call (`▸ Bash  ls -la`) with its result, a note while a tool waits for the iPhone, and how long it took. The first run opens the window; later ones are followed in it once the one before is over; three seconds after the last it closes by itself. On macOS Terminal is driven through AppleScript, so Run mode does not need the Accessibility permission.
- The permission mode decides what Claude may do without asking: `acceptEdits` by default. Allow rules in your Claude settings apply as in the terminal; any other tool comes to the phone, whose run card asks to allow or deny it, and the run waits until it is answered or stopped. AskUserQuestion is refused with a note to make a reasonable choice, since the phone cannot answer questions yet. Change the mode with the environment variable `VOICED_PERMISSION_MODE`, or on macOS with `defaults write com.local.voiced.input claudePermissionMode <mode>` (`default`, `acceptEdits`, `auto`, `plan`, `dontAsk` or `bypassPermissions`); it applies from the next sentence.

## Layout

| File | What it does |
| --- | --- |
| `src/main.rs` | Arguments, and the core thread that handles every event in order |
| `src/protocol.rs` | The wire format |
| `src/listener.rs` | TCP connections and the Bonjour advertisement |
| `src/typer.rs` | Clipboard and the paste shortcut (CGEvent on macOS, SendInput on Windows) |
| `src/runner.rs` | `claude -p` per sentence, and the transcript the phone gets |
| `src/shell.rs` | Where `claude` is |
| `src/transcript.rs` | `--claude-follow`: prints a run in its window |
| `src/terminal/` | Terminal.app over AppleScript (macOS), console windows (Windows) |
| `src/tray.rs` | The icon and its status menu |

`cargo test` runs the protocol and prompt tests.
