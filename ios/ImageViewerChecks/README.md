

# Native image viewer checks

Run against a booted simulator:

```sh
python3 ios/ImageViewerChecks/run.py booted
python3 ios/ImageViewerChecks/run_ui.py SIMULAT OR_UDID
```

The first command runs nine checks against production image loading/zoom code: thumbnail preservation, file lifetime, failure/retry, cancellation, invalid files, orientation and bounded decoding. The second creates a temporary Xcode project and drives the production gallery with real XCTest swipe/pinch gestures, sharing, close and retry flows.

Both use isolated diagnostic apps and generated images. They never install NoteBank or access its storage. The UI runner leaves build products in `/tmp/notebank-gallery-ui-build` for inspecting/recording the fixture and uninstalls its diagnostic apps afterward.
