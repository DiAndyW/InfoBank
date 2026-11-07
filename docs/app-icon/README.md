# App icon

NoteBank's icon is **the Pile on butter**: three loose sheets, newest on top, on a butter-yellow ground. It stands for "dump it in now": things pile up in one place and get sorted later.

The SVGs here are the masters. Regenerate PNGs from them rather than scaling PNGs.

| Master | Ships as |
| --- | --- |
| `ios.svg`: full-bleed butter square, opaque, square corners (iOS applies the mask) | `ios/NoteBank/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, 1024 px RGB, no alpha |
| `macos.svg`: artwork in an 824 px rounded tile on a transparent 1024 canvas, tile shadow baked in | `desktop/src-tauri/icons/icon.icns` and the `32x32`, `128x128`, `128x128@2x` and `icon.png` PNGs |
| `windows.svg`: no tile, each sheet with a fine darker edge | `desktop/src-tauri/icons/icon.ico` (16–256 px frames) |
| `tray-template.svg`: one-colour glyph, black plus alpha | `desktop/src-tauri/icons/tray-template.png`, 36 px, loaded as a macOS template image |

## Colours

| Role | Hex | Source |
| --- | --- | --- |
| Background (iOS, macOS tile) | `#E8CF74` | Butter yellow |
| Flat shadow under the pile | `#CDB257` | Butter, darkened |
| Back sheet | `#1F4E79` | Navy (paper accent) |
| Middle sheet | `#FDF5B8` | Notepad yellow |
| Top note | `#FFFCF6` | Cream note (`surface-raised`) |
| Note lines | `#8C8070` | Note lines (`line-strong`) |
| Windows edge, top note | `#A89C88` | Derived |
| Windows edge, middle sheet | `#C9B85E` | Derived |
| macOS tile shadow | `#2A241C` at 28% | Ink |

## Construction

Everything is drawn on a 1024 × 1024 grid. All three sheets are the same rectangle; only their centre, angle and colour change.

| Element | Centre (x, y) | Rotation | Notes |
| --- | --- | --- | --- |
| Sheet | n/a | n/a | 470 × 560, corner radius 40 |
| Back sheet | 566, 548 | +13° | Navy |
| Middle sheet | 470, 524 | −15° | Notepad yellow |
| Top note | 512, 500 | −3° | Cream, with three lines |
| Flat shadow | each sheet +14, +22 | same as sheet | `#CDB257`, drawn under all three |
| Lines | from 20% to 80% of note width | follow the note | 47 px stroke, round caps, 112 px apart; third line 55% length |

- **macOS tile:** the full artwork scaled to 80.47% into a rounded square at x = y = 100, 824 × 824, radius 185.
- **Windows:** the pile scaled 1.36× around the centre, no tile, 14 px edge on each sheet.
- **Tray:** two sheets only. The front sheet (480 × 620, −4°) has the three lines knocked out; the back sheet (+16°) is separated from it by a 55 px gap.

## Rules

- Keep the sheet order everywhere: navy at the back, notepad yellow in the middle, cream on top.
- Every sheet's corners use the same radius.
- No black or near-black tile, no text or wordmark, no gradients.
- Don't put the pile in a tray or box: a note sticking out of a flat-topped box reads as a ballot box.
- At 16 px the three lines become texture. That's expected; don't add detail to compensate.
