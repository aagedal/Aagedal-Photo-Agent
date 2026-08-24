# Deadline information-hierarchy validation

**Validated:** 2026-08-24  
**Scope:** Deadline Workspace hierarchy and authoritative Send eligibility

## Implemented contract

- The header identifies the selected saved profile explicitly.
- A top-level overview separates current phase, readiness, next required action, and Send
  eligibility from the detailed preflight rows.
- Planned Outputs has its own heading and retains the exact output filename, format-policy context,
  destination, and metadata-write-policy context already projected by preflight.
- Caption blockers make Caption the only current phase and keep Verify locked. Verify becomes
  current only after caption blockers are clear, and Send remains locked while any blocker exists.
- Empty selection/profile, progressive evaluation, partially configured or blocked input, warning
  review, preparation, active delivery, retained-resume, failure, cancellation, and completion have
  distinct guidance.
- `DeadlineSendAvailability` is owned by `DeadlineDeliveryExecutionModel`. Both the Send button and
  its visible explanation consume that exact value; the view does not independently infer whether
  Send is allowed.
- Availability fails closed for evaluation in progress, a busy or retained workflow, an outstanding
  warning/confirmation step, absent or stale preflight, blockers, a non-staged write strategy, an
  empty selection, or incomplete exact source identity capture.

## Automated evidence

The existing target-member test file was extended rather than adding a new file:

```sh
xcodebuild test \
  -project 'Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' \
  -destination 'platform=macOS' \
  -derivedDataPath '/private/tmp/aagedal-deadline-hierarchy-tests' \
  -only-testing:'Aagedal Photo Agent Tests/DeadlinePreflightCoordinatorTests'
```

Result: **18 tests passed** in one suite. The run compiled the application and test targets and
covered the authoritative availability reasons, warning/confirmation gating, coherent phase
ordering, readiness/action projection, exact planned names, cancellation, failure/recovery, and
receipt completion behavior.

## Remaining manual gate

The plan's separate first-use usability pass remains open. It should exercise representative empty,
incomplete, warning-only, ready, running, failed, resumed, and completed assignments at compact and
wide window sizes, then record any approved wording or layout changes in a dated note.
