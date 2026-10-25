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
    width: 420
    height: 480

    onRun: {
        if (!curScore) {
            statusBody = "No score is open";
            return;
        }
        refreshTarget();
    }

    // Result or error shown under the version line in the status area, so a
    // copied status always carries the version (for issue reports).
    property string statusBody: ""

    // The staff being processed: the first staff of a range selection,
    // otherwise staff 1, whole. The last staff is the TAB target (a
    // selection on it is ignored, see collectEvents).
    property string summary: ""
    property bool hasTab: false

    // "<part name>" for a staff index, or "Staff n".
    function staffName(staffIdx) {
        try {
            var parts = curScore.parts;
            for (var pi = 0; pi < parts.length; pi++) {
                var part = parts[pi];
                var base = Math.floor(part.startTrack / 4);
                var nSt = Math.max(1, Math.round((part.endTrack - part.startTrack) / 4));
                if (staffIdx >= base && staffIdx < base + nSt)
                    return (staffIdx + 1) + ": "
                        + ("" + (part.partName || part.longName || "Staff")).trim();
            }
        } catch (e) {}
        return "Staff " + (staffIdx + 1);
    }

    // Re-read the selection (it may have changed while the dialog is open)
    // for the line above the options.
    function refreshTarget() {
        if (!curScore) { summary = ""; return; }
        var n = curScore.nstaves;
        hasTab = n >= 2;
        var c = curScore.newCursor();
        c.rewind(Cursor.SELECTION_START);
        var onSel = !!c.segment && !(hasTab && c.staffIdx === n - 1);
        var src = onSel ? c.staffIdx : 0;
        summary = (onSel ? "Selection: " : "Whole staff: ") + staffName(src)
            + (hasTab ? " \u2192 TAB " + staffName(n - 1) : "");
    }

    // Measure start ticks, ascending, built once per run. Used only to turn
    // ticks into bar numbers for the status window.
    property var measureStarts: []

    function buildMeasureStarts() {
        measureStarts = [];
        try {
            for (var m = curScore.firstMeasure; m; m = m.nextMeasure)
                measureStarts.push(m.firstSegment.tick);
        } catch (e) {
            measureStarts = [];
        }
    }

    // 1-based bar number containing tick, or 0 when unavailable.
    function measureNoAt(tick) {
        var ms = measureStarts;
        if (!ms || !ms.length) return 0;
        var lo = 0, hi = ms.length - 1, ans = 0;
        while (lo <= hi) {
            var mid = Math.floor((lo + hi) / 2);
            if (ms[mid] <= tick) { ans = mid; lo = mid + 1; }
            else hi = mid - 1;
        }
        return ans + 1;
    }

    // Collapses a sorted list of bar numbers into "3-7, 11, 20-24".
    function formatBarRanges(bars, maxRanges) {
        if (!bars.length) return "";
        var out = [], start = bars[0], prev = bars[0];
        for (var i = 1; i <= bars.length; i++) {
            var b = bars[i];
            if (i < bars.length && (b === prev || b === prev + 1)) { prev = b; continue; }
            out.push(start === prev ? "" + start : start + "-" + prev);
            if (i < bars.length) { start = b; prev = b; }
        }
        if (maxRanges && out.length > maxRanges)
            return out.slice(0, maxRanges).join(", ") + ", +" + (out.length - maxRanges) + " more";
        return out.join(", ");
    }

    // String-number mode: Core.STRING_MARKS_OFF / _ALWAYS / _CHANGE
    property int stringMarksMode: Core.STRING_MARKS_OFF

    property var voiceCounts: [0, 0, 0, 0]
    property var voiceEvents: [[], [], [], []]
    property int targetStaff: 0

    // -- ownership of plugin-written annotations ----------
    // Everything the plugin writes is recorded in a score meta tag
    // ("fretPath": JSON {v: 1, items: [[tick, pitch, kind, text, staff],
    // ...]}, kind "f"=finger, "s"=string, "p"=position mark, pitch -1 for
    // staff text) and tinted with markerColor. On re-run, annotations
    // matching their registry entry are removed and regenerated; a
    // plugin-written text the user has edited no longer matches and is
    // promoted to a user constraint. Marker-colored elements with no
    // registry slot (registry lost or ticks shifted) fall back to
    // plugin-owned. Annotations are written in autoColor (visible blue) or,
    // when colorize is unchecked, stealthColor (near-black); both are
    // recognized as plugin-owned. Promoted (user-edited) elements are
    // recolored to plain black.
    property string stealthColor: "#010101"
    property string autoColor: "#0065bf"
    property var pluginEls: []     // elements to remove on this run
    property var promotedEls: []   // edited by user: recolor to black
    property var registry: null

    function loadRegistry() {
        var reg = {items: [], consumed: [], byKey: {}, byKind: {}};
        try {
            var raw = curScore.metaTag("fretPath");
            if (raw) reg.items = JSON.parse(raw).items || [];
        } catch (e) { reg.items = []; }
        for (var i = 0; i < reg.items.length; i++) {
            var it = reg.items[i];
            var key = it[4] + "|" + it[0] + "|" + it[1] + "|" + it[2] + "|" + it[3];
            if (!reg.byKey[key]) reg.byKey[key] = [];
            reg.byKey[key].push(i);
            reg.byKind[it[4] + "|" + it[0] + "|" + it[1] + "|" + it[2]] = true;
            reg.consumed.push(false);
        }
        return reg;
    }

    // Registry items not consumed this run (e.g. outside the selection)
    // survive; consumed ones are replaced by newItems.
    function saveRegistry(newItems) {
        var items = [];
        for (var q = 0; q < registry.items.length; q++)
            if (!registry.consumed[q]) items.push(registry.items[q]);
        items = items.concat(newItems);
        curScore.setMetaTag("fretPath", JSON.stringify({v: 1, items: items}));
        return items.length - newItems.length;
    }

    function isMarkerColored(el) {
        var c = ("" + el.color).toLowerCase();   // "#rrggbb" or "#aarrggbb"
        if (c.length < 7) return false;
        var hex = c.substr(c.length - 6);
        return hex === stealthColor.substr(1) || hex === autoColor.substr(1);
    }

    // "plugin" = remove and regenerate; "human" = honor as constraint.
    function classifyAnnotation(reg, el, tick, pitch, kind, text) {
        var idxs = reg.byKey[targetStaff + "|" + tick + "|" + pitch + "|" + kind + "|" + text];
        if (idxs) {
            for (var i = 0; i < idxs.length; i++)
                if (!reg.consumed[idxs[i]]) { reg.consumed[idxs[i]] = true; return "plugin"; }
        }
        if (isMarkerColored(el)) {
            // registered slot with different text = user edited it
            if (reg.byKind[targetStaff + "|" + tick + "|" + pitch + "|" + kind]) {
                promotedEls.push(el);
                return "human";
            }
            return "plugin";
        }
        return "human";
    }

    // Recolors user-edited annotations black and removes the plugin's
    // previous ones (collected by collectEvents). Runs before the TAB
    // copy, so stale marks are not pasted onto the TAB staff.
    function removePluginAnnotations() {
        curScore.startCmd();
        for (var pr = 0; pr < promotedEls.length; pr++) {
            try { promotedEls[pr].color = "#000000"; } catch (e) {}
        }
        var removed = 0;
        for (var r = 0; r < pluginEls.length; r++) {
            try { removeElement(pluginEls[r]); removed++; } catch (e2) {}
        }
        curScore.endCmd();
        return removed;
    }

    // -- clear plugin annotations ------------------------
    // Removes all plugin-owned annotations in the selection (or the whole
    // staff) and updates the registry. Manual annotations are untouched
    // unless "Replace my own fingerings" is checked.
    function clearAnnotations() {
        if (!curScore) { statusBody = "No score is open"; return; }
        collectEvents();   // classifies annotations into pluginEls/promotedEls
        var removed = removePluginAnnotations();
        curScore.startCmd();
        var kept = saveRegistry([]);
        curScore.endCmd();
        statusBody = "Cleared " + removed + " plugin annotation"
            + (removed === 1 ? "" : "s")
            + (kept ? " (" + kept + " outside the selection kept)" : "");
    }
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
        targetStaff = staffIdx;
        registry = loadRegistry();
        pluginEls = [];
        promotedEls = [];
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
                // plugin-written position marks live on segments
                if (voice === 0 && cursor.segment.annotations) {
                    var anns = cursor.segment.annotations;
                    for (var an = 0; an < anns.length; an++) {
                        var a = anns[an];
                        if (!a || a.type !== Element.STAFF_TEXT) continue;
                        if (a.track !== undefined && Math.floor(a.track / 4) !== staffIdx) continue;
                        var ptxt = ("" + a.text).replace(/<[^>]*>/g, "").trim();
                        if (!Core.isPositionMark(ptxt)) continue;
                        if (classifyAnnotation(registry, a, cursor.tick, -1, "p", ptxt) === "plugin")
                            pluginEls.push(a);
                    }
                }
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
                        var t = cursor.tick;
                        var ann = readAnnotations(note, t);
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
    // string numbers from finger numbers; without it treat 0-4 as fingers.
    // Plugin-owned annotations (see classifyAnnotation) are queued for
    // removal instead and never become constraints.
    function readAnnotations(note, tick) {
        var out = {string: null, finger: null};
        if (!note.elements) return out;
        var plainDigits = [], humanEls = [];
        for (var i = 0; i < note.elements.length; i++) {
            var el = note.elements[i];
            if (el.type !== Element.FINGERING) continue;
            var txt = ("" + el.text).replace(/<[^>]*>/g, "").trim();
            // "(3)": string number written without the String Number style
            var paren = /^\([1-9]\)$/.test(txt);
            if (!paren && !/^[0-9]$/.test(txt)) continue;
            var isString = paren;
            try {
                // MuseScore 4: subStyle (if available) distinguishes string numbers
                if (el.subStyle !== undefined && typeof Tid !== "undefined" &&
                    el.subStyle === Tid.STRING_NUMBER)
                    isString = true;
            } catch (e) { /* tolerate API differences */ }
            if (classifyAnnotation(registry, el, tick, note.pitch,
                                   isString ? "s" : "f", txt) === "plugin") {
                pluginEls.push(el);
                continue;
            }
            humanEls.push(el);
            if (paren) continue;   // hand-written "(3)": no constraint
            var v = parseInt(txt);
            if (isString && v >= 1 && v <= Core.TUNING.length) out.string = v;
            else plainDigits.push(v);
        }
        // A single style-less digit is trusted as a finger number. Multiple
        // digits likely mean finger+string side by side; ignore to avoid
        // misreading
        if (plainDigits.length === 1 && plainDigits[0] <= 4)
            out.finger = plainDigits[0];
        // Replace mode: the user's own finger/string annotations are
        // removed and regenerated too.
        if (overwrite.checked && humanEls.length) {
            for (var r = 0; r < humanEls.length; r++) pluginEls.push(humanEls[r]);
            out.string = null;
            out.finger = null;
        }
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
        log("FretPath v" + plugin.version + " / MuseScore " + (mscoreVersion !== undefined ? mscoreVersion : "?"));
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

    function fixupTab(tabStaff, asg, color) {
        // overwrite string/fret + remove stems + hide rests (tie continuations carried);
        // the fret numbers take the marker color like every plugin annotation
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
                            note.color = color;
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

    function writeTab(asg, color) {
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
        var fx = fixupTab(tabStaff, asg, color);

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
        if (!fx.setFail && !missing.length)
            return "TAB: " + fx.written + " notes written";
        return pre + steps.join("\n")
            + "\nString/fret overwrite: " + fx.written
            + (fx.setFail ? " / set failed " + fx.setFail : "")
            + (missing.length ? "\nVerify: MISSING " + missing.join(", ") : "");
    }

    // -- annotation writing ------------------------------
    function apply() {
        if (!curScore) { statusBody = "No score is open"; return; }
        trace = [];
        var tuningMsg = applyTuningFromScore();
        var events = collectEvents();
        if (events.length === 0) { statusBody = "No notes found"; return; }
        // note.pitch is the sounding pitch (verified on treble+8 scores)
        // events whose annotations cannot be satisfied (e.g. harmonics) are skipped
        buildMeasureStarts();
        var skippedBars = [];
        var solvable = [];
        var noteCount = 0, solvedNotes = 0;
        for (var si = 0; si < events.length; si++) {
            noteCount += events[si].pitches.length;
            if (Core.candidatesForEvent(events[si].pitches).length === 0)
                skippedBars.push(measureNoAt(events[si].tick));
            else {
                solvable.push(events[si]);
                solvedNotes += events[si].pitches.length;
            }
        }
        if (solvable.length === 0) {
            statusBody = "No solvable events";
            return;
        }
        var result = Core.solve(solvable);
        if (!result) {
            statusBody = "Viterbi found no solution. Please copy this and report it at\n"
                + "https://github.com/knoguchi/fretpath/issues\n\n" + diagnose();
            return;
        }
        events = solvable;
        removePluginAnnotations();
        var markerColor = colorize.checked ? autoColor : stealthColor;
        var newItems = [];
        var tabMsg = "";
        if (writeTabOpt.checked && !hasTab)
            tabMsg = "\nTAB not written: no TAB staff";
        else if (writeTabOpt.checked) try {
            var asg = {};
            for (var ri = 0; ri < result.length; ri++)
                for (var rj = 0; rj < events[ri].pitches.length; rj++)
                    asg[events[ri].tick + ":" + events[ri].pitches[rj].midi] =
                        [result[ri].combo[rj][0], result[ri].combo[rj][1]];
            tabMsg = "\n" + writeTab(asg, markerColor);
        } catch (e) {
            tabMsg = "\nException while writing TAB: " + e + " " + (e.stack || "");
        }
        curScore.startCmd();
        var prevPos = null;
        var cursor = curScore.newCursor();
        cursor.staffIdx = targetStaff; cursor.voice = 0;
        var nFing = 0, nSkipAnnotated = 0, nOpen = 0, nStr = 0, nPos = 0;
        var markString = Core.stringMarks(result, stringMarksMode);
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
                        fing.color = markerColor;
                        noteRefs[0].add(fing);
                        newItems.push([events[i].tick, events[i].pitches[j].midi, "f",
                                       fing.text, targetStaff]);
                        nFing++;
                    }
                }
                if (markString[i][j] &&
                    (events[i].pitches[j].string === null || overwrite.checked)) {
                    var sn = newElement(Element.FINGERING);
                    // String Number text style: MuseScore draws the circle,
                    // and readAnnotations recognizes it as a string number.
                    var styled = false;
                    try {
                        if (typeof Tid !== "undefined") {
                            sn.subStyle = Tid.STRING_NUMBER;
                            styled = true;
                        }
                    } catch (e3) {}
                    var stringNum = Core.TUNING.length - s;
                    sn.text = styled ? "" + stringNum : "(" + stringNum + ")";
                    sn.color = markerColor;
                    noteRefs[0].add(sn);
                    newItems.push([events[i].tick, events[i].pitches[j].midi, "s",
                                   sn.text, targetStaff]);
                    nStr++;
                }
            }
            if (writePositions.checked && st.pos !== prevPos) {
                var fretted = st.combo.some(function (c) { return c[1] > 0; });
                if (fretted) {
                    cursor.rewindToTick(events[i].tick);
                    var stx = newElement(Element.STAFF_TEXT);
                    stx.text = Core.ROMAN[st.pos];
                    stx.color = markerColor;
                    cursor.add(stx);
                    newItems.push([events[i].tick, -1, "p", stx.text, targetStaff]);
                    prevPos = st.pos;
                    nPos++;
                }
            }
        }
        if (trace.length)
            tabMsg += "\n--- input trace (opening) ---\n" + trace.join("\n");


        saveRegistry(newItems);
        curScore.endCmd();
        var head = skippedBars.length
            ? "Partly done: " + solvedNotes + " of " + noteCount + " notes fingered, "
            : "Done: " + noteCount + " notes, ";
        statusBody = head + tuningMsg + "\n"
            + (skippedBars.length ? "Not fingered in bars "
                + formatBarRanges(skippedBars, 12)
                + " (no string and fret fits the note and its annotations;"
                + " out of range or a harmonic?)\n" : "")
            + "Fingers " + nFing
            + (stringMarksMode !== Core.STRING_MARKS_OFF ? ", strings " + nStr : "")
            + (writePositions.checked ? ", positions " + nPos : "")
            + tabMsg;
    }

    // -- UI ----------------------------------------------
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 6
        Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.bold: true
            color: writeFingers.palette.windowText
            text: plugin.summary
        }
        Text {
            visible: writeTabOpt.checked && !plugin.hasTab
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: "#d32f2f"
            font.bold: true
            text: "No TAB staff: add \"Classical Guitar (tablature)\" in Instruments (I)"
        }
        CheckBox {
            id: writeTabOpt; checked: true
            text: "TAB staff"
            ToolTip.visible: hovered; ToolTip.delay: 400
            ToolTip.text: "Copies the notes to the last staff and sets their string and fret"
        }
        CheckBox { id: writeFingers;   checked: false; text: "Finger numbers" }
        CheckBox { id: writePositions; checked: false; text: "Positions (I, II, III...)" }
        RowLayout {
            Layout.fillWidth: true
            Text {
                text: "String numbers:"
                Layout.alignment: Qt.AlignTop
                topPadding: 10        // lines up with the first row of radios
                color: writeFingers.palette.windowText
            }
            ButtonGroup { id: stringMarksGroup }
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    // index order = Core.STRING_MARKS_OFF / _ALWAYS / _CHANGE
                    model: ["Off", "Always", "When the string changes"]
                    RadioButton {
                        ButtonGroup.group: stringMarksGroup
                        text: modelData
                        checked: plugin.stringMarksMode === index
                        onClicked: plugin.stringMarksMode = index
                        ToolTip.visible: hovered && index === Core.STRING_MARKS_CHANGE
                        ToolTip.delay: 400
                        ToolTip.text: "Melody only: the top note, where its string changes. Chord inner notes are not marked."
                    }
                }
            }
        }
        CheckBox { id: colorize;       checked: true;  text: "Color new marks blue" }
        CheckBox {
            id: overwrite; checked: false
            text: "Replace my own fingerings"
            ToolTip.visible: hovered; ToolTip.delay: 400
            ToolTip.text: "Off: fingerings you wrote are kept and used as constraints"
        }
        RowLayout {
            Button {
                text: "Run"
                onClicked: {
                    statusBody = "Running...";
                    plugin.refreshTarget();
                    try { plugin.apply(); }
                    catch (e) { statusBody = "Exception while running: " + e + "\n" + (e.stack || "")
                        + "\nPlease report: https://github.com/knoguchi/fretpath/issues"; }
                }
            }
            Button {
                text: "Clear"
                onClicked: {
                    plugin.refreshTarget();
                    try { plugin.clearAnnotations(); }
                    catch (e) { statusBody = "Exception while clearing: " + e + "\n" + (e.stack || "")
                        + "\nPlease report: https://github.com/knoguchi/fretpath/issues"; }
                }
            }
            Button {
                text: "Copy"
                onClicked: {
                    // Selecting by mouse does not copy in a plugin dialog on every platform.
                    statusText.forceActiveFocus();
                    statusText.selectAll();
                    statusText.copy();
                    // Fallback if the clipboard does not take it: save it to a file.
                    var saved = plugin.dumpLog(statusText.text);
                    if (saved.charAt(0) !== "(")
                        statusBody = statusBody + "\n(copied; also saved to " + saved + ")";
                }
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
                text: "v" + plugin.version + (plugin.statusBody ? "\n" + plugin.statusBody : "")
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                color: writeFingers.palette.windowText
            }
        }
    }
}
