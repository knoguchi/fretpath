// FretPath - automatic guitar and bass fingering for MuseScore Studio 4.4+
// Copyright (C) 2026 Kenji Noguchi <tokyo246@gmail.com>
// License: GPL-3.0 (see LICENSE)
// https://github.com/knoguchi/fretpath
//
// Scans the score, decides (string, fret, left-hand finger, position) for
// every note with Viterbi dynamic programming, and writes a TAB staff and/or
// annotations. Existing finger/string-number annotations are honored as
// hard constraints.
//
// Limitations: harmonics and grace notes are skipped; tie continuations are carried.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MuseScore 3.0
import "fingering_core.js" as Core

MuseScore {
    id: plugin
    version: "1.1.0"
    title: "FretPath"
    description: "Computes playable guitar or bass fingering (string/fret/finger/position) with dynamic programming and writes a TAB staff."
    categoryCode: "composing-arranging-tools"
    pluginType: "dialog"
    width: 380
    height: 420

    onRun: {
        if (!curScore) {
            statusText.text = "No score is open";
        }
    }

    property var voiceCounts: [0, 0, 0, 0]
    property var voiceEvents: [[], [], [], []]

    // -- parts and staves --------------------------------
    // Parts know their track range; a staff has 4 tracks
    function partOfStaff(staffIdx) {
        for (var i = 0; i < curScore.parts.length; i++) {
            var p = curScore.parts[i];
            if (p.startTrack <= staffIdx * 4 && staffIdx * 4 < p.endTrack) return p;
        }
        return null;
    }

    // A tablature instrument with no standard staff (e.g. "Bass Guitar (tablature)")
    function isTabOnly(part) {
        return !!part && part.hasTabStaff === true && part.hasPitchedStaff === false;
    }

    // Tuning of a part: {pitches (low to high), frets} or null for non-string instruments
    function stringDataOf(part) {
        try {
            var sd = part.instrumentAtTick(0).stringData;
            if (sd && sd.strings && sd.strings.length >= 3) {
                var pitches = [];
                for (var i = 0; i < sd.strings.length; i++)
                    pitches.push(sd.strings[i].pitch);
                pitches.sort(function (a, b) { return a - b; });
                return {pitches: pitches, frets: sd.frets > 0 ? sd.frets : 19};
            }
        } catch (e) {}
        return null;
    }

    // Some scores store a transposing instrument's string pitches as written
    // (e.g. bass E2 A2 D3 G3 with an octave-down transposition) while
    // note.pitch is sounding. Measure the offset from the frets a TAB staff
    // already has: pitch - (open string + fret), the most common value wins.
    function tuningOffset(staffIdx, pitches) {
        var counts = {}, best = 0, bestN = 0;
        var c = curScore.newCursor();
        c.staffIdx = staffIdx; c.voice = 0;
        c.rewind(Cursor.SCORE_START);
        c.staffIdx = staffIdx; c.voice = 0;
        while (c.segment) {
            var el = c.element;
            if (el && el.type === Element.CHORD)
                for (var n = 0; n < el.notes.length; n++) {
                    var nt = el.notes[n];
                    if (nt.string < 0 || nt.string >= pitches.length || nt.fret < 0) continue;
                    var off = nt.pitch - (pitches[pitches.length - 1 - nt.string] + nt.fret);
                    counts[off] = (counts[off] || 0) + 1;
                    if (counts[off] > bestN) { bestN = counts[off]; best = off; }
                }
            c.next();
        }
        return best;
    }

    // Without a selection: the first fretted instrument with standard notation,
    // else the first TAB-only one (which is then updated in place)
    function firstStringStaff() {
        var tabOnly = -1;
        for (var i = 0; i < curScore.parts.length; i++) {
            var p = curScore.parts[i];
            if (!stringDataOf(p)) continue;
            if (!isTabOnly(p)) return p.startTrack / 4;
            if (tabOnly < 0) tabOnly = p.startTrack / 4;
        }
        return tabOnly;
    }

    // TAB target: a TAB-only part, preferring the first one after the source
    // part. If this MuseScore does not expose hasTabStaff, fall back to the
    // last staff of the score if it is a fretted instrument (never drums)
    // other than the source part.
    function findTabStaff(srcPart) {
        var parts = curScore.parts, after = -1, any = -1, seen = false;
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i];
            if (p.startTrack === srcPart.startTrack) { seen = true; continue; }
            if (!isTabOnly(p)) continue;
            if (seen && after < 0) after = p.startTrack / 4;
            if (any < 0) any = p.startTrack / 4;
        }
        if (after >= 0) return after;
        if (any >= 0) return any;
        var last = curScore.nstaves - 1, lastPart = partOfStaff(last);
        if (parts.length && parts[0].hasTabStaff === undefined &&
            lastPart.startTrack !== srcPart.startTrack && stringDataOf(lastPart))
            return last;
        return -1;
    }

    // Decide the source staff and range, and load its tuning into the core.
    // A TAB-only source is updated in place instead of copied to another staff.
    // Returns {src, endTick, part, inPlace, msg} or {error}
    function setup() {
        var cursor = curScore.newCursor();
        cursor.rewind(Cursor.SELECTION_START);
        var src, endTick = -1;
        if (cursor.segment) {                       // a selection exists
            src = cursor.staffIdx;
            var c2 = curScore.newCursor();
            c2.rewind(Cursor.SELECTION_END);
            endTick = c2.tick === 0 ? curScore.lastSegment.tick + 1 : c2.tick;
        } else {
            src = firstStringStaff();
            if (src < 0)
                return {error: "No guitar or bass staff found. Select the staff to finger."};
        }
        var part = partOfStaff(src);
        var sd = part ? stringDataOf(part) : null;
        if (!sd)
            return {error: "The selected staff is not a fretted instrument (no string data).\n"
                         + "Select a guitar or bass staff."};
        var inPlace = isTabOnly(part);
        var offset = inPlace ? tuningOffset(src, sd.pitches) : 0;
        var tuning = sd.pitches.map(function (p) { return p + offset; });
        Core.setTuning(tuning, sd.frets);
        var msg = "staff " + (src + 1) + " (" + part.longName + "), tuning: "
                + tuning.map(noteName).join(" ") + ", " + sd.frets + " frets";
        if (offset) msg += " (stored as " + sd.pitches.map(noteName).join(" ")
                         + ", shifted " + offset + " to match the existing frets)";
        if (inPlace) msg += "\nTAB-only staff: updating its string/fret in place";
        return {src: src, endTick: endTick, part: part, inPlace: inPlace, msg: msg};
    }

    // -- score scanning ----------------------------------
    // returns: [{tick, pitches: [{midi, string, finger, refs: [Note,...]}]}]
    function collectEvents(staffIdx, endTick) {
        var cursor = curScore.newCursor();
        var byTick = {};
        voiceCounts = [0, 0, 0, 0];
        voiceEvents = [[], [], [], []];
        for (var voice = 0; voice < 4; voice++) {
            // IMPORTANT: set voice/staffIdx BEFORE rewind. In the reverse
            // order the walk ends immediately for voices that have no element
            // at the very first segment of the score
            cursor.staffIdx = staffIdx;
            cursor.voice = voice;
            cursor.rewind(endTick < 0 ? Cursor.SCORE_START : Cursor.SELECTION_START);
            cursor.staffIdx = staffIdx;
            cursor.voice = voice;
            while (cursor.segment && (endTick < 0 || cursor.tick < endTick)) {
                var el = cursor.element;
                if (el && el.type === Element.REST) {
                    voiceEvents[voice].push({tick: cursor.tick, rest: true,
                        mTick: cursor.measure ? cursor.measure.firstSegment.tick : -1,
                        dur: el.duration
                             ? {num: el.duration.numerator,
                                den: el.duration.denominator}
                             : {num: 1, den: 4}});
                }
                if (el && el.type === Element.CHORD) {
                    var t0 = cursor.tick;
                    // for writing: include tie continuations so the voice timeline is gapless
                    var vEv = {tick: t0, pitches: [], ties: [],
                               mTick: cursor.measure ? cursor.measure.firstSegment.tick : -1,
                               dur: el.duration
                                    ? {num: el.duration.numerator,
                                       den: el.duration.denominator}
                                    : {num: 1, den: 4}};
                    for (var i0 = 0; i0 < el.notes.length; i0++) {
                        vEv.pitches.push(el.notes[i0].pitch);
                        if (el.notes[i0].tieBack) vEv.ties.push(el.notes[i0].pitch);
                    }
                    voiceEvents[voice].push(vEv);
                    for (var i = 0; i < el.notes.length; i++) {
                        var note = el.notes[i];
                        if (note.tieBack) continue;          // excluded from fingering computation
                        voiceCounts[voice]++;
                        var ann = readAnnotations(note);
                        var t = cursor.tick;
                        if (!byTick[t]) byTick[t] = {};
                        var p = note.pitch;
                        if (byTick[t][p]) {                   // merge duplicates across voices
                            byTick[t][p].refs.push(note);
                            if (byTick[t][p].string === null) byTick[t][p].string = ann.string;
                            if (byTick[t][p].finger === null) byTick[t][p].finger = ann.finger;
                        } else {
                            byTick[t][p] = {midi: p, string: ann.string,
                                            finger: ann.finger, refs: [note]};
                        }
                    }
                }
                cursor.next();
            }
        }
        var ticks = Object.keys(byTick).map(Number).sort(function (a, b) { return a - b; });
        var events = [];
        for (var ti = 0; ti < ticks.length; ti++) {
            var pitches = Object.keys(byTick[ticks[ti]])
                .map(function (k) { return byTick[ticks[ti]][k]; })
                .sort(function (a, b) { return b.midi - a.midi; });
            events.push({tick: ticks[ti], pitches: pitches});
        }
        return events;
    }

    // Read existing Fingering annotations. With style info we can tell
    // string numbers from finger numbers; without it treat 0-4 as fingers
    function readAnnotations(note) {
        var out = {string: null, finger: null};
        if (!note.elements) return out;
        var plainDigits = [];
        for (var i = 0; i < note.elements.length; i++) {
            var el = note.elements[i];
            if (el.type !== Element.FINGERING) continue;
            var txt = ("" + el.text).replace(/<[^>]*>/g, "").trim();
            if (!/^[0-9]$/.test(txt)) continue;
            var v = parseInt(txt);
            var isString = false;
            try {
                // MuseScore 4: subStyle (if available) distinguishes string numbers
                if (el.subStyle !== undefined && typeof Tid !== "undefined" &&
                    el.subStyle === Tid.STRING_NUMBER)
                    isString = true;
            } catch (e) { /* tolerate API differences */ }
            if (isString && v >= 1 && v <= Core.TUNING.length) out.string = v;
            else plainDigits.push(v);
        }
        // A single style-less digit is trusted as a finger number. Multiple
        // digits likely mean finger+string side by side; ignore to avoid
        // misreading
        if (plainDigits.length === 1 && plainDigits[0] <= 4)
            out.finger = plainDigits[0];
        return out;
    }

    function noteName(midi) {
        var names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];
        return names[midi % 12] + (Math.floor(midi / 12) - 1);
    }

    // -- diagnostics -------------------------------------
    function diagnose() {
        var lines = [];
        function log(s) { lines.push(s); console.log("[FretPath] " + s); }
        log("FretPath v1.1.0 / MuseScore " + (mscoreVersion !== undefined ? mscoreVersion : "?"));
        if (!curScore) { log("no score is open"); return lines.join("\n"); }
        log("score: " + curScore.scoreName + " / staves " + curScore.nstaves);
        var ctx = setup();
        if (ctx.error) { log(ctx.error); return lines.join("\n"); }
        log("source: " + ctx.msg + (ctx.endTick < 0 ? " (whole staff)" : " (selection)"));
        var tab = ctx.inPlace ? ctx.src : findTabStaff(ctx.part);
        log("TAB target: " + (tab < 0 ? "none found" : "staff " + (tab + 1)
            + " (" + partOfStaff(tab).longName + ")" + (ctx.inPlace ? ", in place" : "")));
        var events;
        try { events = collectEvents(ctx.src, ctx.endTick); }
        catch (e) { log("exception while collecting: " + e); return lines.join("\n"); }
        log("events: " + events.length);
        if (events.length === 0) return lines.join("\n");
        var lo = 999, hi = -1, maxNotes = 0, annStr = 0, annFing = 0;
        for (var i = 0; i < events.length; i++) {
            maxNotes = Math.max(maxNotes, events[i].pitches.length);
            for (var j = 0; j < events[i].pitches.length; j++) {
                var p = events[i].pitches[j];
                lo = Math.min(lo, p.midi); hi = Math.max(hi, p.midi);
                if (p.string !== null) annStr++;
                if (p.finger !== null) annFing++;
            }
        }
        log("pitch range: " + noteName(lo) + "(" + lo + ") - " + noteName(hi) + "(" + hi + ")"
            + " / instrument range is " + noteName(Core.TUNING[0]) + "(" + Core.TUNING[0] + ")-"
            + noteName(Core.TUNING[Core.TUNING.length - 1] + Core.MAX_FRET)
            + "(" + (Core.TUNING[Core.TUNING.length - 1] + Core.MAX_FRET) + ")");
        log("max simultaneous notes: " + maxNotes + " / annotations: strings " + annStr + " fingers " + annFing);
        log("notes per voice: " + voiceCounts.join(" / "));
        var shown = 0;
        for (var i2 = 0; i2 < events.length; i2++) {
            var ev = {pitches: events[i2].pitches};
            var combos = Core.candidatesForEvent(ev.pitches);
            if (combos.length === 0 && shown < 5) {
                shown++;
                var desc = ev.pitches.map(function (p3) {
                    var nc = Core.candidatesForNote(p3).length;
                    return noteName(p3.midi) + "(" + p3.midi + ", cand " + nc
                        + (p3.string ? ", string " + p3.string + " fixed" : "")
                        + (p3.finger !== null ? ", finger " + p3.finger : "") + ")";
                }).join(" + ");
                log("unsolvable event at tick " + events[i2].tick + ": " + desc);
            }
        }
        if (shown === 0) {
            var result = Core.solve(events);
            log(result ? "Viterbi: solution found (ready to write)" : "Viterbi: no solution (needs investigation)");
        }
        return lines.join("\n");
    }

    // -- writing the TAB staff ---------------------------
    // The last staff is treated as TAB. Voices are written separately with
    // their original durations. Chords within a voice are built with
    // chord.add(Note) instead of relying on addToChord.
    // MuseScore's internal string index: 0 = highest-pitched string.
    function tpcOf(pitch) {
        return [14, 21, 16, 23, 18, 13, 20, 15, 22, 17, 12, 19][pitch % 12];
    }

    // Two replication paths: (A) MuseScore's own copy & paste (faithful
    // incl. ties/tuplets where cmd works), or (B) note-by-note entry as a
    // proven fallback. Both are followed by the shared fixupTab pass.

    function pasteCopy(srcStaff, tabStaff, steps) {
        var lastTick = curScore.lastSegment.tick + 1;
        var r1 = curScore.selection.selectRange(0, lastTick, srcStaff, srcStaff + 1);
        steps.push("select source staff: " + r1);
        cmd("copy");
        var r2 = curScore.selection.selectRange(0, 1, tabStaff, tabStaff + 1);
        steps.push("select TAB start: " + r2);
        cmd("paste");
        curScore.selection.clear();
        var pasted = 0;
        var pc = curScore.newCursor();
        pc.staffIdx = tabStaff; pc.voice = 0;
        pc.rewind(Cursor.SCORE_START);
        pc.staffIdx = tabStaff; pc.voice = 0;
        while (pc.segment) {
            if (pc.element && pc.element.type === Element.CHORD) pasted++;
            pc.next();
        }
        steps.push("chords on TAB voice1 after paste: " + pasted);
        return pasted > 0;
    }

    function entryWrite(tabStaff, steps) {
        // note-by-note entry (per measure, rests included, chords via chord.add)
        curScore.startCmd();
        var added = 0;
        for (var v = 0; v < 4; v++) {
            var evs = voiceEvents[v];
            var cur = null, expectTick = -1, curM = -2;
            for (var i = 0; i < evs.length; i++) {
                var ev = evs[i];
                if (cur === null || ev.tick !== expectTick || ev.mTick !== curM) {
                    curM = ev.mTick;
                    cur = curScore.newCursor();
                    cur.rewindToTick(ev.tick);
                    cur.staffIdx = tabStaff;
                    cur.voice = v;
                }
                cur.setDuration(ev.dur.num, ev.dur.den);
                if (ev.rest) {
                    cur.addRest();
                } else {
                    cur.addNote(ev.pitches[0]);
                    added++;
                    if (ev.pitches.length > 1) {
                        var c2 = curScore.newCursor();
                        c2.rewindToTick(ev.tick);
                        c2.staffIdx = tabStaff;
                        c2.voice = v;
                        var ch = c2.element;
                        if (ch && ch.type === Element.CHORD)
                            for (var j = 1; j < ev.pitches.length; j++) {
                                var nn = newElement(Element.NOTE);
                                nn.pitch = ev.pitches[j];
                                nn.tpc1 = tpcOf(ev.pitches[j]);
                                nn.tpc2 = tpcOf(ev.pitches[j]);
                                ch.add(nn);
                                added++;
                            }
                    }
                }
                expectTick = ev.tick
                    + Math.round(1920 * ev.dur.num / ev.dur.den);
            }
        }
        curScore.endCmd();
        steps.push("note entry: " + added + " notes");
    }

    function fixupTab(tabStaff, asg, inPlace) {
        // overwrite string/fret (tie continuations carried). On a freshly
        // copied staff also remove stems and hide rests; in place, touch
        // nothing but the solved notes and their tie continuations
        curScore.startCmd();
        var written = 0, setFail = 0;
        var last = {};
        for (var v = 0; v < 4; v++) {
            var c = curScore.newCursor();
            c.staffIdx = tabStaff; c.voice = v;
            c.rewind(Cursor.SCORE_START);
            c.staffIdx = tabStaff; c.voice = v;
            while (c.segment) {
                var el = c.element;
                if (el && el.type === Element.CHORD) {
                    if (!inPlace) try { el.noStem = true; } catch (e9) {}
                    for (var n = 0; n < el.notes.length; n++) {
                        var note = el.notes[n];
                        var sf = asg[c.tick + ":" + note.pitch];
                        if (!sf && (!inPlace || note.tieBack)) sf = last[note.pitch];
                        if (!sf) { if (!inPlace) setFail++; continue; }
                        last[note.pitch] = sf;
                        var msStr = Core.TUNING.length - 1 - sf[0];
                        try {
                            note.string = msStr;
                            note.fret = sf[1];
                            if (note.string === msStr && note.fret === sf[1]) written++;
                            else setFail++;
                        } catch (e) { setFail++; }
                    }
                } else if (!inPlace && el && el.type === Element.REST) {
                    try { el.visible = false; } catch (e3) {}
                }
                c.next();
            }
        }
        curScore.endCmd();
        return {written: written, setFail: setFail};
    }

    function writeTab(asg, ctx) {
        if (ctx.inPlace) {
            var fxi = fixupTab(ctx.src, asg, true);
            return "Updated in place: " + fxi.written + " notes"
                + (fxi.setFail ? " / set failed " + fxi.setFail : "");
        }
        var tabStaff = findTabStaff(ctx.part);
        if (tabStaff < 0)
            return "No TAB staff. Open Instruments (I), search \"tablature\", add the\n"
                 + "matching tablature instrument (e.g. \"Bass Guitar (tablature)\")\n"
                 + "and run again (first time only)";
        var tabPart = partOfStaff(tabStaff);
        var tabSd = stringDataOf(tabPart);
        if (!tabSd || tabSd.pitches.length !== Core.TUNING.length)
            return "TAB staff " + (tabStaff + 1) + " (" + tabPart.longName + ") has "
                 + (tabSd ? tabSd.pitches.length : "no") + " strings but the source has "
                 + Core.TUNING.length + ". Add a tablature instrument with the same string count.";
        var pre = "TAB target: staff " + (tabStaff + 1) + " (" + tabPart.longName + ")\n";
        if (tabSd.pitches.join(",") !== Core.TUNING.join(","))
            pre += "Warning: TAB tuning " + tabSd.pitches.map(noteName).join(" ")
                 + " differs from the source tuning\n";
        var steps = [];
        var ok = false;
        try { ok = pasteCopy(ctx.src, tabStaff, steps); } catch (e) { steps.push("paste exception: " + e); }
        if (!ok) {
            steps.push("paste ineffective -> falling back to note entry");
            entryWrite(tabStaff, steps);
        }
        var fx = fixupTab(tabStaff, asg, false);

        // self-verification
        var missing = [];
        for (var v2 = 0; v2 < 4; v2++) {
            var tabByTick = {};
            var vc = curScore.newCursor();
            vc.staffIdx = tabStaff; vc.voice = v2;
            vc.rewind(Cursor.SCORE_START);
            vc.staffIdx = tabStaff; vc.voice = v2;
            while (vc.segment) {
                var e2 = vc.element;
                if (e2 && e2.type === Element.CHORD) {
                    var ps = {};
                    for (var n2 = 0; n2 < e2.notes.length; n2++)
                        ps[e2.notes[n2].pitch] = true;
                    tabByTick[vc.tick] = ps;
                }
                vc.next();
            }
            var evs2 = voiceEvents[v2];
            for (var i3 = 0; i3 < evs2.length; i3++) {
                if (evs2[i3].rest) continue;
                var got = tabByTick[evs2[i3].tick] || {};
                for (var j2 = 0; j2 < evs2[i3].pitches.length; j2++) {
                    var m = evs2[i3].pitches[j2];
                    if (!got[m] && missing.length < 8)
                        missing.push("voice " + (v2 + 1) + " " + noteName(m)
                                     + "@tick" + evs2[i3].tick);
                }
            }
        }
        return pre + steps.join("\n")
            + "\nString/fret overwrite: " + fx.written
            + (fx.setFail ? " / set failed " + fx.setFail : "")
            + (missing.length
               ? "\nVerify: MISSING " + missing.join(", ")
               : "\nVerify: all notes of all voices present on TAB");
    }

    // -- annotation writing ------------------------------
    function apply() {
        if (!curScore) { statusText.text = "No score is open"; return; }
        var ctx = setup();
        if (ctx.error) { statusText.text = ctx.error; return; }
        var tuningMsg = ctx.msg;
        var events = collectEvents(ctx.src, ctx.endTick);
        if (events.length === 0) { statusText.text = "No notes found"; return; }
        // note.pitch is the sounding pitch (verified on treble+8 scores)
        // events whose annotations cannot be satisfied (e.g. harmonics) are skipped
        var skipped = [];
        var solvable = [];
        for (var si = 0; si < events.length; si++) {
            if (Core.candidatesForEvent(events[si].pitches).length === 0)
                skipped.push(events[si].tick);
            else
                solvable.push(events[si]);
        }
        if (solvable.length === 0) {
            statusText.text = "No solvable events";
            return;
        }
        var result = Core.solve(solvable);
        if (!result) {
            statusText.text = "Viterbi found no solution. Please run Diagnose, then\n"
                + "report the output at https://github.com/knoguchi/fretpath/issues";
            return;
        }
        events = solvable;
        var tabMsg = "";
        if (writeTabOpt.checked) try {
            var asg = {};
            for (var ri = 0; ri < result.length; ri++)
                for (var rj = 0; rj < events[ri].pitches.length; rj++)
                    asg[events[ri].tick + ":" + events[ri].pitches[rj].midi] =
                        [result[ri].combo[rj][0], result[ri].combo[rj][1]];
            tabMsg = "\n" + writeTab(asg, ctx);
        } catch (e) {
            tabMsg = "\nException while writing TAB: " + e + " " + (e.stack || "");
        }
        curScore.startCmd();
        var prevPos = null;
        var cursor = curScore.newCursor();
        var nFing = 0, nSkipAnnotated = 0, nOpen = 0, nStr = 0;
        for (var i = 0; i < result.length; i++) {
            var st = result[i];
            for (var j = 0; j < events[i].pitches.length; j++) {
                var noteRefs = events[i].pitches[j].refs;
                var s = st.combo[j][0], f = st.combo[j][1], k = st.fingers[j];
                if (writeFingers.checked) {
                    if (k === null) nOpen++;
                    else if (events[i].pitches[j].finger !== null && !overwrite.checked)
                        nSkipAnnotated++;
                    else {
                        var fing = newElement(Element.FINGERING);
                        fing.text = "" + k;
                        noteRefs[0].add(fing);
                        nFing++;
                    }
                }
                if (writeStrings.checked && f > 0 &&
                    (events[i].pitches[j].string === null || overwrite.checked)) {
                    var sn = newElement(Element.FINGERING);
                    sn.text = "(" + (Core.TUNING.length - s) + ")"; // string number, ASCII
                    noteRefs[0].add(sn);
                    nStr++;
                }
            }
            if (writePositions.checked && st.pos !== prevPos) {
                var fretted = st.combo.some(function (c) { return c[1] > 0; });
                if (fretted) {
                    cursor.rewindToTick(events[i].tick);
                    var stx = newElement(Element.STAFF_TEXT);
                    stx.text = Core.roman(st.pos);
                    cursor.add(stx);
                    prevPos = st.pos;
                }
            }
        }
        console.log("[FretPath] === result ===\n" + tabMsg);

        curScore.endCmd();
        statusText.text = tuningMsg + "\n"
            + "Done: " + events.length + " events processed" + tabMsg
            + "\nFingers: wrote " + nFing
            + " / skipped annotated " + nSkipAnnotated
            + " / open strings (n/a) " + nOpen
            + (writeStrings.checked ? " / strings wrote " + nStr : "")

            + (skipped.length
               ? "\nSkipped " + skipped.length
                 + " events (tick " + skipped.join(", ")
                 + ") - no fingering satisfies the annotations; possibly harmonics"
               : "");
    }

    // -- UI ----------------------------------------------
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 8
        Label {
            text: "Computes fingering for the selection (or the whole score) and writes it.\nExisting finger/string annotations are honored as constraints."
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        CheckBox { id: writeTabOpt;    checked: true;  text: "Write to TAB staff (a tablature instrument in the score)" }
        CheckBox { id: writeFingers;   checked: false; text: "Write left-hand finger numbers" }
        CheckBox { id: writeStrings;   checked: false; text: "Write string numbers, e.g. (1)" }
        CheckBox { id: writePositions; checked: false; text: "Write positions (Roman numerals)" }
        CheckBox { id: overwrite;      checked: false; text: "Also write on notes with existing annotations" }
        RowLayout {
            Button {
                text: "Run"
                onClicked: {
                    statusText.text = "Running...";
                    try { plugin.apply(); }
                    catch (e) { statusText.text = "Exception while running: " + e + "\n" + (e.stack || "")
                        + "\nPlease report: https://github.com/knoguchi/fretpath/issues"; }
                }
            }
            Button {
                text: "Diagnose"
                onClicked: {
                    try {
                        statusText.text = plugin.diagnose();
                    }
                    catch (e) { statusText.text = "Exception in diagnostics: " + e + "\n" + (e.stack || "")
                        + "\nPlease report: https://github.com/knoguchi/fretpath/issues"; }
                }
            }
            Button {
                text: "Copy log"
                onClicked: { statusText.selectAll(); statusText.copy(); statusText.deselect(); }
            }
            Button { text: "Close"; onClicked: quit() }
        }
        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: statusText.height
            clip: true
            TextEdit {
                id: statusText
                width: parent.width
                text: "v1.1.0 - Select the guitar or bass staff, then Run to compute fingering and write the TAB staff. First time only: add a matching tablature instrument (Instruments panel). Use Copy log to share results. Issues: github.com/knoguchi/fretpath"
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                color: "black"
            }
        }
    }
}
