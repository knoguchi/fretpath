// Unit tests for fingering_core.js - run with: npm test (node --test)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const core = require('./load_core.js');

// combo entry: [string (0 = low E), fret]
function ev(combo) { return {combo: combo}; }

const result = [
    ev([[4, 1]]),                    // C4 on B: first melody note
    ev([[4, 3]]),                    // D4 on B: same string
    ev([[5, 0]]),                    // open E: not marked, but the string changed
    ev([[5, 1], [3, 2], [1, 3]]),    // chord, top F on E: same string as before
    ev([[4, 3], [3, 2], [2, 3]]),    // chord, top on B: changed
    ev([[4, 1]]),                    // B again
    ev([[3, 2], [2, 2]])             // top on G: changed
];

test('stringMarks: off marks nothing', function () {
    core.stringMarks(result, core.STRING_MARKS_OFF).forEach(function (m) {
        assert.ok(m.every(function (x) { return !x; }));
    });
});

test('stringMarks: always marks every fretted note, never an open string', function () {
    assert.deepStrictEqual(core.stringMarks(result, core.STRING_MARKS_ALWAYS), [
        [true], [true], [false], [true, true, true], [true, true, true], [true], [true, true]
    ]);
});

test('stringMarks: change marks the top note where its string changes', function () {
    assert.deepStrictEqual(core.stringMarks(result, core.STRING_MARKS_CHANGE), [
        [true], [false], [false], [false, false, false], [true, false, false], [false],
        [true, false]
    ]);
});

test('stringMarks: on a solved line', function () {
    // E4 F4 G4 A4 B4: open E, then up the E string; the melody stays there
    const events = [64, 65, 67, 69, 71].map(function (m) {
        return {pitches: [{midi: m, string: null, finger: null}]};
    });
    const solved = core.solve(events);
    const marks = core.stringMarks(solved, core.STRING_MARKS_CHANGE);
    assert.strictEqual(marks.length, 5);
    const strings = solved.map(function (s) { return s.combo[0][0]; });
    for (let i = 0; i < 5; i++) {
        const fretted = solved[i].combo[0][1] > 0;
        const changed = i === 0 || strings[i] !== strings[i - 1];
        assert.strictEqual(marks[i][0], fretted && changed, 'note ' + i);
    }
});
