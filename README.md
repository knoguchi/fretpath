# FretPath

Playable guitar and bass fingering for MuseScore Studio 4.4+, with a Node API
for using the solver outside MuseScore.

Repository: https://github.com/knoguchi/fretpath
Bug reports and feature requests: https://github.com/knoguchi/fretpath/issues

Computes playable guitar fingering - (string, fret, left-hand finger,
position) for every note - using position-aware Viterbi dynamic programming,
and writes a TAB staff and/or annotations.

Unlike MuseScore's built-in conversion (StringData::convertPitch, a per-note
greedy scan that picks the thinnest string with the lowest fret), this plugin
optimizes the whole sequence: it minimizes hand movement along the neck,
prefers open strings, penalizes wide chord stretches, and respects existing
finger-number and string-number annotations as hard constraints. Alternate
tunings (drop D etc.) and fret counts are read automatically from the
instrument's string data.

## Comparison

Same excerpt, same notation — only the TAB staff differs.

MuseScore built-in (per-note greedy):

![MuseScore built-in tab](docs/images/builtin.png)

FretPath (position-aware Viterbi):

![FretPath tab](docs/images/fretpath.png)

The built-in conversion picks the thinnest available string for each note in
isolation, producing frets up to 10 and a hand that jumps around the neck.
FretPath uses open strings where they fit, spreads the line across the
fretboard, and stays in low positions — the way a classical guitarist would
actually play it.

## Setup
1. Copy this folder to Documents/MuseScore4/Plugins and restart MuseScore.
2. Enable the plugin in Home > Plugins.
3. If your part is in standard notation, first time only: open the
   Instruments panel (I), search "tablature", and add the matching
   tablature instrument - e.g. "Classical Guitar (tablature)" or "Bass
   Guitar (tablature)" - with the same number of strings. If your part is
   already a tablature-only instrument, skip this step.

The source is the staff you select (or, with nothing selected, the first
guitar/bass in the score, preferring standard notation), and its tuning
comes from that staff's instrument. Drums and other non-fretted
instruments are ignored.

- **Source is a tablature-only instrument** (e.g. a bass TAB with no
  notation): its strings and frets are re-fingered in place. Nothing else
  changes - stems, rests, and bars outside the selection stay as they are.
- **Source is standard notation**: the notes are copied to the first
  tablature-only instrument after it, so a score can hold guitar, bass and
  their TAB staves side by side. The plugin refuses to write when that TAB
  instrument has a different string count.

An in-place update is a single undo step (Ctrl+Z).

## Usage

Launch from **Plugins → Composing/arranging tools → FretPath**:

![Plugins menu](docs/images/run1.png)

The plugin dialog:

![FretPath dialog](docs/images/run2.png)

- **Run** — computes the fingering for the current selection (or the whole
  score if nothing is selected) and writes the TAB staff, overwriting
  previous contents.
- **Write to TAB staff** — the default output, written to the tablature
  instrument described above.
- **Write left-hand finger numbers / string numbers / positions
  (Roman numerals)** — optional annotations on the source staff.
- **Also write on notes with existing annotations** — overwrite manual
  annotations; off by default so your edits are preserved.
- **Diagnose** — prints collection and solver statistics without writing
  anything to the score.
- **Copy log** — copies the full report to the clipboard for bug reports.

## How it works
1. All four voices of the source staff are collected and merged into
   onset events; existing annotations become constraints.
2. Viterbi over states (fingering combo, hand position) finds the
   globally cheapest fingering. Cost terms: position-shift distance and
   count, quadratic penalty past the body joint, chord stretch, open
   string bonus, and deviation from annotated fingers.
3. The score is replicated to the TAB staff via MuseScore's own copy &
   paste (faithful voices, durations, ties); if paste is unavailable the
   plugin falls back to note-by-note entry.
4. Each note's string/fret is overwritten with the Viterbi result, stems
   are removed, rests hidden. A final pass re-reads the TAB staff and
   verifies that every collected note is present.

## Known limitations
- The TAB instrument must be added manually once: MuseScore's appendPart
  API does not apply tablature staff types (engraving/dom/score.cpp:4376
  copies only the line count from the instrument template).
- Chords whose annotations cannot be satisfied (e.g. natural harmonics)
  are skipped and reported.
- Grace notes are not fingered; on the TAB they reuse the last string/fret
  used for that pitch.
- The finger model is guitar-style (one finger per fret over four frets).
  For bass this only affects the finger numbers, not the TAB.
- Requires MuseScore Studio 4.4 or later.

## Node API
`fingering_core.js` is shared with the plugin; `index.js` loads it for Node
(18+), giving each instance its own tuning.

```js
const { createFretPath, fingerLine, TUNINGS } = require("./index.js");

// Pitches are MIDI numbers; an inner array is a chord.
fingerLine([29, 36, 41, 36], { tuning: TUNINGS.bass4, maxFret: 20 });
// -> [{position: 1, notes: [{midi: 29, string: 4, fret: 1, finger: 1}]}, ...]
//    string 1 is the highest string; null if any note is unplayable.

// Lower level: the same solver the plugin uses, with constraints.
const fp = createFretPath({ tuning: TUNINGS.bass5, maxFret: 24, bodyFret: 16,
                            weights: { W_MOVE: 2.0 } });
fp.solve([{ pitches: [{ midi: 33, string: 4, finger: null }] }]);
// -> [{combo: [[stringIdx, fret]], pos, fingers, barres}] (stringIdx 0 = lowest)
```

Tunings: `TUNINGS.guitar`, `bass4`, `bass5`, `bass6`. Run the tests with
`npm test`.

## License
GPL-3.0. Copyright (C) 2026 Kenji Noguchi <tokyo246@gmail.com>.
