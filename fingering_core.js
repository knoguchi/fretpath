// fingering_core.js - guitar fingering core (port of mscx2tab.py).
// Copyright (C) 2026 Kenji Noguchi <tokyo246@gmail.com> - GPL-3.0
// Pure JavaScript, loadable from MuseScore QML and from Node.
//
// Method: Viterbi over states = (fingering combo, hand position).
//   - emission: only (string, fret) sets that produce the pitches (hard)
//   - transition: fixed shift cost + distance cost
//   - local: quadratic penalty past the body joint (12F), chord stretch,
//     open-string bonus
// String/finger annotations in the score are honored as constraints.
.pragma library

var TUNING = [40, 45, 50, 55, 59, 64];   // default: standard E2 A2 D3 G3 B3 E4 (low to high)
var MAX_FRET = 19;

// Inject the tuning read from the score (ascending, low to high)
function setTuning(arr, maxFret) {
    if (arr && arr.length >= 3) TUNING = arr.slice();
    if (maxFret && maxFret > 0) MAX_FRET = maxFret;
}
var MAX_POS = 16;
var MAX_CHORD_SPAN = 4;
var FINGER_TOL = 1;
var BODY_FRET = 12;

var W = {
    W_MOVE: 3.0,        // per unit of position-shift distance
    W_SHIFT: 1.5,       // fixed cost per shift
    W_BODY: 0.3,        // quadratic penalty past the body joint
    W_STRETCH: 2.0,     // fret span within a chord
    W_OPEN_BONUS: -0.1, // bonus for open strings
    W_FINGER_DEV: 1.0   // deviation from an annotated finger's home fret
};

var ROMAN = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII",
             "IX", "X", "XI", "XII", "XIII", "XIV", "XV", "XVI"];

// -- candidate enumeration -------------------------------
// note: {midi, string (1-6 or null), finger (0-4 or null)}
function candidatesForNote(note) {
    var out = [];
    var allowed;
    if (note.string) allowed = [TUNING.length - note.string];
    else { allowed = []; for (var a = 0; a < TUNING.length; a++) allowed.push(a); }
    for (var i = 0; i < allowed.length; i++) {
        var s = allowed[i];
        var f = note.midi - TUNING[s];
        if (f >= 0 && f <= MAX_FRET)
            out.push([s, f]);
    }
    return out;   // empty means unplayable
}

function candidatesForEvent(notes) {
    // notes must be sorted by descending pitch
    var perNote = [];
    for (var i = 0; i < notes.length; i++) {
        var c = candidatesForNote(notes[i]);
        if (c.length === 0) return [];
        perNote.push(c);
    }
    var results = [];
    function rec(idx, acc, used) {
        if (idx === perNote.length) {
            var frets = [];
            for (var j = 0; j < acc.length; j++)
                if (acc[j][1] > 0) frets.push(acc[j][1]);
            if (frets.length &&
                Math.max.apply(null, frets) - Math.min.apply(null, frets) > MAX_CHORD_SPAN)
                return;
            results.push(acc.slice());
            return;
        }
        for (var j = 0; j < perNote[idx].length; j++) {
            var sf = perNote[idx][j];
            if (used[sf[0]]) continue;
            // higher pitch on higher string (no crossing); annotated notes exempt
            if (idx > 0 && !notes[idx].string && !notes[idx - 1].string &&
                acc[idx - 1][0] <= sf[0]) continue;
            used[sf[0]] = true;
            acc.push(sf);
            rec(idx + 1, acc, used);
            acc.pop();
            used[sf[0]] = false;
        }
    }
    rec(0, [], {});
    return results;
}

// -- positions and finger constraints --------------------
function fingerDev(f, k, pos) { return Math.abs(f - (pos + k - 1)); }

function feasiblePositions(combo) {
    var frets = [];
    for (var i = 0; i < combo.length; i++)
        if (combo[i][1] > 0) frets.push(combo[i][1]);
    if (frets.length === 0) {
        var all = [];
        for (var p = 1; p <= MAX_POS; p++) all.push(p);
        return all;
    }
    var lo = Math.max(1, Math.max.apply(null, frets) - 3);
    var hi = Math.min.apply(null, frets);
    if (hi < lo) hi = lo;
    var out = [];
    for (var p = lo; p <= hi; p++) out.push(p);
    return out;
}

