# Voice lifecycle validation

Checked on 28 November 2026.

## iPhone model preparation

`VoicePreparationTests` simulates a model SDK that keeps initializing after cancellation. A second voice must wait for the first initializer to actually exit. The cancelled preparation cannot publish a usable result.

`PhoneVoiceMemoryProbe` is an opt-in, physical-device check. It requires the existing downloaded default 8-bit Qwen model and Serena stock voice. It downloads nothing, opens no microphone and plays no audio. It prepares the model, samples the process physical footprint every 50 ms, releases it before another family can start, and saves only numeric memory metrics in the app cache.

Enable `LISTEN_QWEN_MEMORY_PROBE=1`, `LISTEN_TEST_NO_MICROPHONE=1` and `LISTEN_TALKBACK_MUTE=1` in the test host environment, and select only `ListenTests/VoicePreparationTests` and `ListenTests/PhoneVoiceMemoryProbe`. For example, add these values to `EnvironmentVariables` in the generated `.xctestrun`, then run `xcodebuild test-without-building -xctestrun <manifest> -destination 'platform=iOS,id=<your-device>' -only-testing:ListenTests/VoicePreparationTests -only-testing:ListenTests/PhoneVoiceMemoryProbe`. The memory probe stays disabled during ordinary test runs.

On one iPhone 15 Pro Max running iOS 26.6.2, both checks passed. The silent Qwen preparation sampled 2,589,952,600 bytes at peak; after release the process used 306,709,856 bytes. An earlier live-session OS termination occurred at 3,601,022,976 resident bytes with `per-process-limit`. These are different workloads and accounting sources: no percentage speed/memory improvement, acoustic quality score or guarantee for other models/devices is inferred.

The shared voice lifecycle was checked in development build 43. The final source preserves that phone path and also retains shared warmup on machines with 12 GiB or more, so cancelling one caller does not cancel another caller’s warmup. Build-only validation does not establish microphone echo cancellation, interruption quality or full voice-in/voice-out latency. No user recordings, device identifiers or raw diagnostics are included in this repository.

## Live controls

On iPhone, voice selection, voice samples and the waiting sound are behind the Settings button. The start and live screens use the same 44-point control, 24-point horizontal inset and 8-point top inset. The live screen retains its explicit exit action and recording indicator. Mac voice controls remain available.
