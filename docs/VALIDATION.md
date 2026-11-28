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

## Microphone mute and observed action feedback

Implementation decision, 28 November 2026: live conversations have an explicit
microphone-only mute control in both assistant and spoken-card views. Muting removes
the input tap, closes frame delivery, flushes the unfinished recognition boundary and
rejects late input callbacks. The shared output engine, committed requests and native
tool operations remain active. This is application input muting; hardware microphone
power state is outside this control.

Recordings represent muted intervals with generated silence. Recognition timestamps
are mapped across those intervals, while acoustic support remains tied to the original
recognition feed. Mute events identify the generated sections for later analysis.

Short acknowledgements such as “thank you” preserve a pending request; substantive
corrections still interrupt. Observed tool feedback survives conversational interruption.
An identical action awaiting owner confirmation reuses the existing pending card. This
neither grants permission nor coalesces a later explicit repeat after dispatch.

Playback/control speech uses coherent structured receipts and the observed player state,
including the actual fallback language. Continue/status results do not imply a new start.
Title ambiguity offers bounded validated title/year choices. Raw service speech and
instructions are never narrated. Generic Home Assistant on/off tools require a nonempty,
explicit domain when their schema offers a domain array; execution supplies no guessed
device type or all-device default.

A single validated title candidate is presented as a clarification, rather than a
service failure or a playback confirmation. A structured `episode_unavailable` result
with `playback_started: false` explains that the requested selection is unavailable;
it never retries or selects another episode. Two synthetic regression cases reproduced
the generic-error fallthrough before these changes. All eleven receipt checks passed
afterwards, including hostile service speech, invalid title/year data and conflicting
or missing playback flags. This follow-up is source-tested and is not deployed in the
installed build 57.

Confirmation fields use localized labels and readable language/action values, while
retaining every supplied field and the exact typed request used for authorization.
Unknown values remain literal; exact JSON stays under action details. Cancel remains
the same denial path and now explains how to reformulate a request. Three synthetic
formatting checks and a Mac Catalyst SDK build passed. Device layout and interaction
acceptance remain pending; no new conversation or device action was run for this check.

Playback receipts reject explicit conflicts between requested, selected and observed
season/episode/year, media IDs and trailing `SxxExx` player-title markers. Matching
stable media IDs permit display aliases but never override an episode conflict.
If a receipt supplies a `playback_id`, the player must echo that ID. Status/control
receipts may describe an existing player's ID without reserving a new start; older
adapters with neither ID remain supported. Opaque display labels are not assumed to
be series names. Conflicts produce an unconfirmed response, without
retrying or dispatching anything. Five synthetic identity regressions and the existing
receipt checks pass against the actual Foundation decoder, including the independent
stale-player reproducer. No microphone, model, network or physical player is involved.

If an observation changes during generation, a buffered answer is regenerated from the
new facts at most once before speaking or proposing operations. Direct answers that
start while a native operation is pending are buffered through model completion for this
check. That can delay the first spoken sentence for these overlapping requests and can
add one model request. Ordinary replies retain streaming. This change establishes no
new acoustic latency score or comparison with another voice service.

Validation: 19 focused native tests passed with `LISTEN_TEST_NO_MICROPHONE=1` and
`LISTEN_TALKBACK_MUTE=1`: seven `PlaybackReceiptTests`, eight selected
`VoiceAssistantSessions` regressions, three `TerminalInterface` capture/clock checks,
and `SpokenSessionWiring/talkStartsTheTopicsOwnSystemAndItsPauseReachesTheRecogniser()`.
The latter exercises SessionModel ingestion and output continuity with synthetic audio
and silent speech. Both buffered-tool and tool-withheld reply paths are covered by the
new observation-refresh regression. Thirteen focused Foundation/MCP checks also passed.
Mac Catalyst test builds and an unsigned iOS application build succeeded. Reproduce the
native checks with the generated `.xctestrun`, the two environment variables above, and
`-only-testing:ListenTests/<suite>/<method>()` filters; confirm the Swift Testing test count,
not just the XCTest wrapper summary. A zero-test run is not validation.

Physical microphone capture, echo cancellation across mute/unmute and real speaker
continuity remain unverified for this change. No new recordings or physical device
commands were used in these checks. Device configuration, recordings and analysis
artifacts are excluded from the public change.

## General-purpose working context

28 November 2026: bounded original participant quotations now carry relevant earlier
constraints, corrections and task context beyond the last sixteen messages. Retention
cues select source evidence; they do not create a semantic profile or new instructions.
The same context goes to routing, task workers and speculative preparation. No additional
model call is needed to retain it. Current-session evidence and dated prior-session quotes
are separate; recent explicit corrections govern the current task. Earlier quoted tasks
cannot grant permissions or become an automatic action queue.

An input-order candidate keeps the static topic/tool prefix and places historical
evidence before recent action observations, with current dialogue last. Unknown fields
remain present. Two structural checks reproduce the old trailing-history order and pass
after the change; decoded JSON values and payload byte count are unchanged. Independent
source inspection confirms that HTTP/Responses and router/official-CLI paths carry the
encoded JSON as a string, preserving this inner order. Mac Catalyst compilation passed.
This establishes the input mechanism, not improved answers or the cause of any particular
recording. No model call was made for this candidate; semantic/live acceptance remains
open in issue #6, and this follow-up is not deployed to installed build 57.

When conversation notes are enabled, exact selected statements are stored in a bounded
0600 sidecar in the selected topic's conversation folder. An optional model-summary rewrite
does not replace that evidence. Clearing topic notes removes both. Sidecar reads reject
symlinks, excessive sizes and invalid shapes. With notes disabled, earlier summaries and
statement sidecars are excluded; within-session working context still works.

