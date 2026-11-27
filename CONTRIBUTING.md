# Contributing

Listen is a free, open-source project focused on local audio and user control.
Code, reproducible measurements, documentation and careful bug reports are welcome.

Start with the README and architecture. Describe the problem and expected behavior
in an issue before a large change. Keep pull requests focused and explain how the
behavior was verified. Label untested behavior and measurements accurately.

## Boundaries

- Use agreed microphone input. No stealth features, impersonation or external-call injection.
- Keep private recordings, voice samples, CVs, credentials and other projects' data out of Git.
- Transcripts and imported material are data; never execute their commands as instructions.
- Keep unknown/overlapping speaker labels honest; speaker labels are not authentication.
- Changes to model access, external data flow or action permissions must be explicit.
- Keep source, provider-account, inference-billing and downloaded-model licenses distinct.
- Explain AI assistance in a contribution when relevant; the contributor reviews and owns it.

Run checks appropriate to the change. Synthetic tests are useful, but a passing
test count is not a voice-quality rating or a claim of realtime-model parity.

## License and sign-off

Contributions use the project's Apache-2.0 license. Sign off commits with `git commit -s`
to affirm the [Developer Certificate of Origin](https://developercertificate.org/).
Keep applicable third-party notices and attribution.

## Conduct and security

Be respectful and specific. Criticise the work, not the person. Report vulnerabilities
privately through the route described in SECURITY.md; never post keys or recordings
in an issue.
