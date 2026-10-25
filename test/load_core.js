// Loads fingering_core.js for Node tests. The core is written for the QML
// JS engine (".pragma library" directive); strip that line and evaluate the
// rest, exposing the internals under test.
'use strict';
const fs = require('fs');
const path = require('path');

const src = fs
    .readFileSync(path.join(__dirname, '..', 'fingering_core.js'), 'utf8')
    .replace(/^\.pragma[^\n]*\n/m, '');

module.exports = new Function(src + `
return {solve: solve, stringMarks: stringMarks,
        STRING_MARKS_OFF: STRING_MARKS_OFF, STRING_MARKS_ALWAYS: STRING_MARKS_ALWAYS,
        STRING_MARKS_CHANGE: STRING_MARKS_CHANGE};
`)();
