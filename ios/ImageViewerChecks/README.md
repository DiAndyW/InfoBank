

# Native image viewer checks

Run against a booted simulator:

```sh
python3 ios/ImageViewerChecks/run.py booted
python3 ios/ImageViewerChecks/run_ui.py SIMULATOR_UDID
```

The first command compiles in Swift 6 mode and runs 22 checks against production image loading/zoom code: thumbnail preservation, file lifetime, failure/retry, cancellation, invalid files, orientation, bounded decoding, decoded-original cache reuse and limits, cached file failures, video exclusion, reentrant loading, synchronous activation, thumbnail/zoom reset on close, decoded-image lifetime and cost-based eviction. The second creates a temporary Xcode project and drives the production gallery with real XCTest swipe/pinch gestures, sharing, close and retry flows.

Both use isolated diagnostic apps and generated images. They never install NoteBank or access its storage. The UI runner leaves build products in `/tmp/notebank-gallery-ui-build` for inspecting/recording the fixture and uninstalls its diagnostic apps afterward.
