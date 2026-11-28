# Listen

**Your voice. Your models. Your rules.**

Listen is a free, open-source voice assistant for Mac and iPhone. Speech recognition
and speech synthesis run on your device. You choose the connected models that do
the reasoning, and the tools they may use.

The goal is a sovereign alternative to closed voice assistants: software you can
inspect, run, modify and share, without a Listen account or a Listen-operated
inference service. Listen's own code is licensed under [Apache-2.0](LICENSE).

**Early source alpha.** The native Mac development build is the primary evaluation
environment. iPhone builds, latency, turn handling and voice naturalness are still
being refined. Build from source; a signed public app or TestFlight download is
not included in this release.

## Local audio, your choice of intelligence

```text
Microphone → on-device recognition → your selected model(s) → on-device voice
                                      ↓
                              tools you explicitly enable
```

- **Voice in:** native on-device speech recognition, with optional local recognition models.
- **Voice out:** downloadable local voice models, including Pocket TTS, Qwen TTS
  and experimental Supertonic voices. Models are selected separately from the model
  that reasons about your request.
- **Reasoning:** connect your own supported model accounts or APIs. Optional routing
  can select faster or stronger models and coordinate separate tasks.
- **Actions:** native MCP connections with explicit tool bindings, confirmation and
  owner-controlled standing permissions. Tool results are reported as observations.
- **Context:** topics, instructions and locally saved conversation history that you control.
- **Visibility:** inspect model/tool activity in the recording timeline.

Here, **local audio** means the speech recognition and synthesis path runs on your
device after required assets are downloaded. If you select a cloud reasoning model,
the relevant transcript and context go to that provider. Provider charges, account
access and third-party model licenses are separate from Listen's free source code.

Model choice currently uses the supported connections and optional personal router.
Loading arbitrary reasoning-model weights directly into the native app is not a
general-purpose feature of this alpha. Local voice model downloads are supported.

## Start on a Mac

Developed on Apple Silicon with Xcode 27.2, its Metal Toolchain component, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Local voice models also require
compatible hardware, storage and their first download.

```sh
ios/Tools/run-mac.sh
```

The helper builds and opens the Mac Catalyst app. It starts no conversation for you.
In the app:

1. Add a supported model connection in Settings, using your own account or key.
2. Choose or create a topic and select its Voice assistant system.
3. Select and download a local voice model.
4. Start **Talk with Listen** and grant microphone access when requested.
5. Add MCP tools only if you want device/service actions, then choose their permissions.

The application requests microphone access only through native OS controls. The
public source uses microphone input; it does not capture another app's screen or
audio. Camera access is limited to user-initiated setup QR scanning, with no image
upload or vision-model input.

For an iPhone build, open the generated Xcode project and use your own Apple signing
team and bundle identifier. See [Setup](docs/SETUP.md).

## Develop and contribute

Native Swift/SwiftUI client, local audio engines, and an optional Rust router.
Contributions, reproducible measurements and constructive feedback are welcome.

- [Architecture](docs/ARCHITECTURE.md)
- [Spoken tool results](docs/TOOL_RESULTS.md)
- [Data and privacy](docs/PRIVACY.md)
- [Current limits](docs/LIMITATIONS.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [Third-party software and model licenses](THIRD_PARTY.md)

```sh
cd ios
Tools/generate-project.sh
xcodebuild test -project Listen.xcodeproj -scheme Listen \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:ListenTests CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Use the scheme's silent test settings. Real-provider and speech-model probes are
explicitly gated; most tests use synthetic transports and model doubles. Tests do
not establish subjective voice quality or performance on every device.

For the optional headless router:

```sh
cd backend
cargo test --locked --workspace --exclude listen-router-app
```

Use Listen openly and with participants' agreement. It is a personal assistant,
without voice impersonation or automatic participation in external calls.

## License and acknowledgements

Listen's code is free to use, modify and redistribute under Apache-2.0. Retain the
[LICENSE](LICENSE), [NOTICE](NOTICE) and applicable [third-party notices](THIRD_PARTY.md).
Downloaded models retain their own licenses; experimental Supertonic weights, for
example, do not become Apache-2.0 because the app is.

Built with AI-assisted development. Contributions remain the responsibility of
their human authors. Listen is an independent project with no provider endorsement.
