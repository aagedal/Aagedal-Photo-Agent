# SwiftExif local fork

This directory is a source-preserving fork of
[aagedal/SwiftExif](https://github.com/aagedal/SwiftExif) 1.9.10 at revision
`47249c72b613ebab8e4514f4adf05bb8000a1908`. Its GPL-3.0 license is retained in `LICENSE`.

Photo Agent maintains one carrier-model delta that upstream 1.9.10 cannot express:
`XMPValue.languageAlternative` retains every ordered `rdf:Alt` item and its `xml:lang` tag.
The reader and writer use this representation losslessly while the existing scalar
`langAlternative` case remains source compatible for clients that author only `x-default`.

When updating the fork, start from the recorded upstream revision, reapply the localized-language
alternative delta, and run Photo Agent's localized-title sidecar and embedded-container tests.
