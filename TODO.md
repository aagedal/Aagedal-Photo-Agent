# TODO

## Priority

- [x] **Avoid ImageIO QoS priority inversion during embedded RAW preview extraction.**
  (2026-07-21) `FullScreenImageCache.extractEmbeddedPreviewOffPoolWithOrientation`
  now confines synchronous ImageIO extraction to an enforced default-QoS dispatch work
  item and resumes foreground callers through a checked continuation. The edit preview,
  Clean Feed fallback, and full-screen RAW preview all use the async boundary. A focused
  `.userInitiated` regression test passes with Thread Performance Checker enabled.
