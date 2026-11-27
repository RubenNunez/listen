# Fixtures

Everything here is synthetic and written by hand. No recordings, no real transcripts, no real personal facts.

- `streams/two_speaker_de.jsonl`: provider-neutral speech events (one JSON object per line, the `SpeechEvent` type of the session crate) for a fictional German two-speaker exchange. Voice 1 asks, voice 2 answers. It contains revised partials, an overlapping interjection (segment 5 starts before segment 4 ends) and one segment with no voice.
- `protocol/client_events.jsonl`, `protocol/server_envelopes.jsonl`: one line per wire event variant. The Rust protocol crate and the Swift app both test against them, so the two implementations cannot drift apart unnoticed.
