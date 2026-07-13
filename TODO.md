# TODO

## Priority

- [ ] **Avoid ImageIO QoS priority inversion during embedded RAW preview extraction.**
  `EditWorkspaceView` currently calls synchronous `CGImageSourceCreateThumbnailAtIndex`
  from a `.userInitiated` task, while ImageIO may wait on its own default-QoS worker.
  Add an async cache helper that performs only the blocking ImageIO call on an explicit
  default-QoS dispatch work item and resumes through a checked continuation; adopt it in
  the edit preview and Clean Feed fallback, then verify with Thread Performance Checker.
