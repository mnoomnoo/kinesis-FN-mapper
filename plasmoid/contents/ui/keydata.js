.pragma library

// The KB800 FN-layer keys, in the same set fn_remap.py's DEFAULT_FN_ACTIONS
// exposes. `code` is the evdev KEY_* name (the config key); `group` drives the
// section headers in the editor.
var FN_KEYS = [
    { group: "Numpad overlay", code: "KEY_NUMLOCK",    label: "FN · NumLock" },
    { group: "Numpad overlay", code: "KEY_SCROLLLOCK", label: "FN · ScrollLock" },
    { group: "Numpad overlay", code: "KEY_INSERT",     label: "FN · Insert" },
    { group: "Numpad overlay", code: "KEY_KPSLASH",    label: "FN · /" },
    { group: "Numpad overlay", code: "KEY_KPASTERISK", label: "FN · *" },
    { group: "Numpad overlay", code: "KEY_KPMINUS",    label: "FN · -" },
    { group: "Numpad overlay", code: "KEY_KPPLUS",     label: "FN · +" },
    { group: "Numpad overlay", code: "KEY_KP7",        label: "FN · 7" },
    { group: "Numpad overlay", code: "KEY_KP8",        label: "FN · 8" },
    { group: "Numpad overlay", code: "KEY_KP9",        label: "FN · 9" },
    { group: "Numpad overlay", code: "KEY_KP4",        label: "FN · 4" },
    { group: "Numpad overlay", code: "KEY_KP5",        label: "FN · 5" },
    { group: "Numpad overlay", code: "KEY_KP6",        label: "FN · 6" },
    { group: "Numpad overlay", code: "KEY_KP1",        label: "FN · 1" },
    { group: "Numpad overlay", code: "KEY_KP2",        label: "FN · 2" },
    { group: "Numpad overlay", code: "KEY_KP3",        label: "FN · 3" },
    { group: "Numpad overlay", code: "KEY_KP0",        label: "FN · 0" },
    { group: "Numpad overlay", code: "KEY_KPDOT",      label: "FN · ." },
    { group: "Media keys",     code: "KEY_MUTE",       label: "FN · Mute" },
    { group: "Media keys",     code: "KEY_VOLUMEDOWN", label: "FN · Vol −" },
    { group: "Media keys",     code: "KEY_VOLUMEUP",   label: "FN · Vol +" },
    { group: "Media keys",     code: "KEY_CALC",       label: "FN · Calc" }
];

// Factory defaults: every FN key passes through untouched, i.e. the keyboard's
// own native behaviour with nothing remapped. Same shape as the on-disk
// fn_map.json so it can be fed straight to buildRows() — an empty map means
// every key falls back to pass-through.
var DEFAULTS = {};

// Modifier keys, kept separate from remap targets: the editor exposes these as
// Ctrl/Alt/Shift/Super toggles rather than dropdown entries.
var MODIFIERS = ["KEY_LEFTCTRL", "KEY_LEFTALT", "KEY_LEFTSHIFT", "KEY_LEFTMETA"];

var MOD_META = [
    { code: "KEY_LEFTCTRL",  label: "Ctrl" },
    { code: "KEY_LEFTALT",   label: "Alt" },
    { code: "KEY_LEFTSHIFT", label: "Shift" },
    { code: "KEY_LEFTMETA",  label: "Super" }
];

