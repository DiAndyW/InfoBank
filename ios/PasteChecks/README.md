Run with a booted iOS simulator:

```sh
python3 ios/PasteChecks/run.py booted
```

The runner compiles production clipboard, UIKit input and SwiftUI wrapper code into an isolated diagnostic app. It generates its own JPEG fixture and checks text plus one/three images, attachment-only Paste availability, selection replacement, text Undo, one callback per item despite multiple image representations, original-format preference, SwiftUI binding and clearing the draft. It removes the diagnostic app afterward and never replaces NoteBank or accesses its storage. Running these checks changes the simulator clipboard to test content.
