# Current limits

This is a source alpha, not a polished system-level Siri replacement. macOS/iOS
system privileges, background execution and device support remain subject to the
platform. There is no signed public binary or TestFlight build in this source release.

- Native Mac testing is ahead of physical-device coverage. Phone latency and energy
  use need device-specific measurements.
- Speech quality varies by voice model and device. Buffer underruns, prosody,
  recognition mistakes and false interruptions remain active engineering work.
- Model/provider latency varies. No general claim of matching or beating GPT-Live
  is made by this alpha; synthetic PCM timing is not acoustic latency.
- Supported model connections do not imply arbitrary native reasoning-weight loading.
- Cloud model and optional routing usage can cost money. Listen's source is free;
  those services are separate.
- Optional downloaded voices have different licenses. Supertonic weights carry
  the included RAIL terms rather than Apache-2.0.
- The bounded local action/wait/action sequence is experimental: at most thirty
  seconds, existing permissions per action, during the active conversation only.
  Cancel, a new tool instruction, pause/background or conversation end stops future
  steps; an already dispatched action is not rolled back.
- The Rust desktop router's Linux GUI dependency chain still contains the documented
  glib 0.18 advisory [RUSTSEC-2024-0429](https://rustsec.org/advisories/RUSTSEC-2024-0429.html).
  No Linux GUI binary is distributed here.

Treat generated text and native service observations as distinct evidence. A model's
claim is not proof that a device changed state or that a private repository was read.
