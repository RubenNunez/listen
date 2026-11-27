# Open-harness configuration checks

This package compiles the app's actual [configuration sources](../../Listen/Harness/OpenHarness)
and [tests](../../ListenTests/HarnessConfigurationTests.swift) through relative
symlinks. It has no third-party dependencies, network client, account inventory,
microphone access or inference. Test writes use disposable temporary folders.

Run from the repository root:

```sh
swift test --package-path ios/Tools/harness-config --scratch-path /tmp/listen-harness-config-build
```

The test target also links the actual `SystemConfig.swift`, so migration is
decoded through the current engine's real settings type. The small
`LegacyCompilationContext.swift` supplies only the names used by the prompt
placeholder helper; it is not an engine or a model stub. It is outside the app
target. This does not replace the complete Mac app tests or a runtime migration.

## Implemented foundation

- Version 2 values for connections, exact model references, arbitrary prompt and
  role IDs, typed flow nodes, profiles and per-conversation immutable plans.
- Structural validation, unknown-field and duplicate-key rejection, bounded DAG
  compilation, capability/adapter checks and explicit execution/fallback policy.
- Local binding fingerprints include destination, authentication slot and adapter
  contract. Capability observations also bind the exact upstream model. Imported
  JSON cannot create those observations or grants.
- Explicit v1 migration from the supplied current defaults, preserving prompt
  bytes, selected model strings, timing, switches and retained extension data.
  An original-byte backup precedes replacement. Prompt text has one v2 source.
- A compatibility facade projects those values back to the actual legacy decoder.
  A legacy-backed document requires that decoder's validator before it can be
  saved as a working recovery copy.
- Atomic saves, observed stale-edit/revision rejection and a persistent last-valid
  copy. Invalid edits are left in place for repair; no fresh cloud defaults appear.

The migrated default flow is a single `currentListen` node. It keeps the existing
engine whole until operators replace it; it cannot be mixed with new flow nodes.
The temporary compatibility payload holds old agent switches and model-selection
strings, not another set of prompts. No saved account is discovered or activated.

## Integration boundary

These files are compiled into the native project, but `SystemConfig.load`,
`SessionModel`, `AnswerEngine` and the settings UI do not call them yet. Do not
install a v2 file as the live `system.json` through the old loader. The production
bridge must first recognize versions, validate legacy/core semantics, retain its
last valid state and reject unsupported execution instead of using fresh defaults.

There is no HTTP/CLI adapter factory, flow executor, prompt renderer or v2 editor
in this package. Compilation proves references, ports and dependencies; it does
not prove runtime joins, cancellation, decision field schemas or card quality.
File hashes detect changes observed before replacement; atomic file replacement
is not a cross-process compare-and-swap against an uncoordinated external editor.
Optional structural fields are omitted rather than written as `null`.

Next steps and acceptance: [implementation plan](../../../docs/OPEN_HARNESS_PLAN.md).
App integration follows the reviewed performance checkpoint, preserving the
measurement baseline. Full app tests, actual account compatibility, native UI,
runtime migration and latency/quality acceptance remain pending.

Evidence, 17 November 2026: 28 Swift Testing tests in four suites passed, including
parameterized rejection cases and the real `SystemConfig` decoder. All five
production core files also passed Swift 6 type checking for arm64 Mac Catalyst
and arm64 iPhone; XcodeGen was regenerated. This is not a speedup measurement.
