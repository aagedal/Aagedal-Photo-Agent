# ADR-006: authenticated local native review handoff

Date: 2026-10-02. Status: accepted for the bounded transcription review handoff.

## Decision

The independently launched STDIO helper may ask the running app to present one exact retained
transcription request. The local channel accepts only a schema version, fixed review kind and
original lowercase request UUID/epoch. It cannot carry provider configuration, paths, transcript
text, a consent flag or an execution capability. A successful `reviewRequired` response acknowledges
the presentation request; it does not prove that the user has inspected, consented to or completed
anything. Direct helper execution remains a separate unfinished boundary.

Use a private Unix-domain socket. No launchd service installation, network listener or application
launch is required. The app starts its listener only with local automation enabled and stops it when
automation is disabled or the app exits. The native handler independently reloads current authority
and revalidates exact epoch, retained state, expiry and the whole ordered rooted preview. After the
UI hop, the existing native model repeats inspection and clears any prior execution review/consent.
Provider review, fresh explicit consent and rooted operation admission continue through the existing
native service. No prepared binding or rooted reservation is serialized.

## Authentication and endpoint lifetime

Each side checks kernel-supplied peer user credentials and `LOCAL_PEERTOKEN`. The audit token selects
dynamic code using [Apple's guest-code API](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:))
and [audit-token guest attribute](https://developer.apple.com/documentation/security/ksecguestattributeaudit).
PID lookup, socket filenames, hashes in request JSON and archive checksums grant no authentication.
Both executable signatures must match the expected identifiers, Apple certificate anchor and
application team, with no ad-hoc signature. Dynamic peer code hashes and executable paths must match
the valid app/helper pair in the current bundle. A copied, unsigned, unpaired or differently installed
peer refuses. This policy does not authenticate arbitrary code from the same user's account.

The app first authenticates the accepted helper and sends a fixed, non-sensitive `peerAccepted`
greeting. The helper then authenticates the app before sending request handles. This bounded
sequence makes kernel peer credentials available after accept; the greeting itself grants no trust
and carries no request or provider data. There is no weaker authentication fallback.
After the response, the app holds the connection until a fixed, bounded `peerReceipt`
acknowledgement so the helper can repeat its kernel peer check before the socket closes.
The acknowledgement grants no consent or additional invocation authority.

The default directory is `/private/tmp/apa-native-<effective-user-id>`, mode 0700; the socket and
owner-lock file are mode 0600. Directory walks use retained no-follow descriptors and inode witnesses.
Lexical path validation preserves physical `/private/tmp` spelling rather than relying on Foundation's
normalization to `/tmp`. Socket publication uses no-follow permission changes and checks identity
again. The lifetime owner lock is nonblocking. Stale recovery requires exclusive owner authority,
an exact safe socket witness and a concrete refused connection; live endpoints and unexpected entries
are preserved. Closing or crashing releases the kernel lock. Normal stop removes its witnessed socket
and wakes blocked socket IO without synchronously waiting for a running review handler.

Messages use a closed canonical JSON shape, a 512-byte bound, one request per connection, a bounded
deadline and at most four accepted connections. Authentication and endpoint witnesses are checked
again before handling and returning a response. Arbitrary error descriptions and signature details
are not sent to clients. Socket artifacts contain no photo/audio/transcript content; the inert owner
file may remain after shutdown.

## Outcomes and limits

An awaiting request can produce a native presentation request only after exact whole-set validation.
Cancelled, expired, changed or uncertain admitted requests refuse. A linked request can return only
its exact retained operation UUID after locked admission/owner/kind/batch/chronology checks; plan
expiry does not erase retained operation history. Missing history is unavailable and never completion.
The helper's current authority must still match after the call.

Native UI tests and socket tests with injected peer checks are distinct from production authentication.
The disposable signed-pair probe exercises the actual Security framework and kernel credentials without
touching host roots, preferences or models. Neither that probe nor development signing qualifies
distribution signing, notarization, actual speech inference, physical power-loss recovery or release
readiness. Broader authenticated execution requires a later decision and acceptance evidence.

[Cycle 122](release/cycle-122-installed-native-review-authority-2026-10-02.md) also joins
the actual development-signed bundled helper, running app, retained request resolver and
native review UI in one disposable Debug qualification. Two stale-epoch refusals preserve
native selection/consent; two valid presentations select the exact request and clear prior
consent. Normal Command-Q removes the listener. The helper launches outside XCTest's sandbox;
the runner retains its sandbox with one narrow fixture-directory write exception. Debug
storage routing injects no peer authentication and submits no inference. This bounded
installed review evidence does not qualify distribution signing, real providers or direct
helper execution.
