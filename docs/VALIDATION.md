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

## Diagnostic overhead

Debug voice timing records now use a serial background writer. Admission is bounded to 1 MiB of JSON payload and 1,024 pending records. Overflow and write failures are reported as numeric `voice_trace_dropped` events once storage is writable; a benchmark containing such events is incomplete. This is best-effort diagnostic output: an abrupt process exit can lose pending records. It does not replace the session recorder.

On memory-constrained devices, `voice_prepare` separates queue wait (`queue_wait_s`), old-family release (`release_s`) and model preparation (`prepare_s`). The event describes preparation, not audible output. `voice_audio` retains the distinct first-buffer and underrun measurements.

The standalone `ios/Tools/bench-voice-trace.swift` compiles with the actual writer and opens no app, microphone, speaker, model or network connection. It checks 800 concurrent unique events plus an existing record, explicit overflow accounting, and recovery after a write failure. Its timing loop compares the previous synchronous append with background admission and completed writes separately.

One macOS run, nine samples of 100 pre-serialized synthetic events each: median synchronous caller time 1.925 ms; new caller admission 0.031 ms; new complete-write time 2.093 ms. Total disk work has not become faster. The change moves that work off the calling executor and serializes concurrent writes. These measurements establish neither phone timing nor end-to-end voice latency.

## Conversation reliability and local MCP

Checked on 28 November 2026 with eight targeted physical-iPhone checks: four cover bounded quoted memory checkpoints, topic isolation, supported utterance-language selection and local endpoint validation; four cover echo fragments and real interruption/correction behavior. All eight passed without physical microphone input or speaker playback. They do not establish subjective accent quality or end-to-end latency.

The local checkpoint is saved before requesting an optional model summary. It contains bounded, JSON-quoted user statements, explicitly labelled as unverified quotations rather than completed actions; assistant claims are excluded. A failed summary leaves the checkpoint intact.

Supertonic output language is detected per utterance using on-device NaturalLanguage, restricted to the SDK's supported codes. Short/uncertain fragments retain the topic language. This does not change the recognition language and does not add languages to Pocket or Qwen.

HTTP MCP endpoints can use private IPv4/IPv6 addresses, loopback, unqualified local hostnames and `.local` names. Public HTTP destinations, URL credentials, queries and fragments remain rejected. Redirects remain disabled. The app already declares local-network usage and `NSAllowsLocalNetworking`; Apple's current behavior is documented in [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking), verified 28 November 2026. The connection editor explains that local HTTP sends tool data and server tokens without transport encryption.

`NativeLocalMCPSetup` is separate owner-authorized device maintenance, disabled in ordinary tests. It requires an explicit `LISTEN_PROVISION_LOCAL_MCP=1` environment flag and a protected app-cache setup file. It performs discovery, stores the server token through the device's credential backend, and binds capabilities to the selected voice topic. It never calls an action or adds standing grants, and removes the supplied cache file on exit. Real setup files and credentials do not belong in this repository.

The live conversation settings show configured answer-model roles and native tool availability. These are configuration facts, not a claim that every model is called on every turn. `NativeVoiceRoutingSetup` is a separately opted-in owner setup check: it sends only tiny synthetic connection requests through the existing adapters, verifies a typed routing response, and enables only the model slots it checked. Single connection timings are not comparative model benchmarks or a voice-quality score.

Decision, 28 November 2026: local-network MCP access belongs in the generic Listen client. Home-automation server implementations, deployment settings, device lists and client credentials remain separate from this public source tree.

## Long-running tools and spoken clarification

Checked on 28 November 2026. MCP discovery keeps a 25-second request timeout and
30-second total resource deadline. Tool execution uses separate 180-second request
and resource deadlines. These bounds accommodate tools that legitimately outlive
discovery; they do not accelerate the server. A dispatched action is never
retried automatically when its result is unknown. The live view includes pending
tool execution in its waiting indicator and optional waiting sound.

