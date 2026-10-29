// index.js - Node entry point for fingering_core.js.
// Copyright (C) 2026 Kenji Noguchi <tokyo246@gmail.com> - GPL-3.0
//
// fingering_core.js is a QML library (it starts with ".pragma library") and
// keeps its tuning in module-level variables. This loader evaluates it in a
// fresh scope per call, so every instance has its own tuning and weights.
//
//   const { createFretPath, TUNINGS } = require("fretpath");
//   const fp = createFretPath({ tuning: TUNINGS.bass4, maxFret: 24 });
//   fp.solve([{ pitches: [{ midi: 29, string: null, finger: null }] }]);
"use strict";

const fs = require("fs");
const path = require("path");

const SOURCE = fs.readFileSync(path.join(__dirname, "fingering_core.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, "");

const EXPORTS = ["setTuning", "setOptions", "solve", "candidatesForEvent",
                 "candidatesForNote", "assignFingers", "roman", "W"];

function load() {
    return new Function(SOURCE + "\nreturn {" + EXPORTS.join(",")
        + ", tuning: function () { return TUNING.slice(); }"
        + ", maxFret: function () { return MAX_FRET; }, TUNINGS: TUNINGS};")();
}

// opts: {tuning: [midi low..high], maxFret, bodyFret, weights: {W_MOVE, ...}}
function createFretPath(opts) {
    const core = load();
    opts = opts || {};
    if (opts.tuning || opts.maxFret) core.setTuning(opts.tuning, opts.maxFret);
    core.setOptions(opts);
    return core;
}

// Convenience: an array of MIDI pitches or chords (arrays of pitches) in,
// [{notes: [{midi, string (1 = highest), fret, finger}], position}] out.
// Returns null if any event cannot be played.
function fingerLine(line, opts) {
    const core = createFretPath(opts);
    const nStrings = core.tuning().length;
    const events = line.map(function (ev) {
        const ps = Array.isArray(ev) ? ev : [ev];
        return {pitches: ps.slice().sort(function (a, b) { return b - a; })
            .map(function (m) { return {midi: m, string: null, finger: null}; })};
    });
    const result = core.solve(events);
    if (!result) return null;
    return result.map(function (r, i) {
        return {
            position: r.pos,
            notes: r.combo.map(function (sf, j) {
                return {midi: events[i].pitches[j].midi, string: nStrings - sf[0],
                        fret: sf[1], finger: r.fingers[j]};
            })
        };
    });
}

module.exports = {createFretPath, fingerLine, TUNINGS: load().TUNINGS};