// Curated remap targets. A flat, grouped list feeds one ComboBox (the group is
// folded into the label so no separator UI is needed).
function buildTargets() {
    var out = [];
    function add(group, code, label) { out.push({ group: group, code: code, label: label }); }

    add("Media", "KEY_PLAYPAUSE",     "Play / Pause");
    add("Media", "KEY_NEXTSONG",      "Next track");
    add("Media", "KEY_PREVIOUSSONG",  "Previous track");
    add("Media", "KEY_STOPCD",        "Stop");
    add("Media", "KEY_MUTE",          "Mute");
    add("Media", "KEY_VOLUMEUP",      "Volume up");
    add("Media", "KEY_VOLUMEDOWN",    "Volume down");
    add("Media", "KEY_BRIGHTNESSUP",  "Brightness up");
    add("Media", "KEY_BRIGHTNESSDOWN","Brightness down");

    for (var f = 1; f <= 24; f++)
        add("Function", "KEY_F" + f, "F" + f);

    var letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    for (var i = 0; i < letters.length; i++)
        add("Letter", "KEY_" + letters[i], letters[i]);

    var digitNames = ["KEY_1","KEY_2","KEY_3","KEY_4","KEY_5",
                      "KEY_6","KEY_7","KEY_8","KEY_9","KEY_0"];
    var digitLabels = ["1","2","3","4","5","6","7","8","9","0"];
    for (var d = 0; d < digitNames.length; d++)
        add("Digit", digitNames[d], digitLabels[d]);

    add("Navigation", "KEY_UP",       "Up");
    add("Navigation", "KEY_DOWN",     "Down");
    add("Navigation", "KEY_LEFT",     "Left");
    add("Navigation", "KEY_RIGHT",    "Right");
    add("Navigation", "KEY_HOME",     "Home");
    add("Navigation", "KEY_END",      "End");
    add("Navigation", "KEY_PAGEUP",   "Page Up");
    add("Navigation", "KEY_PAGEDOWN", "Page Down");
    add("Navigation", "KEY_INSERT",   "Insert");
    add("Navigation", "KEY_DELETE",   "Delete");

    add("Editing", "KEY_ENTER",     "Enter");
    add("Editing", "KEY_TAB",       "Tab");
    add("Editing", "KEY_ESC",       "Esc");
    add("Editing", "KEY_BACKSPACE", "Backspace");
    add("Editing", "KEY_SPACE",     "Space");

    add("Misc", "KEY_CALC", "Calculator");

    return out;
}

var TARGETS = buildTargets();

// Format each target for the ComboBox: "Play / Pause  (Media)".
function targetDisplay(t) { return t.label + "  (" + t.group + ")"; }

function targetIndex(code) {
    for (var i = 0; i < TARGETS.length; i++)
        if (TARGETS[i].code === code) return i;
    return -1;
}

function targetLabel(code) {
    var i = targetIndex(code);
    return i >= 0 ? TARGETS[i].label : code;
}

function isModifier(code) { return MODIFIERS.indexOf(code) !== -1; }

// --- visual numpad layout ---------------------------------------------------
// Drives the tile grid in main.qml, arranged to mirror the physical KB800 blue
// FN legends: an embedded keypad (digits with the operators down the right edge)
// beside a vertical FN column. NUMPAD_GRID is a matrix of KEY_* codes; "" is a
// gap. FN_COLUMN is the far-right stack (media then locks), matching the
// F9→Insert F-key column. Together these cover exactly the FN_KEYS set above.
var NUMPAD_GRID = [
    ["KEY_KP7", "KEY_KP8",   "KEY_KP9",     "KEY_KPASTERISK"],
    ["KEY_KP4", "KEY_KP5",   "KEY_KP6",     "KEY_KPMINUS"],
    ["KEY_KP1", "KEY_KP2",   "KEY_KP3",     "KEY_KPPLUS"],
    ["KEY_KP0", "KEY_KPDOT", "KEY_KPSLASH", ""]
];

var NUMPAD_SPAN = {};   // code -> column span (default 1); no spans in this layout

var FN_COLUMN = ["KEY_MUTE", "KEY_VOLUMEDOWN", "KEY_VOLUMEUP", "KEY_CALC",
                 "KEY_NUMLOCK", "KEY_SCROLLLOCK", "KEY_INSERT"];

// Short one-line badge describing an entry's current action, for the key tile.
// Empty string for a plain pass-through (the tile then reads as "unmapped").
function summary(entry) {
    if (!entry) return "";
    if (entry.type === "block") return "blocked";
    if (entry.type === "run")   return "⟳ " + (entry.cmd || "…");
    if (entry.type === "remap") {
        var mods = "";
        if (entry.mods.ctrl)  mods += "Ctrl+";
        if (entry.mods.alt)   mods += "Alt+";
        if (entry.mods.shift) mods += "Shift+";
        if (entry.mods.super) mods += "Super+";
        return "→ " + mods + targetLabel(entry.target);
    }
    return "";   // pass
}
