Run native selection gesture checks in an isolated simulator app:

```sh
python3 ios/SelectionChecks/run_ui.py [simulator-UDID]
```

The runner compiles the production selection row, toolbar layout, and NoteBankKit. Its four tests check compact toolbar geometry, exchanging the trailing action slot for a leading checkbox without rewrapping multiline content, hold-to-select, adding Items, automatic exit after the last deselection, normal taps, and scrolling. Toolbar actions are inert in this layout fixture. It uses its own temporary store, removes the diagnostic app and build artifacts, and restores the simulator's initial boot state. It never installs NoteBank or accesses its data.