Three targeted Foundation-only macOS checks passed using the exact client, tool
feedback and conversation sources, with the corresponding app test methods copied
unchanged into a temporary headless harness. They verify separate discovery/call
request timeouts and one dispatch, bounded ambiguity clarification, and preservation
of raw-payload/partial-failure safeguards. The synthetic exchange makes no network
request or device action. This does not measure a real HTTP deadline, voice latency
or subjective speech quality.

A short plain-language ambiguity error receives a native clarification instead of
only a generic error. Arbitrary JSON, multiline payloads and unsupported errors
retain the safe fallback and their separate diagnostic detail. No raw service text
is added to speech. The model instructions encourage context- and lookup-supported
name/title guesses while preserving explicit language constraints and device-action
scope. Normal speech describes user outcomes; internal providers and tool identifiers
are reserved for explicit diagnostics or a necessary owner decision. Prompt guidance
is not evidence that a live request resolved correctly.

Recommendation intent is separate from playback intent: inspiration alone asks for
brief context-based suggestions or one useful preference question. An explicit
play-anything request delegates title selection within stated constraints, while
identity/availability checks and native action permissions still apply. This is
model guidance; the full recommendation-to-playback flow remains a live validation
item and depends on the tools actually bound in that installation.

## Reported playback alternatives

Listen recognizes an optional application-level result envelope; this is not a
standard MCP result field. An `alternative_available` outcome can carry
`playback_started: false`, `requires_language_confirmation: true` and a bounded
`available_alternatives` list. The first candidate must contain a bounded series
title, positive integer season/episode, supported audio-language code, `ready: true`
and `audio_verified: true`. Only these typed facts reach the native spoken offer;
other payload fields remain diagnostic data. Explicit requested-language metadata
must not contradict the actual request. A matching language is not a switch offer.

The presentation asks before changing language and never dispatches an action.
Subsequent explicit acceptance is a new user turn; normal tool permissions still
apply and the exact offered candidate/language must be preserved. Unknown action
outcomes are never retried. A bounded plain-language no-playable-result failure is
distinct from title ambiguity and does not ask for already sufficient episode details.

Six focused production-source headless checks passed, including the new
alternative/unavailable checks. They cover malformed and duplicate-key envelopes,
unverified or not-ready audio, playback already started, invalid consent policy,
conflicting requested language, unsafe labels, invalid episode values and separate
unknown-outcome handling. They establish result presentation safeguards, not that
an external service actually has a stream or that a live conversation chose correctly.

The MCP client now prefers complete bounded `structuredContent` objects and also
retains complete JSON-object text up to 8 KiB, so machine-readable offers do not
pass through the 2,000-character plain diagnostic limit. The sixth regression
exercises actual MCP envelopes containing text plus structured content, JSON text
longer than 2,000 characters, and the unchanged plain-text fallback. Playback
state and viewing progress must come from observed connected-tool state; ordinary
conversation notes do not prove what was watched. Availability of a concrete
continue capability is installation-specific.

The opted-in owner setup also supports adding a capability to an existing server
with the same identity, endpoint and protocol revision. It retains existing exact
tool mappings and owner grants, rejects an attempted mapping change, and appends
new permissions without standing grants. Source IDs and other servers remain intact.
Native setup is discovery only; binding a continue capability does not test or invoke
playback. Device-specific configurations and watch state stay outside this repository.

## Resting orb motion

The orb's motion reference follows the device's resting gravity instead of a
fixed held-phone angle. A stationary flat or held device supplies zero pull;
changes of pose and shaking still pull the orb. The reference and sample time
reset when the last visible owner releases the motion sensor. The 2.5-second
value is a filter time constant, not an exact time to settle completely.

Five synthetic checks of the exact `OrbTilt` source passed: flat and held rest,
laying the device down and settling, sideways tilt, and bounded shake response.
The exact motion adapter was typechecked against the iOS 26 simulator SDK, and
the Mac Catalyst app/test targets built successfully. These checks open no
microphone, play no audio and do not establish how real hand motion feels on a
phone; that remains a hardware validation item.