Seven focused Foundation checks passed for cross-domain continuity, source-role isolation,
corrections, bounded complete quotations, dated provenance and local persistence/clearing.
The combined build 56 (voice controls, working context and orb rest-pose fix) passed 39
focused native checks, including two session-level continuity/memory-opt-out regressions,
five orb checks and two decoder-failure feedback cases. Signed iPhone and Mac Catalyst
builds succeeded. Synthetic task continuity used the existing main calls without adding
retention calls; it made no external tool changes.

`WorkingContextModelProbe` completed four typed synthetic model calls comparing recent
history alone with retained quotations. The recent-history writing case lacked the earlier
recipient/task details; the retained version supplied the requested two-sentence message.
The retained choice response kept an earlier rejected option excluded. This is a small,
ordered paired probe through the existing adapter with silent output and no tools. Call
order, caching and provider conditions were not controlled; its task-specific rubric and
first-text measurements are not a general intelligence or voice-speed benchmark.

A typed `playback_failed` result with verified audio identifies the found language and
explains the failed player start. Player cleanup to idle does not turn that failure into
missing-language availability. Unverified language metadata never creates a language
claim or an automatic fallback; raw service speech and diagnostic codes stay unspoken.

### Recognition recovery after unmuting (build 57)

The original mute implementation could wait for an analyzer timestamp while blocking
the very frames needed to reach it. Build 57 removes that input barrier. Cancellation
discards unfinished pre-mute analysis without gating resumed frames; a converted-buffer
clock and late-result filtering preserve the recognition boundary. Explicit utterance
finalization uses already-consumed audio, rather than a possibly future input timestamp.
See Apple's [finalization contract](https://developer.apple.com/documentation/speech/speechanalyzer/finalize%28through%3A%29)
and [cancellation contract](https://developer.apple.com/documentation/speech/speechanalyzer/cancelanalysis%28before%3A%29),
verified 28 November 2026.

The explicit opt-in `LiveRecognitionMuteProbe` feeds an owner-supplied local WAV into
the real SpeechAnalyzer, with physical input disabled and no assistant, model, tools or
audio player. It observed recognition before mute, after unmute and after five rapid
toggles, with increasing segment IDs and no old results delivered without new input.
The probe passed in 4.410 seconds; this is test duration, not conversational latency.
The same 39 combined native regressions also passed on build 57. Signed iOS and Mac
Catalyst test builds succeeded. The fixture and receipts remain outside version control.
This does not establish physical microphone, echo-cancellation or speaker quality.

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

### Completed input at the mute boundary

Implementation decision, 28 November 2026: microphone mute also closes a wholly
finalized pending turn through the normal conversation path. Previously those
sentences could be discarded while still waiting for an acoustic pause. Any
unfinished segment prevents this submission: removing an unfinished correction
could change an action's scope. A continuation borrowing a previously committed
prefix is also discarded conservatively. Repeated mute calls and late recognition
of already consumed words do not create another request. Tool permissions remain
unchanged.

The unchanged-draft-to-final regression failed before this correction. The final
Mac Catalyst test build and ten targeted native checks passed, including finalized
input, incomplete corrections, repeated input, ongoing generation/playback, pause
behavior and the physical-microphone test guard. Models, tools and speakers in the
conversation tests are synthetic. This checks turn handoff, not acoustic accuracy
or conversational latency. Installed build 57 does not contain this correction;
physical iPhone acceptance remains pending.

### Shared desktop conversation settings

The assistant and spoken-card modes share the top Settings entry on Mac Catalyst
and iPhone. Secondary voice, source and display controls live in its sheet;
microphone mute, stop, action confirmations, recording status and operational
errors remain in the conversation. Settings has a Command-comma shortcut. Ready
voice notices move into Settings; a missing-model download retains its license
notice before installation. This changes presentation, not tool grants or routing.

Both iOS and Mac Catalyst SDK builds passed for these five view-source files,
with independent source review and byte-for-byte verification of the Mac build
input. These were build-only checks: no test microphone, speaker playback or
device action was started. Actual narrow/wide window appearance and keyboard
focus have not been accepted in a running app. No device upgrade is claimed by
these checks.

### TV connection receipts

A validated `tv_unreachable` outcome receives a local connection-specific phrase
in German or English, independent of the RPC success flag. Service speech stays
untrusted. The phrase makes no claim about content availability, language or
whether playback previously started; it initiates no retry. Duplicate outcome
keys and unstructured claims do not select this diagnostic.

Two independent synthetic connection regressions failed before the correction.
Twenty targeted receipt/identity checks passed afterward against the actual
Foundation decoder source, including null/true/false playback metadata and
malformed receipts. No app, microphone, model, network or player was started by
these checks. This is contract validation, not a live reachability benchmark.

### Human-readable action headings

Generic action confirmations use a bounded, literal display label. Optional tool
`title` takes precedence over `annotations.title`, then the original `name`, as in
the [official MCP schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2026-07-28/schema.ts)
(verified 28 November 2026). Annotation permission hints are not imported. Empty,
oversized or control-bearing labels fall back; markup is plain text, not formatting.
Missing or malformed optional cached display fields do not replace execution IDs,
schemas or saved grants. Explicit light confirmations keep their existing wording.

Twenty-four Foundation checks passed, including display precedence, legacy cache
decoding, malformed metadata, typed argument validation and existing playback
receipts. These use the production decoder/presentation source without an app,
microphone, model or device action. Running-window appearance and accessibility
acceptance remain separate from these contract checks.
