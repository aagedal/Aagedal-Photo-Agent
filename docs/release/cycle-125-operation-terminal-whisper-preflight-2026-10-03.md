# Cycle 125 — operation terminal recovery and Whisper install preflight

Baseline: `a711aa5`, initially clean. State remains **IMPLEMENTING**. Two sub-agents
implemented independent fixes and a build correction; a third reviewed the diffs. The parent integrated,
validated and committed the changes. No whole release gate closes.

## Changes

An automation executor could return a terminal outcome inconsistent with retained
batch progress, or throw while an item was still running. The registry correctly
refused the claimed outcome, but the retained task exited with a nonterminal record.
The coordinator now catches that specific invalid-transition refusal and records
`recoveryRequired`, preserving batch evidence and cancellation acknowledgment.
Storage/owner errors still propagate. Six regression cases cover inconsistent outcomes,
throws, cancellation, repeated completion inspection and released execution capacity.

Signed Whisper installation now preflights the store's generation, trust, model identity
and unclaimed artifacts before transfer. A missing ledger beside retained content or
staging bytes refuses before creating a download cache or starting a network request.
A mismatched model store also refuses before transfer. Installation repeats its existing
checks after suspension; preflight does not grant lasting authority. Two regression tests
cover both lost-ledger artifact forms and the wrong-model store.

The signed build also exposed a baseline packaging defect in the recent description
assistant merge: codesign interpreted `Contents/Helpers/llama.cpp` as a nested bundle
and rejected it. The generated runtime now uses `Resources/llama-runtime`; Xcode outputs,
backend lookup and documentation agree. Bundling verifies source hashes before removing
the obsolete generated Helpers directories (symlinks are unlinked, never followed). Vendor source
remains separate. The existing runtime integration test checks the new destination and
executes the bundled helper. This correction does not expand the 3.0 feature scope.

## Verification

Host: arm64 macOS 27.0.1 (26A434), Xcode 27. Local Debug build/test storage:
`build/qa-v3-continuation/DerivedData`. Tests use generated disposable temporary fixtures;
no private media, user preferences or credentials are needed.

- Focused final development-signed build: **61 tests / three suites**, zero failures,
  1.223 seconds. Evidence: `build/qa-v3-continuation/focused-resources.xcresult` and log.
- Repository validation and whitespace pass: `build/qa-v3-continuation/repository-resources.log`.
- Independent source review passes, including corrected test fixtures and final runtime paths.
- Development signature verification passes with `codesign --verify --deep --strict --verbose=2`:
  `build/qa-v3-continuation/codesign-verify-approved.log`. Sandboxed trust verification
  refused its certificate; approved verification succeeded. This is not notarization.
- Full integrated regression: **3,831 tests / 379 suites pass**, 127.095 seconds;
  `build/qa-v3-continuation/full.xcresult` and log.

No GUI model setup/recovery workflow was exercised this cycle. The runtime integration
test executes the bundled helper; it does not infer a caption with downloaded weights.
Existing host `MDB_MAP_FULL` diagnostics appeared during tests and remain environment
observations, not evidence of workflow qualification.

The first sandboxed build could not resolve GitHub and default Xcode cache writes were
unavailable. Approved Xcode execution resolved pinned dependencies into the checkout.
The first compiled test run found four actor-isolated property accesses in the new tests;
the parent corrected them by awaiting the operation ID before synchronous registry calls.
A second compilation caught private receipt-field access in the new Whisper tests;
tests now recreate canonical descriptor bytes and signatures with the fixture key.
A subsequent run compiled but failed at the baseline helper signing issue described
above; an extension-free Helpers folder also refused its manifest as unsigned code,
so the final layout moved all runtime resources together under Resources. These failed runs are diagnostic evidence, not passing test results.

## Remaining engineering and manual work

Next engineering: finish signed curated catalog/Settings lifecycle integration, live
provider readiness and production automation face/template/physical IPTC executors.
Then qualify real provider cancellation/offline/GPU, retained writes, performance and
candidate packaging against the authoritative plans. These fixes do not establish
actual provider inference or GUI recovery behavior.

User preparation remains the [release handoff](release-completion-handoff-2026-10-02.md):
install the explicit Apple Speech test language; provide disposable delivery endpoints,
removable/cloud targets, additional camera/RAW/HEIF fixtures and unavailable hardware;
confirm editor activation; arrange qualified privacy/legal review and authorized CI
branch protection. The agent can run most subsequent interoperability and device drills.
Actual human acceptance still includes spoken VoiceOver, keyboard/first-use usability,
photographer color/edit review and a complete card-to-delivery rehearsal after candidate
readiness. Publication requires later release-owner authorization. No acceptance or
publication is requested by this cycle.
