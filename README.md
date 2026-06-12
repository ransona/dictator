# Dictator

`Dictator` is a push-to-dictate transcription app with OpenAI.

This repo now contains:

- `Dictator.App`: the original Windows tray app.
- `macos/DictatorMac`: a native macOS menu-bar port.

## What it does

- Registers a global hotkey.
- Pops a small always-on-top recording window.
- Records microphone audio locally.
- Sends the captured `.wav` audio to `POST /v1/audio/transcriptions`.
- Optionally runs one chat-based post-processing pass over the full transcript when the dictated text includes an instruction like making an email, summarizing, formatting, or rewriting.
- Uses the final returned text to paste back into the text field that was focused before recording started.
- Stores the OpenAI API key securely for later launches.
- Can auto-start at sign-in.

On macOS, the API key is requested once on first launch and stored in Keychain.

## Controls

### Windows

- `Win+Esc`: start dictation
- `Space`: pause or resume recording
- `Enter`: stop recording, transcribe, and paste
- `Escape`: cancel recording

### macOS

- `Command+D`: start dictation
- `Enter`: stop recording, transcribe, and paste
- `Escape`: cancel recording

## OpenAI API notes

This prototype uses the OpenAI audio transcription endpoint with `model=whisper-1` and `response_format=text`.

Official references:

- [Speech to text guide](https://platform.openai.com/docs/guides/speech-to-text)
- [Audio transcription API reference](https://platform.openai.com/docs/api-reference/audio/createTranscription)

The current OpenAI docs say audio uploads for transcription are limited to `25 MB`, and supported input formats include `wav`, `mp3`, `m4a`, `mp4`, and `webm`.

## Windows build

```powershell
dotnet build .\Dictator.sln
```

## Windows publish

```powershell
.\scripts\Publish-Dictator.ps1
```

That publishes a self-contained single-file build to `.\artifacts\publish\win-x64`.

## Windows install

```powershell
.\scripts\Install-Dictator.ps1 -StartOnLogin
```

The installer script copies the published app into `%LocalAppData%\Programs\Dictator`, creates a Start Menu shortcut, and optionally enables startup at sign-in.

## macOS build

Requires macOS command line tools with `swift`, `codesign`, and `pkgbuild`.

```bash
./scripts/Build-Mac.sh
```

That produces:

```text
artifacts/macos/Dictator.app
```

## macOS install

```bash
./scripts/Install-Mac.sh
```

To also launch at sign-in:

```bash
./scripts/Install-Mac.sh --start-on-login
```

The installer copies the app to `/Applications/Dictator.app`. On first launch, Dictator prompts once for the OpenAI API key and stores it in Keychain. macOS will also ask for microphone permission. If the `Command+D` shortcut or automatic paste is blocked, grant Accessibility permission to Dictator in System Settings.

## macOS package installer

```bash
./scripts/Make-Mac-Pkg.sh
```

That produces:

```text
artifacts/pkg/Dictator-macOS.pkg
```

## Limitations

- Paste-back relies on restoring the previously focused window and sending `Ctrl+V`, so some elevated or protected windows may block it.
- `Win+Esc` can fail to register if another app already owns the hotkey.
- The prototype uses the clipboard to paste the transcript, which temporarily replaces the current clipboard contents.
- On macOS, `Command+D` is detected with a keyboard event monitor and may require Accessibility permission.
- On macOS, paste-back sends `Command+V` and may require Accessibility permission.
- The macOS package is ad-hoc signed for local installation, not notarized for public distribution.
