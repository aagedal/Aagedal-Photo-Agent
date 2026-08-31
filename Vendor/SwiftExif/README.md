# SwiftExif local fork

This directory is a source-preserving fork of
[aagedal/SwiftExif](https://github.com/aagedal/SwiftExif) 1.9.10 at revision
`47249c72b613ebab8e4514f4adf05bb8000a1908`. Its GPL-3.0 license is retained in `LICENSE`.

Photo Agent maintains two deltas from upstream 1.9.10:

- `XMPValue.languageAlternative` retains every ordered `rdf:Alt` item and its `xml:lang` tag.
  The reader and writer use this representation losslessly while the existing scalar
  `langAlternative` case remains source compatible for clients that author only `x-default`.
- Atomic image, audio, and video metadata writes explicitly restore the destination's prior
  filesystem visibility. This prevents iCloud Drive from intermittently carrying a dot-prefixed
  staging file's hidden flag onto the installed file.

When updating the fork, start from the recorded upstream revision, reapply both deltas, and run
Photo Agent's localized-title, embedded-container, and export-visibility tests.
