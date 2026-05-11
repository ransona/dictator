# Dictator

`Dictator` is a Windows tray app prototype for push-to-dictate transcription with OpenAI.

## What it does

- Registers `Win+Esc` as a global hotkey.
- Pops a small always-on-top recording window.
- Records microphone audio locally.
- Sends the captured `.wav` audio to `POST /v1/audio/transcriptions`.
- Optionally runs one chat-based post-processing pass over the full transcript when the dictated text includes an instruction like making an email, summarizing, formatting, or rewriting.
- Uses the final returned text to paste back into the text field that was focused before recording started.
- Stores the OpenAI API key in `HKCU\Software\Dictator`.
- Can auto-start at sign-in through the current-user `Run` registry key.

## Controls

- `Win+Esc`: start dictation
- `Space`: pause or resume recording
- `Enter`: stop recording, transcribe, and paste
- `Escape`: cancel recording

## OpenAI API notes

This prototype uses the OpenAI audio transcription endpoint with `model=whisper-1` and `response_format=text`.

Official references:

- [Speech to text guide](https://platform.openai.com/docs/guides/speech-to-text)
- [Audio transcription API reference](https://platform.openai.com/docs/api-reference/audio/createTranscription)

The current OpenAI docs say audio uploads for transcription are limited to `25 MB`, and supported input formats include `wav`, `mp3`, `m4a`, `mp4`, and `webm`.

## Build

```powershell
dotnet build .\Dictator.sln
```

## Publish

```powershell
.\scripts\Publish-Dictator.ps1
```

That publishes a self-contained single-file build to `.\artifacts\publish\win-x64`.

## Install

```powershell
.\scripts\Install-Dictator.ps1 -StartOnLogin
```

The installer script copies the published app into `%LocalAppData%\Programs\Dictator`, creates a Start Menu shortcut, and optionally enables startup at sign-in.

## Limitations

- Paste-back relies on restoring the previously focused window and sending `Ctrl+V`, so some elevated or protected windows may block it.
- `Win+Esc` can fail to register if another app already owns the hotkey.
- The prototype uses the clipboard to paste the transcript, which temporarily replaces the current clipboard contents.
