# Voiced Input

A background service that types what Voiced on the iPhone hears at the Mac's cursor, such as a terminal prompt. It replaces the receiver that used to live in the Mac app, so the Voiced window no longer needs to be open: once started, the service keeps listening and types every sentence a connected iPhone sends.

The package at the root of this folder is the service. `VoicedCore/` is a separate package, the library shared by the Mac and iPhone apps; the service does not use it.

## Install

```sh
core/install.sh     # build, register with launchd, start now and at every login
core/uninstall.sh   # stop and unregister (same as voiced stop)
```

`install.sh` builds the service, a single binary at `core/.build/voiced`, and starts it through `voiced`. Run it again after changing the source to rebuild and restart it.

## voiced

`voiced`, at the repository root, controls the service; with no argument it opens the Voiced window. Run it as `./voiced`, or install it as a system command with the root `./install.sh` (removed by `./uninstall.sh`).

```sh
voiced              # open the Voiced window
voiced start        # start the service, and at every login
voiced stop         # stop it; it no longer starts at login
voiced restart
voiced start ui     # the service and the Voiced window
voiced stop ui      # quit Voiced and stop the service
voiced restart ui
voiced status
```

The service is the launch agent `~/Library/LaunchAgents/com.local.voiced.input.plist`; launchd restarts it if it exits. `voiced start` writes the plist and loads it, `voiced stop` unloads and removes it.

While the service runs, a black-and-white waveform icon sits at the right of the menu bar. Clicking it opens a card with the service's status (iPhones connected, sentences typed, the Accessibility permission) and a "Press Return after each sentence" switch, and buttons to open Voiced and to stop the service, the same as `voiced stop`. The icon first appears among the system icons at the right, so a menu bar manager such as Hidden Bar or a full menu bar on a Mac with a notch does not hide it; ⌘-drag it elsewhere and macOS keeps it there.

On the first start macOS asks for the Accessibility permission, which posting the paste needs: allow `voiced` in System Settings → Privacy & Security → Accessibility. The binary is signed with a fixed identifier, so the permission survives rebuilds. The service logs connections and errors to `~/Library/Logs/VoicedInput.log`.

On the iPhone, turn on "Send to Mac" in Voiced's General settings. On the same network the phone finds the Mac by itself and sends each sentence once it is committed.

## How it works

- The service advertises `_voiced-input._tcp` over Bonjour under the Mac's name and accepts TCP connections. Each sentence arrives as one JSON object on its own line, `{"text":"..."}`, the format defined by `PhoneInput` in `core/VoicedCore`. `PhoneInputMessages.swift` holds a copy of the decoding side so the service builds without WhisperKit; keep the two in step.
- A sentence is pasted rather than typed key by key, so an active Chinese or Japanese input method does not compose it again. The clipboard is put back half a second later unless something else replaced it meanwhile.
- A sentence ending in a Latin letter or ASCII punctuation gets a trailing space; Chinese and Japanese are typed as they are.
- Whether Return follows each sentence is the "Press Return after each sentence" switch in the menu bar card, kept in the service's own defaults (`com.local.voiced.input`), not in `~/.voiced/settings.json`, which the Voiced app rewrites whole. The first start takes over the value the Mac app's Settings used to store there. `--return` or `--no-return` on the command line overrides it.

## Running by hand

```sh
core/build.sh
core/.build/voiced [--return | --no-return]
```

Run by hand from a terminal, the Accessibility permission is the terminal's. Stop the launch agent first (`voiced stop`) so the phone does not connect to the other copy.
