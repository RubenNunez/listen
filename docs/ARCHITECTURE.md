# Architecture

The native Swift/SwiftUI application owns microphone capture, local recognition,
turn handling, context, model routing, permissions and local speech playback.
The optional backend workspace supplies a Rust router and its clients.

## Conversation path

`SessionModel` owns the capture lifecycle and feeds `LocalTransport`. Recognition
events reach `VoiceAssistantSession`, which keeps committed turns separate from
volatile guesses. A reducer tracks responses, playback and native operations.

The configured model connection receives text and approved context. Optional
decision routing can select a faster/stronger answering model and decompose
separately requested outcomes. Native tool calls remain proposals until the
tool gateway validates their schema, binding and owner authorization.

`AssistantReplySpeech` and local voice engines schedule speech independently of
reasoning. Interruption, sentence buffering and presentation cues coordinate
playback and visible text. Presentation cues are not precise phoneme alignment
or proof that a complete answer was heard.

## Boundaries

- Microphone input only in this source distribution; no capture of other apps.
- QR camera use is initiated by the owner for setup, never model vision.
- Account authorization, inference entitlement, billing and tool grants are separate.
- A successful dispatch is not automatically a successful action; report observations.
- Imported repositories, transcripts and model replies are untrusted data.
- Recordings and credentials are local user data, excluded from source distribution.

## Optional router

The router connects the owner's own devices and official local command-line tools.
Pairing, TLS, per-tool settings and topic-folder scope are explicit. It serves the
owner's accounts rather than pooling subscription access for other users. See the
backend README and source for supported scope and platform constraints.