function allowedPositions(notes, combo) {
    var base = feasiblePositions(combo);
    var out = [];
    for (var b = 0; b < base.length; b++) {
        var p = base[b], ok = true;
        for (var i = 0; i < notes.length; i++) {
            var k = notes[i].finger;
            if (k === null || k === undefined) continue;
            var f = combo[i][1];
            if (k === 0) { if (f !== 0) { ok = false; break; } continue; }
            if (f === 0) { ok = false; break; }
            if (fingerDev(f, k, p) > FINGER_TOL) { ok = false; break; }
        }
        if (ok) out.push(p);
    }
    return out;
}

// -- costs -----------------------------------------------
function localCost(combo) {
    var c = 0.0, frets = [];
    for (var i = 0; i < combo.length; i++) {
        if (combo[i][1] > 0) frets.push(combo[i][1]);
        else c += W.W_OPEN_BONUS;
    }
    if (frets.length) {
        var mx = Math.max.apply(null, frets);
        var over = Math.max(0, mx - BODY_FRET);
        c += W.W_BODY * over * over;
        c += W.W_STRETCH * (mx - Math.min.apply(null, frets));
    }
    return c;
}

function shiftCost(p1, p2) {
    if (p1 === p2) return 0.0;
    return W.W_SHIFT + W.W_MOVE * Math.abs(p1 - p2);
}

// -- Viterbi ---------------------------------------------
// events: [{pitches: [note, ...]}] - pitches sorted by descending pitch
// returns: [{combo: [[s,f],...], pos, fingers: [k|null,...], barres}] or null
function solve(events) {
    var layers = [];
    for (var e = 0; e < events.length; e++) {
        var notes = events[e].pitches;
        var combos = candidatesForEvent(notes);
        var states = [];
        for (var c = 0; c < combos.length; c++) {
            var lc = localCost(combos[c]);
            var ps = allowedPositions(notes, combos[c]);
            for (var p = 0; p < ps.length; p++) {
                var dev = 0;
                for (var i = 0; i < notes.length; i++) {
                    var k = notes[i].finger;
                    if (k && combos[c][i][1] > 0)
                        dev += fingerDev(combos[c][i][1], k, ps[p]);
                }
                states.push({combo: combos[c], pos: ps[p],
                             lc: lc + W.W_FINGER_DEV * dev});
            }
        }
        if (states.length === 0) {
            // if finger annotations cannot be satisfied, continue without them
            for (var c2 = 0; c2 < combos.length; c2++) {
                var lc2 = localCost(combos[c2]);
                var ps2 = feasiblePositions(combos[c2]);
                for (var p2 = 0; p2 < ps2.length; p2++)
                    states.push({combo: combos[c2], pos: ps2[p2], lc: lc2});
            }
        }
        if (states.length === 0) return null;   // contains an unplayable note
        layers.push(states);
    }

    var n = layers.length;
    var cost = [], back = [];
    cost.push(layers[0].map(function (st) { return st.lc; }));
    back.push(layers[0].map(function () { return -1; }));
    for (var t = 1; t < n; t++) {
        // aggregate the previous layer by position (speed-up)
        var bestByPos = {};
        for (var k2 = 0; k2 < layers[t - 1].length; k2++) {
            var p3 = layers[t - 1][k2].pos;
            if (!(p3 in bestByPos) || cost[t - 1][k2] < bestByPos[p3].c)
                bestByPos[p3] = {c: cost[t - 1][k2], k: k2};
        }
        var ct = [], bt = [];
        for (var j = 0; j < layers[t].length; j++) {
            var st = layers[t][j];
            var best = Infinity, bestK = -1;
            for (var q in bestByPos) {
                var cand = bestByPos[q].c + shiftCost(parseInt(q), st.pos) + st.lc;
                if (cand < best) { best = cand; bestK = bestByPos[q].k; }
            }
            ct.push(best); bt.push(bestK);
        }
        cost.push(ct); back.push(bt);
    }

    var last = cost[n - 1];
    var j2 = 0;
    for (var i2 = 1; i2 < last.length; i2++) if (last[i2] < last[j2]) j2 = i2;
    var path = new Array(n);
    for (var t2 = n - 1; t2 >= 0; t2--) {
        path[t2] = layers[t2][j2];
        j2 = back[t2][j2];
    }

    // finger assignment and barre
    var out = [];
    for (var t3 = 0; t3 < n; t3++) {
        var asg = assignFingers(events[t3].pitches, path[t3].combo, path[t3].pos);
        out.push({combo: path[t3].combo, pos: path[t3].pos,
                  fingers: asg.fingers, barres: asg.barres});
    }
    return out;
}

