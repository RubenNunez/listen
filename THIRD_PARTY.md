# Third parties

Listen's own code is [Apache-2.0](LICENSE). What it builds on keeps its own license. Checked on 16 November 2026; versions from `Package.resolved` and `Cargo.lock`.

## Libraries, compiled into the apps

| What | Used for | License |
|---|---|---|
| [argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift) 1.1 (WhisperKit, SpeakerKit) | Whisper and the speaker model on the device | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Pulled in by argmax-oss-swift | Apache-2.0 |
| [grpc-swift-2](https://github.com/grpc/grpc-swift-2/tree/2.4.4) 2.4.4, [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport/tree/2.12.0) 2.12.0 and [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf/tree/2.5.0) 2.5.0 | Native Swift client for the owner's Listen Router; versions pinned in ios/project.yml | Apache-2.0; retain their LICENSE files |
| [swift-protobuf](https://github.com/apple/swift-protobuf), SwiftNIO and the Apple Swift packages pulled in by the gRPC packages | Protobuf serialization, HTTP/2, networking and TLS support | Apache-2.0 at the package level; retain package notices and the additional component licenses, including BoringSSL's ISC/OpenSSL notices in swift-nio-ssl and swift-crypto |
| [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/tree/v0.2.1) 0.2.1 (MLXAudioTTS, MLXAudioCore), with [mlx-swift](https://github.com/ml-explore/mlx-swift) 0.33.0, [swift-transformers](https://github.com/huggingface/swift-transformers) 1.4.0, [swift-huggingface](https://github.com/huggingface/swift-huggingface) 1.0.1, swift-jinja, yyjson, EventSource and zstd | The local talk-back voice and its model download; version pinned in ios/project.yml | MIT (mlx-audio-swift, mlx-swift, yyjson, EventSource), Apache-2.0 (swift-transformers, swift-huggingface, swift-jinja), BSD (zstd, used under its BSD option); mlx-swift carries MLX, mlx-c, fmt, nlohmann/json and metal-cpp with their own license files |
| [FluidAudio](https://github.com/FluidInference/FluidAudio/tree/v0.18.4) 0.18.4 (commit `e0c6103bc87a88d25276cad491c86e757f58c865`), with the prebuilt `NemoTextProcessing.xcframework` 0.3.4 its manifest links by default (from [text-processing-rs](https://github.com/FluidInference/text-processing-rs), fetched as a checksummed binary when packages are resolved) | Pocket TTS on the device through Core ML; version pinned in ios/project.yml. Listen calls Pocket TTS and Supertonic 3, and fetches the model files itself | Apache-2.0 (both, read from the repositories on 23 November 2026). The resolved xcframework contains no separate license files; FluidAudio's published component notices, including `NemoTextProcessing-LICENSE.md`, are retained in the app's generated ThirdPartyLicenses.txt alongside the package license |
| Apple frameworks (Speech, Foundation Models, SwiftUI, Metal …) | Live hearing, the on-device model, the interface | Part of the OS, under Apple's SDK terms |
| The Rust dependency tree of the Listen Router: 582 crates (tonic, prost, tokio, serde, Tauri 2, rustls, rcgen, mdns-sd, qrcode, clap …) | Router, its desktop app, the command-line client | All permissive (MIT, Apache-2.0, BSD, ISC, Zlib, Unicode-3.0, Unlicense), except 7 crates under MPL-2.0 (`cssparser`, `selectors`, `dtoa-short`, `option-ext`, pulled in by Tauri). MPL-2.0 is file-level copyleft: those files stay MPL; nothing in Listen has to change |

Reproduce the Rust list: `cd backend && cargo metadata --format-version 1 --locked` and read each package's `license`.

The gRPC rows were checked against the resolved source packages on 20 November 2026.
The FluidAudio row was checked against the resolved package (revision as above) on 23 November 2026.
The complete resolved Swift dependency list is in the generated Xcode workspace's
`xcshareddata/swiftpm/Package.resolved`. Additional notices are in each dependency's
`NOTICE`, `NOTICE.txt` and `LICENSE*` files, including `license/` component files.
Carry the applicable texts into distributed app artifacts; the source links above
do not replace those distribution notices. App artifact limits are documented
in [LIMITATIONS.md](docs/LIMITATIONS.md).

## Models, downloaded at first use (not in this repository)

| Model | Used for | License | What it asks |
|---|---|---|---|
| Whisper `small`, Core ML ([argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml)) | Hearing again, stage 2 | MIT | Keep the notice |
| Speaker models ([argmaxinc/speakerkit-coreml](https://huggingface.co/argmaxinc/speakerkit-coreml)) | Telling voices apart | **CC BY 4.0** | Name Argmax, Inc. and the license wherever the models are passed on (done in [`NOTICE`](NOTICE)) |
| Swiss German Whisper ([gcoli/whisper-large-v3-turbo-swiss-german-mit](https://huggingface.co/gcoli/whisper-large-v3-turbo-swiss-german-mit)) | The third listener, converted on your Mac by `ios/Tools/swiss-german/convert.sh` | MIT | Keep the notice |
| Qwen3-TTS 0.6B CustomVoice, MLX conversions ([mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit), `-8bit`, `-bf16`; original by [Qwen](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice)) | The local talk-back voice; downloaded only when the user asks for it in a voice system's settings | Apache-2.0 (checked on the model pages, 20 November 2026) | Keep the notice |
| Pocket TTS, German 6-layer pack, Core ML conversion ([FluidInference/pocket-tts-coreml](https://huggingface.co/FluidInference/pocket-tts-coreml), folder `v2.1/german`, pinned to revision `c2e998e269e4d4b51f74061faddb8450cd8f9a9a`; original model by [Kyutai](https://huggingface.co/kyutai/pocket-tts)) with the voices alba, cosette, fantine and eponine | A second local talk-back voice; 0.4 GB, downloaded only when the user asks for it, each file checked against the size and hash in `PocketVoiceFiles` | **CC BY 4.0**, inherited from Kyutai's model (model page, 23 November 2026). The page states no separate terms for the voice files | Name Kyutai and the license wherever the model is passed on (done in [`NOTICE`](NOTICE)) |
| Supertonic 3, fixed Int4 v2 Core ML conversion ([FluidInference/supertonic-3-coreml](https://huggingface.co/FluidInference/supertonic-3-coreml/tree/2b5b939dfa1bca362c5212dcafeb8aadde90b1bc), original [Supertone/supertonic-3](https://huggingface.co/Supertone/supertonic-3)), stock female F2 | Experimental local talk-back option; 169,051,706 bytes, eight denoising steps, downloaded only on request; every file SHA-256 pinned in `SupertonicVoiceFiles` | **BigScience Open RAIL-M**, dated August 18, 2022 (repository LICENSE read 24 November 2026). FluidAudio code remains Apache-2.0 | Model use/distribution retain paragraph 5 and Attachment A restrictions; full license bundled in `ios/Listen/Resources/Supertonic3License.txt`, exposed in the app and named in NOTICE. Weights are not Apache-2.0 and are not committed. |
| Not integrated: Phonon 40M-DE | Named in the voice menu as unavailable; nothing of it is downloaded, bundled or run | Gated, non-commercial, as recorded in the plan of 23 November 2026; not read again for this table | No mirror or other way around the gate. It stays out until its terms allow it and someone has run it |
| Candidate, not integrated: Swiss German Parakeet ([Flurin17/parakeet-tdt-0.6b-v3-swiss-german](https://huggingface.co/Flurin17/parakeet-tdt-0.6b-v3-swiss-german)) | Work package B4 | **CC BY-NC 4.0** | Non-commercial only. Never bundle it; if it comes, the user downloads it and its terms bind the user |

## Test material, kept outside the repository

Recordings stay in the ignored `runs/` folder and are never committed.

| What | License | Use |
|---|---|---|
| [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) | CC BY 4.0 | Speaker measurements |
| [VoxConverse](https://mm.kaist.ac.kr/datasets/voxconverse/) | See its page | Speaker error (DER) offline |
| [WikiCon – WikiTV-Interview – Dreisam](https://commons.wikimedia.org/wiki/File:WikiCon_-_WikiTV-Interview_-_Dreisam.webm) | CC BY-SA 3.0 | German test recording |

Everything in `fixtures/`, `ios/Tools/scripted/*.txt` and the figures drawn from scripted runs is written for this project and falls under Apache-2.0.

## Images

The speaker animals in the app's asset catalogue were generated with an image model; see [artwork provenance](docs/ARTWORK.md). As far as anyone holds rights in them, they are published under Apache-2.0 with the rest of the repository.

## Sounds

| What | Used for | License | What it asks |
|---|---|---|---|
| "Local Forecast – Slower" by Kevin MacLeod ([incompetech.com](https://incompetech.com)) | The "Elevator music" waiting sound, a joke option next to the heartbeat. `ios/Listen/Resources/ElevatorMusic.m4a` holds its first 20 seconds, changed: mono, 24 kHz, faded in and out; the app also plays it quieter | **CC BY 4.0** ([creativecommons.org/licenses/by/4.0](https://creativecommons.org/licenses/by/4.0/)) | Name the title, Kevin MacLeod, incompetech.com and the license, and say that it was changed (done in [`NOTICE`](NOTICE) and under the choice in the waiting-sound menu) |

The heartbeat waiting sound is computed in `ThinkingCue.swift` and falls under Apache-2.0.

## Services you connect yourself

Listen has no server and no account of its own. When you connect a service, your account and its terms apply between you and that provider:

ChatGPT sign-in where supported by the connected account, OpenAI, Anthropic, Google Gemini, DeepSeek and OpenRouter (your API keys), Jev by TypeSafe (optional structured decisions using your API key; conversation text, limited topic context and candidate cards when enabled), ElevenLabs (account connection only; voice output is unavailable), GitHub (read-only, repositories you choose), Hugging Face (model download).

Listen does not issue inference entitlements or include provider usage. Official sign-in, a valid API key and a subscription are distinct; features, limits and charges depend on the connected account. The source license does not change those provider terms.

The Listen Router runs the official `claude` and `codex` command-line tools that **you** installed and signed in to, on **your** machine, for **your** apps. It never reads their credentials and serves only its owner. The personal router serves only its owner; these integrations do not provide pooled account access for other users. See [architecture](docs/ARCHITECTURE.md).
