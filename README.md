# FretPath

Playable guitar fingering for MuseScore Studio 4.4+.

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

## Setup
1. Copy this folder to Documents/MuseScore4/Plugins and restart MuseScore.
2. Enable the plugin in Home > Plugins.
3. First time only: open the Instruments panel (I), search "tablature",
   and add "Classical Guitar (tablature)". The plugin treats the last
   staff as the TAB target.

## Usage
Run the plugin (Plugins menu). "Run" computes the fingering for the
selection (or the whole score) and writes the TAB staff, overwriting
previous contents. Optional checkboxes write finger numbers, string
numbers, and position marks (Roman numerals) as annotations on the
source staff. "Diagnose" prints collection and solver statistics without
writing. "Copy log" copies the full report to the clipboard.

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
- Requires MuseScore Studio 4.4 or later.

## License
GPL-3.0. Copyright (C) 2026 Kenji Noguchi <tokyo246@gmail.com>.