// -- string numbers --------------------------------------
// Display modes (dialog radio order).
var STRING_MARKS_OFF = 0, STRING_MARKS_ALWAYS = 1, STRING_MARKS_CHANGE = 2;

// Which notes carry a string number under `mode`: per event, one boolean
// per note of the combo. Open strings are never marked (the TAB and the
// "0" say it). ALWAYS marks every fretted note. CHANGE follows the melody,
// the top note of each event (notes are sorted by descending pitch): it
// is marked when its string differs from the previous top note's. Inner
// chord notes are never marked; a chord shape implies its strings. An
// open top note is not marked but still counts as the string played.
function stringMarks(result, mode) {
    var out = [], prev = null;
    for (var i = 0; i < result.length; i++) {
        var combo = result[i].combo, marks = [];
        for (var j = 0; j < combo.length; j++) {
            var fretted = combo[j][1] > 0;
            if (mode === STRING_MARKS_ALWAYS) marks.push(fretted);
            else if (mode === STRING_MARKS_CHANGE && j === 0)
                marks.push(fretted && combo[0][0] !== prev);
            else marks.push(false);
        }
        if (combo.length) prev = combo[0][0];
        out.push(marks);
    }
    return out;
}

// -- finger assignment (barre-aware) ---------------------
function barreValid(finger, fret, strings, combo) {
    var smin = Math.min.apply(null, strings);
    var smax = Math.max.apply(null, strings);
    var covered = {};
    if (finger === 1) {
        for (var s = smin; s < TUNING.length; s++) covered[s] = true;
    } else {
        if (smax - smin !== 1) return false;
        covered[smin] = true; covered[smax] = true;
    }
    for (var i = 0; i < combo.length; i++) {
        var s2 = combo[i][0], f2 = combo[i][1];
        if (covered[s2] && f2 < fret) return false;
    }
    return true;
}

function assignFingers(notes, combo, pos) {
    var fretted = [];
    for (var i = 0; i < combo.length; i++)
        if (combo[i][1] > 0) fretted.push(i);
    var fingers = {};
    for (var a = 0; a < fretted.length; a++) {
        var i2 = fretted[a];
        if (notes[i2].finger) fingers[i2] = notes[i2].finger;
    }
    for (var b = 0; b < fretted.length; b++) {
        var i3 = fretted[b];
        if (i3 in fingers) continue;
        var f = combo[i3][1], s = combo[i3][0];
        var prefs = [];
        for (var k = 1; k <= 4; k++)
            if (fingerDev(f, k, pos) <= FINGER_TOL)
                prefs.push(k);
        prefs.sort(function (x, y) {
            var d = fingerDev(f, x, pos) - fingerDev(f, y, pos);
            return d !== 0 ? d : x - y;
        });
        var chosen = null;
        for (var pi = 0; pi < prefs.length; pi++) {
            var k2 = prefs[pi];
            var holders = [];
            for (var c = 0; c < fretted.length; c++)
                if (fingers[fretted[c]] === k2) holders.push(fretted[c]);
            if (holders.length === 0) { chosen = k2; break; }
            var sameFret = holders.every(function (h) { return combo[h][1] === f; });
            if (sameFret) {
                var ss = holders.map(function (h) { return combo[h][0]; });
                ss.push(s);
                if (barreValid(k2, f, ss, combo)) { chosen = k2; break; }
            }
        }
        if (chosen === null) {
            var used = {};
            for (var key in fingers) used[fingers[key]] = true;
            var free = [];
            for (var k3 = 1; k3 <= 4; k3++) if (!used[k3]) free.push(k3);
            if (free.length === 0) free = [1];
            chosen = free[0];
            for (var fi = 1; fi < free.length; fi++)
                if (fingerDev(f, free[fi], pos) < fingerDev(f, chosen, pos))
                    chosen = free[fi];
        }
        fingers[i3] = chosen;
    }
    var outF = [], groups = {};
    for (var i4 = 0; i4 < combo.length; i4++) {
        outF.push(i4 in fingers ? fingers[i4] : null);
        if (i4 in fingers) {
            var gk = fingers[i4] + ":" + combo[i4][1];
            if (!groups[gk]) groups[gk] = [];
            groups[gk].push(combo[i4][0]);
        }
    }
    var barres = [];
    for (var g in groups)
        if (groups[g].length > 1) {
            var parts = g.split(":");
            barres.push([parseInt(parts[0]), parseInt(parts[1]),
                         Math.min.apply(null, groups[g]),
                         Math.max.apply(null, groups[g])]);
        }
    return {fingers: outF, barres: barres};
}
