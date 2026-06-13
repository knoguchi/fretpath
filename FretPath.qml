// FretPath - automatic guitar fingering for MuseScore Studio 4.4+
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
import FileIO 3.0
import "fingering_core.js" as Core

MuseScore {
    id: plugin
    version: "1.0.0"
    title: "FretPath"
    description: "Computes playable guitar fingering (string/fret/finger/position) with dynamic programming and writes a TAB staff."
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
    FileIO { id: logFile }

    property var trace: []
    function dumpLog(text) {
        // FileIO in 4.4 restricts writable locations; try likely-allowed places in order
        var candidates = [];
        try { candidates.push(logFile.tempPath() + "/FretPath_log.txt"); } catch (e) {}
        try { candidates.push(logFile.homePath()
              + "/Documents/MuseScore4/FretPath_log.txt"); } catch (e) {}
        candidates.push(Qt.resolvedUrl("FretPath_log.txt")
                        .toString().replace("file://", ""));
        var errs = [];
        for (var i = 0; i < candidates.length; i++) {
            try {
                logFile.source = candidates[i];
                logFile.write(text);
                if (logFile.read() && logFile.read().length > 0)
                    return candidates[i];
            } catch (e) { errs.push(candidates[i] + ": " + e); }
        }
        return "(all candidates failed: " + errs.join(" / ") + ")";
    }
    function tlog(s) { trace.push(s); console.log("[FretPath] " + s); }
    property int traceTickMax: 1920 * 2      // default: trace roughly the first 3 measures

    // -- score scanning ----------------------------------
    // returns: [{tick, pitches: [{midi, string, finger, refs: [Note,...]}]}]
    function collectEvents() {
        var cursor = curScore.newCursor();
        cursor.rewind(Cursor.SELECTION_START);
        var staffIdx = 0, endTick = -1;
        // Ignore a selection that sits on the TAB staff (the last staff);
        // a stale selection there would make us collect from the empty staff
        if (cursor.segment && curScore.nstaves >= 2 &&
            cursor.staffIdx === curScore.nstaves - 1) {
            curScore.selection.clear();
            cursor.rewind(Cursor.SELECTION_START);
        }
        if (cursor.segment) {                       // a selection exists
            staffIdx = cursor.staffIdx;
            var c2 = curScore.newCursor();
            c2.rewind(Cursor.SELECTION_END);
            endTick = c2.tick === 0 ? curScore.lastSegment.tick + 1 : c2.tick;
        }
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
            if (isString && v >= 1 && v <= 6) out.string = v;
            else plainDigits.push(v);
        }
        // A single style-less digit is trusted as a finger number. Multiple
        // digits likely mean finger+string side by side; ignore to avoid
        // misreading
        if (plainDigits.length === 1 && plainDigits[0] <= 4)
            out.finger = plainDigits[0];
        return out;
    }

    // Read the tuning from the score and inject it into the core. Returns a display string
    function applyTuningFromScore() {
        try {
            var part = curScore.parts[0];           // part of the source staff
            var inst = part.instrumentAtTick(0);
            var sd = inst.stringData;
            if (sd && sd.strings && sd.strings.length >= 3) {
                var pitches = [];
                for (var i = 0; i < sd.strings.length; i++)
                    pitches.push(sd.strings[i].pitch);
                pitches.sort(function (a, b) { return a - b; });   // low to high
                Core.setTuning(pitches, sd.frets > 0 ? sd.frets : 19);
                var names = pitches.map(noteName).join(" ");
                var std = pitches.length === 6 && pitches.join(",") === "40,45,50,55,59,64";
                return "tuning: " + names
                     + (std ? "" : " (non-standard detected)");
            }
        } catch (e) {}
        Core.setTuning([40, 45, 50, 55, 59, 64], 19);
        return "tuning: standard (fallback)";
    }

    function noteName(midi) {
        var names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"];
        return names[midi % 12] + (Math.floor(midi / 12) - 1);
    }

    function unplayableReport(events) {
        var bad = [];
        for (var i = 0; i < events.length; i++)
            for (var j = 0; j < events[i].pitches.length; j++) {
                var m = events[i].pitches[j].midi;
                var lo = Core.TUNING[0];
                var hi = Core.TUNING[Core.TUNING.length - 1] + 19;
                if (m < lo || m > hi)
                    bad.push(noteName(m) + " (tick " + events[i].tick + ")");
            }
        return bad;
    }

    // -- diagnostics -------------------------------------
    function diagnose() {
        var lines = [];
        function log(s) { lines.push(s); console.log("[FretPath] " + s); }
        log("FretPath v1.0.0 / MuseScore " + (mscoreVersion !== undefined ? mscoreVersion : "?"));
        if (!curScore) { log("no score is open"); return lines.join("\n"); }
        log("score: " + curScore.scoreName + " / staves " + curScore.nstaves);
        log(applyTuningFromScore());
        var sel = curScore.newCursor();
        sel.rewind(Cursor.SELECTION_START);
        log("selection: " + (sel.segment ? ("yes (staffIdx " + sel.staffIdx + ")") : "none -> whole staff 0"));
        var events;
        try { events = collectEvents(); }
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
            + " / guitar sounding range is E2(40)-B5(83)");
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

    function ensureTabStaff() {
        if (curScore.nstaves >= 2) return "";
        return null;
    }

    // Two replication paths: (A) MuseScore's own copy & paste (faithful
    // incl. ties/tuplets where cmd works), or (B) note-by-note entry as a
    // proven fallback. Both are followed by the shared fixupTab pass.

    function pasteCopy(tabStaff, steps) {
        var lastTick = curScore.lastSegment.tick + 1;
        var r1 = curScore.selection.selectRange(0, lastTick, 0, 1);
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

    function fixupTab(tabStaff, asg) {
        // overwrite string/fret + remove stems + hide rests (tie continuations carried)
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
                    try { el.noStem = true; } catch (e9) {}
                    for (var n = 0; n < el.notes.length; n++) {
                        var note = el.notes[n];
                        var sf = asg[c.tick + ":" + note.pitch] || last[note.pitch];
                        if (!sf) { setFail++; continue; }
                        last[note.pitch] = sf;
                        var msStr = Core.TUNING.length - 1 - sf[0];
                        try {
                            note.string = msStr;
                            note.fret = sf[1];
                            if (note.string === msStr && note.fret === sf[1]) written++;
                            else setFail++;
                        } catch (e) { setFail++; }
                    }
                } else if (el && el.type === Element.REST) {
                    try { el.visible = false; } catch (e3) {}
                }
                c.next();
            }
        }
        curScore.endCmd();
        return {written: written, setFail: setFail};
    }

    function writeTab(asg) {
        var pre = ensureTabStaff();
        if (pre === null)
            return "No TAB staff. Open Instruments (I), search \"tablature\",\nadd \"Classical Guitar (tablature)\" and run again (first time only)";
        var tabStaff = curScore.nstaves - 1;
        var steps = [];
        var ok = false;
        try { ok = pasteCopy(tabStaff, steps); } catch (e) { steps.push("paste exception: " + e); }
        if (!ok) {
            steps.push("paste ineffective -> falling back to note entry");
            entryWrite(tabStaff, steps);
        }
        var fx = fixupTab(tabStaff, asg);

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
        trace = [];
        var tuningMsg = applyTuningFromScore();
        var events = collectEvents();
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
            tabMsg = "\n" + writeTab(asg);
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
                    stx.text = Core.ROMAN[st.pos];
                    cursor.add(stx);
                    prevPos = st.pos;
                }
            }
        }
        if (trace.length)
            tabMsg += "\n--- input trace (opening) ---\n" + trace.join("\n");
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
        CheckBox { id: writeTabOpt;    checked: true;  text: "Write to TAB staff (last staff is treated as TAB)" }
        CheckBox { id: writeFingers;   checked: false; text: "Write left-hand finger numbers" }
        CheckBox { id: writeStrings;   checked: false; text: "Write string numbers (1)-(6)" }
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
                text: "v1.0.0 - Run computes fingering and writes the TAB staff. First time only: add a tablature instrument (Instruments panel). Use Copy log to share results. Issues: github.com/knoguchi/fretpath"
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                color: "black"
            }
        }
    }
}
