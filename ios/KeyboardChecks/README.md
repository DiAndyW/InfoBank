# Keyboard and lifecycle checks

Use a disposable iPhone 17 simulator with the signed NoteBank app installed and Setup completed using a loopback Server and a dummy secret. Never use a real Server. Stop the app before running this check.

Run `python3 ios/KeyboardChecks/run_ui.py [simulator-UDID]`. The runner requires a loopback Server URL, seeds a long Home draft, disables automatic Tunnel trash, and drives the installed production app. It uninstalls NoteBank and the test apps afterward.

The two XCTest checks cover background/foreground draft recovery, empty Feed taps, downward keyboard dismissal, composer taps keeping focus, and Tunnel tap-to-copy. They do not cover attachment taps, double taps, or context menus.
