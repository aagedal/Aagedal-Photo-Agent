# Delivery large-batch validation — 2026-08-21

The verified delivery pipeline was stressed with 1,000-item deterministic staging, upload, and
workflow batches. The test distinguishes unavoidable O(item-count) plan/result/checkpoint evidence
from artifact-byte working memory: item arrays retain only typed identities and fixed-size evidence,
while rendered/read-back payload data must be released before the next item begins.

Staging processed 64 MiB cumulatively as 1,000 custom-deallocator 64 KiB payloads. Probes yielded
while each payload was marked active and proved a maximum of one live payload, zero live payloads
after completion, one concurrent boundary operation, and responsive cancellation at item 25.
Upload performed 2,000 inspections and 1,000 transfers with maximum inspection/transfer concurrency
of one. A cancellation requested during the first all-artifact preflight inspection caused zero
uploads; production now checks explicit and caller cancellation before and after every initial
inspection and after each fresh pre-transfer inspection while retaining the active-file boundary.

The workflow stress retained 1,000 staging items, upload acknowledgements, checkpoint entries, and
receipt entries. Encoded evidence contained no artifact payload, editorial value, local URL, or
output filename; staging evidence remained below 2,000 encoded bytes per item and checkpoint/
manifest evidence below 700 bytes per item. Thus bookkeeping is necessarily O(n), but artifact-byte
working memory is bounded to one item and upload carries only URL/hash/size facts.

Validation used isolated DerivedData at `/private/tmp/aagedal-large-batch-final-01`. Thirty-five
tests across three suites passed in 19.686 seconds; the three stress cases ran in parallel and each
completed in roughly 16–20 seconds. The upload fixture created 2,000 tiny files, while staging and
workflow used small synthetic payloads rather than large on-disk artifacts. Swift parse validation
and project-file lint passed.

This is a deterministic architectural stress test, not a claim about throughput on every Apple
Silicon tier. Representative-device performance measurement remains a release drill.
