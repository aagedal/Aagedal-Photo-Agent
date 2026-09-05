# Analysis loupe interaction — 2026-09-05

The loupe background is now constrained to the width of its two 132-point pixel panes and padding.
Previously the header Spacer accepted the viewport width, leaving substantial empty material around
the images. The existing 100% and 400% raster rendering and edge-aware reticle remain unchanged.

The Loupe toolbar button and Z while pointing at the photo toggle visibility for the current Analysis
workspace. Loupe visibility starts enabled. Text editors retain typed Z, Command-Z remains undo,
and key repeats do not toggle repeatedly. The shortcut also works when annotations are read-only.
The loupe chooses the corner opposite the pointer in viewport coordinates, so inspecting the top
moves it down; placement remains independent of image zoom and pan.

Validation:

- Serial unfiltered Xcode run: **2,092 tests in 238 suites passed**, 65.915 seconds.
- Added placement coverage for all four corners at two viewport sizes; existing raster crop tests pass.
- `scripts/ci/validate_repository.sh` and `git diff --check`: passed.
- Logs: `/private/tmp/aagedal-analysis-loupe-tests.log` and
  `/private/tmp/aagedal-analysis-loupe-repository.log`.
- Result: `Test-Aagedal Photo Agent Tests-2026.09.05_23-52-24-+0200.xcresult` in Xcode DerivedData.

Manual visual verification remains: hover each quadrant in normal and residual views, toggle Z and
the toolbar control, type a label containing z, and verify Command-Z still undoes an annotation.
Check compact loupe sizing at the user's normal window size and display scale.
