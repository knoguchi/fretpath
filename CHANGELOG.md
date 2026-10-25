# Changelog

## Unreleased

- Re-running no longer piles up annotations. Every annotation the plugin
  writes is recorded in a score meta tag (`fretPath`) and colored blue
  (or near-black #010101 with "Color new marks blue" off); a re-run removes
  and regenerates them. Before, position marks and string numbers were added
  again on every run, and the plugin's own finger numbers from the last run
  were read back as the user's constraints, so they could never change.
  An annotation the user edits is recolored black and honored as a
  constraint. A new **Clear** button removes the plugin's annotations.
- The TAB staff's fret numbers are written in the same blue (or near-black)
  as the annotations, so everything the plugin wrote looks alike.
- String numbers: Off / Always / When the string changes. The last one marks
  only the melody (the top note of each event) where its string changes;
  inner chord notes are never marked. String numbers are written in the
  String Number style (circled, read back as constraints) instead of the
  text "(3)".
- "Also write on notes with existing annotations" is now "Replace my own
  fingerings": on, the user's finger and string numbers are replaced, not
  written over.
- Dialog: one line names the source and TAB staves (a red warning when there
  is no TAB staff); shorter option labels; Diagnose is gone (a failed run
  includes the diagnosis); the status text follows the theme color, so it is
  readable in dark mode.
- Status: "Partly done: N of M notes fingered" and the bars left unfingered,
  instead of "Done" with a list of ticks. The TAB report is one line unless
  something went wrong.
- Position marks go on the processed staff. Before, they always went to
  staff 1.
- Node tests for the core (`npm test`) and CI.
