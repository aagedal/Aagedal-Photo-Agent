# Production delivery transport validation — 2026-08-21

The Phase 5 upload boundary now has a production adapter for the app's existing FTP, explicit-FTPS,
and SFTP connection inventory. The adapter resolves a strict canonical connection UUID, validates
the staged filename, byte count, SHA-256 shape, and remote child path before requesting credentials,
and keeps the Keychain lookup inside the transport boundary. Credentials are supplied to `curl`
through a temporary mode-0600 netrc file; command arguments and outward errors contain neither the
password nor editorial metadata.

An upload runs in an uncancelled detached operation so cancellation remains a file-boundary action.
The optional post-transfer probe distinguishes protocol acknowledgement from a non-cryptographic
remote existence/size observation. A confirmed missing object is reported only for curl's explicit
remote-not-found result; unsupported or otherwise inconclusive probes remain unavailable rather
than being mislabeled as failure or cryptographic verification.

Validation used isolated DerivedData. `DeliveryFTPTransportFactoryTests` passed 8/8, including the
three protocol variants, path and identifier rejection before Keychain access, sanitized failures,
remote-stat interpretation, and active-file cancellation behavior. The adjacent legacy FTP suites
passed 16/16, the production target built successfully, the project file passed `plutil -lint`, and
the scoped diff passed `git diff --check`.

Known boundaries are explicit: SFTP currently uses the existing password/netrc authentication
model rather than an SSH private-key identity, and remote SIZE depends on server/curl HEAD support.
Remote existence and size are useful acknowledgement evidence, not proof that remote bytes match
the locally recorded SHA-256.
