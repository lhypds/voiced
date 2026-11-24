# voiced

A background service that types what Voiced on the iPhone hears at the Mac's cursor, such as a terminal prompt. It replaces the receiver that used to live in the Mac app, so the Voiced window no longer needs to be open: once started, the service keeps listening and types every sentence a connected iPhone sends.

The package at the root of this folder is the service. `VoicedCore/` is a separate package, the library shared by the Mac and iPhone apps; the service does not use it.

## Install

```sh
core/install.sh     # build, register with launchd, start now and at every login
core/uninstall.sh   # stop and unregister (same as voiced stop)
```

`install.sh` builds the service, a single binary at `core/.build/voiced`, and starts it through `voiced`. Run it again after changing the source to rebuild and restart it.

## voiced

`voiced`, at the repository root, starts and controls the service and starts the Voiced apps. Run it as `./voiced`, or install it as a system command with the root `./install.sh` (removed by `./uninstall.sh`).

```sh
voiced              # start the service, and at every login (folder: home)
voiced .            # the same, with the current folder
voiced ~/abc        # the same, with that folder
voiced stop         # stop it; it no longer starts at login
voiced restart [folder]
voiced start        # ask whether to start Voiced on macOS or iOS
voiced start macos  # open the Mac app
voiced start ios    # pick a connected iPhone or a simulator and run the app there
voiced stop macos   # quit the Mac app
voiced status
voiced help
```

The service is the launch agent `~/Library/LaunchAgents/com.local.voiced.input.plist`; launchd restarts it if it exits. `voiced` writes the plist and loads it, `voiced stop` unloads and removes it.

While the service runs, a black-and-white waveform icon sits at the right of the menu bar. Clicking it opens a card with the service's status (iPhones connected, sentences typed, the Accessibility permission), the folder Claude Code runs in, and buttons to open Voiced and to stop the service, the same as `voiced stop`. The icon first appears among the system icons at the right, so a menu bar manager such as Hidden Bar or a full menu bar on a Mac with a notch does not hide it; ⌘-drag it elsewhere and macOS keeps it there.

On the first start macOS asks for the Accessibility permission, which posting the paste needs: allow `voiced` in System Settings → Privacy & Security → Accessibility. The binary is signed with a fixed identifier, so the permission survives rebuilds. The service logs connections and errors to `~/Library/Logs/VoicedInput.log`.

On the iPhone, turn on "Send to Mac" in Voiced's General settings and pick its mode: Type (typed at the cursor, such as a terminal prompt), Type and Return (typed, then Return), or Run (carried out by Claude Code, opened in Terminal in the service's folder). Then hold the microphone while speaking: what is said before letting go is sent to the Mac, whether or not a recording is running. A tap only starts or stops recording and sends nothing. On the same network the phone finds the Mac by itself and sends each sentence once it is committed.

## How it works

- The service advertises `_voiced-input._tcp` over Bonjour under the Mac's name and accepts TCP connections. Each sentence arrives as one JSON object on its own line, `{"text":"...","mode":"type"}`, where `mode` is `type`, `typeAndReturn` or `claude` (missing or unknown: `type`), the format defined by `PhoneInput` in `core/VoicedCore`. `PhoneInputMessages.swift` holds a copy of the decoding side so the service builds without WhisperKit; keep the two in step.
- A sentence is pasted rather than typed key by key, so an active Chinese or Japanese input method does not compose it again. The clipboard is put back half a second later unless something else replaced it meanwhile.
- A sentence ending in a Latin letter or ASCII punctuation gets a trailing space; Chinese and Japanese are typed as they are.
- What happens to a sentence is chosen on the phone and sent with it, so the service has no switch for it. The Claude Code folder is kept in the service's own defaults (`com.local.voiced.input`), not in `~/.voiced/settings.json`, which the Voiced app rewrites whole; `voiced <folder>` sets it.
- In Run mode Claude Code runs non-interactively (`claude -p`), as the Agent SDK does in ~/code/tm, so it never stops to ask whether to trust the folder. The first sentence opens a Terminal window, changes to the folder and runs `claude -p` with the sentence as its prompt; each later sentence runs `claude -p --continue` in that window once the run before it has finished, carrying on the same conversation. A new window, and a new conversation, start when that one was closed or the folder changed. Commands go in through Terminal's AppleScript, so Run mode does not need the Accessibility permission.
- A run cannot ask for permission, so the permission mode decides what Claude may do: `acceptEdits` by default (file edits are allowed; shell commands and other tools only when your Claude settings allow them). Change it with `defaults write com.local.voiced.input claudePermissionMode <mode>` (`default`, `acceptEdits`, `auto`, `plan`, `dontAsk` or `bypassPermissions`, which allows everything); it applies from the next sentence.

## Running by hand

```sh
core/build.sh
core/.build/voiced
```

Run by hand from a terminal, the Accessibility permission is the terminal's. Stop the launch agent first (`voiced stop`) so the phone does not connect to the other copy.
