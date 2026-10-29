"use strict";
const test = require("node:test");
const assert = require("node:assert");
const { createFretPath, fingerLine, TUNINGS } = require("..");

// [string, fret] per note, string 1 = highest, ordered by ascending pitch
function frets(step) {
    return step.notes.slice().sort(function (a, b) { return a.midi - b.midi; })
        .map(function (n) { return [n.string, n.fret]; });
}

test("bass4: root-fifth-octave in F stays in first position", function () {
    const r = fingerLine([29, 36, 41, 36], { tuning: TUNINGS.bass4, maxFret: 20 });
    assert.deepStrictEqual(r.map(frets), [[[4, 1]], [[3, 3]], [[2, 3]], [[3, 3]]]);
    assert.deepStrictEqual(r.map(function (s) { return s.position; }), [1, 1, 1, 1]);
});

test("bass5: open E preferred over B string fret 5", function () {
    const r = fingerLine([28], { tuning: TUNINGS.bass5, maxFret: 24 });
    assert.deepStrictEqual(frets(r[0]), [[4, 0]]);
});

test("bass4: positions above XVI are reachable and named", function () {
    const r = fingerLine([60, 62, 64], { tuning: TUNINGS.bass4, maxFret: 24 });
    assert.ok(r, "line should be playable with 24 frets");
    assert.deepStrictEqual(frets(r[2]), [[1, 21]]);
    const core = createFretPath();
    assert.ok(r[2].position >= 18);
    assert.strictEqual(core.roman(r[2].position).length > 0, true);
});

test("notes above the last fret or below the lowest string are unplayable", function () {
    assert.strictEqual(fingerLine([64], { tuning: TUNINGS.bass4 }), null);   // default 19 frets
    assert.strictEqual(fingerLine([24], { tuning: TUNINGS.bass4 }), null);   // C1 on 4-string
});

test("roman numerals", function () {
    const core = createFretPath();
    assert.deepStrictEqual([1, 4, 9, 14, 16, 19, 24].map(core.roman),
        ["I", "IV", "IX", "XIV", "XVI", "XIX", "XXIV"]);
});

test("instances do not share tuning", function () {
    const bass = createFretPath({ tuning: TUNINGS.bass4, maxFret: 24 });
    const guitar = createFretPath({ tuning: TUNINGS.guitar });
    assert.deepStrictEqual(bass.tuning(), TUNINGS.bass4);
    assert.deepStrictEqual(guitar.tuning(), TUNINGS.guitar);
    assert.strictEqual(bass.maxFret(), 24);
    assert.strictEqual(guitar.maxFret(), 19);
});

test("guitar: open C major chord", function () {
    const r = fingerLine([[48, 52, 55, 60, 64]], { tuning: TUNINGS.guitar });
    assert.deepStrictEqual(frets(r[0]), [[5, 3], [4, 2], [3, 0], [2, 1], [1, 0]]);
});

test("annotated string is honored", function () {
    const core = createFretPath({ tuning: TUNINGS.bass4, maxFret: 20 });
    // A1 forced onto the E string (string 4): fret 5 instead of open A
    const r = core.solve([{ pitches: [{ midi: 33, string: 4, finger: null }] }]);
    assert.deepStrictEqual(r[0].combo, [[0, 5]]);
});
