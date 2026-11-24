# Voiced Input

A background service that types what Voiced on the iPhone hears at the Mac's cursor, such as a terminal prompt. It replaces the receiver that used to live in the Mac app, so the Voiced window no longer needs to be open: once started, the service keeps listening and types every sentence a connected iPhone sends.

## Install

```sh
core/install.sh     # build, register with launchd, start now and at every login
core/uninstall.sh   # stop and unregister
```

`install.sh` builds `core/.build/VoicedInput.app` and installs the launch agent `~/Library/LaunchAgents/com.local.voiced.input.plist`. launchd restarts the service if it exits. Run `install.sh` again after changing the source to rebuild and restart it.

On the first start macOS asks for the Accessibility permission, which posting the paste needs: allow VoicedInput in System Settings → Privacy & Security → Accessibility. The app bundle is signed with a fixed identifier, so the permission survives rebuilds. The service logs connections and errors to `~/Library/Logs/VoicedInput.log`.

On the iPhone, turn on "Send to Mac" in Voiced's General settings. On the same network the phone finds the Mac by itself and sends each sentence once it is committed.

## How it works

- The service advertises `_voiced-input._tcp` over Bonjour under the Mac's name and accepts TCP connections. Each sentence arrives as one JSON object on its own line, `{"text":"..."}`, the format defined by `PhoneInput` in `Shared/VoicedCore`. `PhoneInputMessages.swift` holds a copy of the decoding side so the service builds without WhisperKit; keep the two in step.
- A sentence is pasted rather than typed key by key, so an active Chinese or Japanese input method does not compose it again. The clipboard is put back half a second later unless something else replaced it meanwhile.
- A sentence ending in a Latin letter or ASCII punctuation gets a trailing space; Chinese and Japanese are typed as they are.
- Whether Return follows each sentence is read from `phoneInputReturn` in `~/.voiced/settings.json` for every sentence, which is the "Press Return after each sentence" switch in the Mac app's Settings. `--return` or `--no-return` on the command line overrides it.

## Running by hand

```sh
core/build.sh
core/.build/VoicedInput.app/Contents/MacOS/VoicedInput [--return | --no-return]
```

Run by hand from a terminal, the Accessibility permission is the terminal's. Stop the launch agent first (`core/uninstall.sh`) so the phone does not connect to the other copy.
