# ---------------------------------------------------------------------------
# saved_faces_370.py
# Shared face store for the 370-LED physical matrix.
# v1.5.6: firmware-side source of truth for WebUI face manager,
# order-preserving row numbering, lock state, and face type (default/custom/part).
# ---------------------------------------------------------------------------
# Import: Loads json so this module can use that dependency.
import json

# Variable: STORE_PATH stores the configured text value.
STORE_PATH = "saved_faces_370.json"
# Variable: RENAME_PATH stores the configured text value.
RENAME_PATH = "saved_faces_370_names.json"  # kept for migration compatibility
# Variable: MAX_FACES stores the configured literal value.
MAX_FACES = 99
# Variable: DEFAULT_FACES stores the collection of values used later in this module.
DEFAULT_FACES = [{'name': '惊讶眨眼大嘴', 'hex': '0000000000700408804044020020080100200000001002000000006180027900080400402004F20030C0000000000'}, {'name': '眼镜方嘴', 'hex': '00000000000000000000300301A0160780780C00E000014000020000000000000FFC00402003FC000000000000000'}, {'name': '困惑挑眉', 'hex': '0000000000000000000000000000000800041E01E000000000000A00140000000408001F800000000000000000000'}, {'name': '难过斜眼', 'hex': '000000000000000000003000C0C00C0300400C00C00000C000000A001401FE0004080010800090000600000000000'}, {'name': '中性偷笑', 'hex': '00000000000000000000300300C00C0300300C00C000000000000A00140201000408001F800000000000000000000'}, {'name': '开心眯眼', 'hex': '00000000000000000000000000C00C03C0F006018000000000000540A800840003F00010800204000000000000000'}, {'name': '宽眉小嘴', 'hex': '0000000000000000000000000000000FC0FC000028000040000000000000780002100020400204003FC0000000000'}, {'name': '三角眼委屈', 'hex': '00000000000000000000100200A014044088000000000000000005002829FE5004080010800090000600000000000'}, {'name': '竖眼皱眉', 'hex': '000000000000000000001806006018018060060180000000000005002801FE0004080010800090000600000000000'}, {'name': 'X眼皱眉', 'hex': '00000000000000000000C000C0C00C0080400C00C0C000C0000005002829FE5004080010800090000600000000000'}, {'name': '强强', 'hex': '0000000001C423A242451212208844042108108420000001084200000000FC0004080040200402004020040801F80'}]
# Variable: DEFAULT_HEXES stores the result returned by set().
DEFAULT_HEXES = set([it.get("hex", "") for it in DEFAULT_FACES])
# Variable: _cache stores the empty sentinel value.
_cache = None
# Variable: _name_cache stores the empty sentinel value.
_name_cache = None

# Function: Defines _clean_hex(face_hex) to handle clean hex behavior.
def _clean_hex(face_hex):
    # Variable: s stores the result returned by str.strip().
    s = str(face_hex or "").strip()
    # Logic: Branches when s.upper().startswith("M370:") so the correct firmware path runs.
    if s.upper().startswith("M370:"):
        # Variable: s stores the selected item s[5:].
        s = s[5:]
    # Variable: out stores the configured text value.
    out = ""
    # Loop: Iterates ch over s so each item can be processed.
    for ch in s:
        # Logic: Branches when ch in "0123456789abcdefABCDEF" so the correct firmware path runs.
        if ch in "0123456789abcdefABCDEF":
            # Variable: Updates out in place using the result returned by ch.upper().
            out += ch.upper()
    # Logic: Branches when len(out) < 93 so the correct firmware path runs.
    if len(out) < 93:
        # Variable: Updates out in place using the calculated expression "0" * (93 - len(out)).
        out += "0" * (93 - len(out))
    # Return: Sends the selected item out[:93] back to the caller.
    return out[:93]

# Function: Defines _clean_name(name, fallback) to handle clean name behavior.
def _clean_name(name, fallback="未命名"):
    # Variable: s stores the result returned by str.replace.replace.replace.replace().
    s = str(name or fallback).replace("|", " ").replace("\r", " ").replace("\n", " ").replace("\t", " ")
    # Variable: s stores the result returned by join().
    s = " ".join(s.split())
    # Remove redundant old prefixes such as "默认 01" from migrated builds.
    # Logic: Branches when s.startswith("默认") so the correct firmware path runs.
    if s.startswith("默认"):
        # Variable: rest stores the result returned by strip().
        rest = s[2:].strip()
        # Loop: Repeats while rest and (rest[0].isdigit() or rest[0] in "*：:-_. ") remains true.
        while rest and (rest[0].isdigit() or rest[0] in "*：:-_. "):
            # Variable: rest stores the result returned by strip().
            rest = rest[1:].strip()
        # Logic: Branches when rest so the correct firmware path runs.
        if rest:
            # Variable: s stores the current rest value.
            s = rest
    # Return: Sends the selected item (s or fallback)[:48] back to the caller.
    return (s or fallback)[:48]

# Function: Defines _as_bool(v, default) to handle as bool behavior.
def _as_bool(v, default=False):
    # Logic: Branches when isinstance(v, bool) so the correct firmware path runs.
    if isinstance(v, bool):
        # Return: Sends the current v value back to the caller.
        return v
    # Logic: Branches when v is None so the correct firmware path runs.
    if v is None:
        # Return: Sends the current default value back to the caller.
        return default
    # Return: Sends the comparison result str(v).strip().lower() in ("1", "true", "yes", "on", "locked") back to the caller.
    return str(v).strip().lower() in ("1", "true", "yes", "on", "locked")

# Function: Defines _type_of(item, is_default) to handle type of behavior.
def _type_of(item, is_default):
    # Logic: Branches when is_default so the correct firmware path runs.
    if is_default:
        # Return: Sends the configured text value back to the caller.
        return "default"
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: raw stores the result returned by str.lower().
        raw = str(item.get("type", item.get("kind", item.get("source", "custom")))).lower()
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: raw stores the configured text value.
        raw = "custom"
    # Logic: Branches when raw in ("part", "parts", "component", "表情部件") so the correct firmware path runs.
    if raw in ("part", "parts", "component", "表情部件"):
        # Return: Sends the configured text value back to the caller.
        return "part"
    # Return: Sends the configured text value back to the caller.
    return "custom"

# Function: Defines _load_name_overrides() to handle load name overrides behavior.
def _load_name_overrides():
    # Variable: Marks _name_cache as module-level state modified here.
    global _name_cache
    # Logic: Branches when _name_cache is not None so the correct firmware path runs.
    if _name_cache is not None:
        # Return: Sends the current _name_cache value back to the caller.
        return _name_cache
    # Variable: data stores the lookup table used by this module.
    data = {}
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Resource: Opens managed resources for this block and releases them automatically.
        with open(RENAME_PATH, "r") as f:
            # Variable: raw stores the result returned by json.loads().
            raw = json.loads(f.read())
        # Logic: Branches when isinstance(raw, dict) so the correct firmware path runs.
        if isinstance(raw, dict):
            # Loop: Iterates k, v over raw.items() so each item can be processed.
            for k, v in raw.items():
                # Variable: hx stores the result returned by _clean_hex().
                hx = _clean_hex(k)
                # Variable: nm stores the result returned by _clean_name().
                nm = _clean_name(v, "")
                # Logic: Branches when hx and nm so the correct firmware path runs.
                if hx and nm:
                    # Variable: data[...] stores the current nm value.
                    data[hx] = nm
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: data stores the lookup table used by this module.
        data = {}
    # Variable: _name_cache stores the current data value.
    _name_cache = data
    # Return: Sends the current data value back to the caller.
    return data

# Function: Defines _default_by_hex() to handle default by hex behavior.
def _default_by_hex():
    # Return: Sends the result returned by dict() back to the caller.
    return dict([(_clean_hex(it.get("hex", "")), it) for it in DEFAULT_FACES])

# Function: Defines _default_item(item) to handle default item behavior.
def _default_item(item):
    # Variable: hx stores the result returned by _clean_hex().
    hx = _clean_hex(item.get("hex", ""))
    # Variable: name stores the result returned by _load_name_overrides.get().
    name = _load_name_overrides().get(hx, _clean_name(item.get("name", "默认表情"), "默认表情"))
    # Return: Sends the lookup table used by this module back to the caller.
    return {"name": name, "hex": hx, "ts": 0, "default": True, "type": "default", "locked": True}

# Function: Defines _normalize_item(item, fallback_name) to handle normalize item behavior.
def _normalize_item(item, fallback_name):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: hx stores the result returned by _clean_hex().
        hx = _clean_hex(item.get("hex", ""))
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: hx stores the result returned by _clean_hex().
        hx = _clean_hex("")
    # Variable: defaults stores the result returned by _default_by_hex().
    defaults = _default_by_hex()
    # Variable: is_default stores the comparison result hx in defaults.
    is_default = hx in defaults
    # Logic: Branches when is_default so the correct firmware path runs.
    if is_default:
        # Variable: base_name stores the result returned by get().
        base_name = defaults[hx].get("name", fallback_name)
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: base_name stores the current fallback_name value.
        base_name = fallback_name
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: name stores the result returned by _clean_name().
        name = _clean_name(item.get("name", base_name), base_name)
        # Variable: ts stores the result returned by int().
        ts = int(item.get("ts", 0) or 0)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: name, ts stores the collection of values used later in this module.
        name, ts = _clean_name(base_name), 0
    # Logic: Branches when is_default so the correct firmware path runs.
    if is_default:
        # Variable: name stores the result returned by _load_name_overrides.get().
        name = _load_name_overrides().get(hx, _clean_name(name, base_name))
    # Variable: typ stores the result returned by _type_of().
    typ = _type_of(item if isinstance(item, dict) else {}, is_default)
    # Variable: locked stores the conditional expression _as_bool(item.get("locked", True if is_default else False), True if is_default else F....
    locked = _as_bool(item.get("locked", True if is_default else False), True if is_default else False) if isinstance(item, dict) else (True if is_default else False)
    # Return: Sends the lookup table used by this module back to the caller.
    return {"name": name, "hex": hx, "ts": ts, "default": is_default, "type": typ, "locked": locked}

# Function: Defines _renumber(items) to handle renumber behavior.
def _renumber(items):
    # Display number is the visible row number from top to bottom.
    # Defaults use the same row number with a leading '*'.  typeNumber remains
    # available for code that wants default/custom counters separated.
    # Variable: d stores the configured literal value.
    d = 1
    # Variable: c stores the configured literal value.
    c = 1
    # Loop: Iterates idx, it over enumerate(items) so each item can be processed.
    for idx, it in enumerate(items):
        # Variable: row_no stores the calculated expression idx + 1.
        row_no = idx + 1
        # Variable: it[...] stores the current row_no value.
        it["order"] = row_no
        # Variable: it[...] stores the calculated expression "%02d" % row_no.
        it["rowNumber"] = "%02d" % row_no
        # Logic: Branches when it.get("type") == "default" so the correct firmware path runs.
        if it.get("type") == "default":
            # Variable: it[...] stores the calculated expression "*%02d" % d.
            it["typeNumber"] = "*%02d" % d
            # Variable: it[...] stores the calculated expression "*%02d" % row_no.
            it["number"] = "*%02d" % row_no
            # Variable: Updates d in place using the configured literal value.
            d += 1
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Variable: it[...] stores the calculated expression "%02d" % c.
            it["typeNumber"] = "%02d" % c
            # Variable: it[...] stores the calculated expression "%02d" % row_no.
            it["number"] = "%02d" % row_no
            # Variable: Updates c in place using the configured literal value.
            c += 1
    # Return: Sends the current items value back to the caller.
    return items

# Function: Defines _merge_defaults(items) to handle merge defaults behavior.
def _merge_defaults(items):
    # Variable: defaults stores the expression [_default_item(it) for it in DEFAULT_FACES].
    defaults = [_default_item(it) for it in DEFAULT_FACES]
    # Variable: default_hexes stores the result returned by set().
    default_hexes = set([it.get("hex", "") for it in defaults])
    # Variable: normalized stores the collection of values used later in this module.
    normalized = []
    # Variable: seen stores the result returned by set().
    seen = set()
    # Loop: Iterates idx, it over enumerate(items or []) so each item can be processed.
    for idx, it in enumerate(items or []):
        # Logic: Branches when not isinstance(it, dict) so the correct firmware path runs.
        if not isinstance(it, dict):
            # Control: Skips to the next loop iteration after this case is handled.
            continue
        # Variable: n stores the result returned by _normalize_item().
        n = _normalize_item(it, "custom %02d" % (idx + 1))
        # Keep one row per default hex; allow duplicate custom bitmaps only when names/types differ.
        # Variable: key stores the conditional expression n["hex"] if n["type"] == "default" else (n["hex"], n["name"], n["type"]).
        key = n["hex"] if n["type"] == "default" else (n["hex"], n["name"], n["type"])
        # Logic: Branches when key in seen so the correct firmware path runs.
        if key in seen:
            # Control: Skips to the next loop iteration after this case is handled.
            continue
        # Expression: Calls normalized.append() for its side effects.
        normalized.append(n)
        # Expression: Calls seen.add() for its side effects.
        seen.add(key)
    # Variable: existing_defaults stores the result returned by set().
    existing_defaults = set([it["hex"] for it in normalized if it.get("type") == "default"])
    # Variable: missing_defaults stores the expression [it for it in defaults if it["hex"] not in existing_defaults].
    missing_defaults = [it for it in defaults if it["hex"] not in existing_defaults]
    # Logic: Branches when existing_defaults so the correct firmware path runs.
    if existing_defaults:
        # Variable: merged stores the calculated expression normalized + missing_defaults.
        merged = normalized + missing_defaults
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: merged stores the calculated expression missing_defaults + normalized.
        merged = missing_defaults + normalized
    # Return: Sends the result returned by _renumber() back to the caller.
    return _renumber(merged[:MAX_FACES])

# Function: Defines load(force) to handle load behavior.
def load(force=False):
    # Variable: Marks _cache as module-level state modified here.
    global _cache
    # Logic: Branches when _cache is not None and not force so the correct firmware path runs.
    if _cache is not None and not force:
        # Return: Sends the current _cache value back to the caller.
        return _cache
    # Variable: items stores the collection of values used later in this module.
    items = []
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Resource: Opens managed resources for this block and releases them automatically.
        with open(STORE_PATH, "r") as f:
            # Variable: raw stores the result returned by json.loads().
            raw = json.loads(f.read())
        # Logic: Branches when isinstance(raw, list) so the correct firmware path runs.
        if isinstance(raw, list):
            # Variable: items stores the current raw value.
            items = raw
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: items stores the collection of values used later in this module.
        items = []
    # Variable: _cache stores the result returned by _merge_defaults().
    _cache = _merge_defaults(items)
    # Return: Sends the current _cache value back to the caller.
    return _cache

# Function: Defines save(items) to handle save behavior.
def save(items):
    # Variable: Marks _cache as module-level state modified here.
    global _cache
    # Variable: _cache stores the result returned by _merge_defaults().
    _cache = _merge_defaults(items)
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Resource: Opens managed resources for this block and releases them automatically.
        with open(STORE_PATH, "w") as f:
            # Expression: Calls f.write() for its side effects.
            f.write(json.dumps(_cache))
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception as exc:
        # Expression: Calls print() for its side effects.
        print("saved_faces_370 save failed:", exc)
    # Return: Sends the current _cache value back to the caller.
    return _cache

# Function: Defines save_json(json_text) to handle save json behavior.
def save_json(json_text):
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: raw stores the result returned by json.loads().
        raw = json.loads(str(json_text or "[]"))
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Logic: Branches when not isinstance(raw, list) so the correct firmware path runs.
    if not isinstance(raw, list):
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Expression: Calls save() for its side effects.
    save(raw)
    # Return: Sends the enabled/disabled flag value back to the caller.
    return True

# Function: Defines all_faces() to handle all faces behavior.
def all_faces():
    # Return: Sends the result returned by load() back to the caller.
    return load()

# Function: Defines is_default_hex(face_hex) to handle is default hex behavior.
def is_default_hex(face_hex):
    # Return: Sends the comparison result _clean_hex(face_hex) in DEFAULT_HEXES back to the caller.
    return _clean_hex(face_hex) in DEFAULT_HEXES

# Function: Defines count() to handle count behavior.
def count():
    # Return: Sends the result returned by len() back to the caller.
    return len(load())

# Function: Defines get(index) to handle get behavior.
def get(index):
    # Variable: faces stores the result returned by load().
    faces = load()
    # Logic: Branches when not faces so the correct firmware path runs.
    if not faces:
        # Return: Sends the lookup table used by this module back to the caller.
        return {"name": "empty", "hex": _clean_hex("")}
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: idx stores the calculated expression int(index) % len(faces).
        idx = int(index) % len(faces)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: idx stores the configured literal value.
        idx = 0
    # Return: Sends the selected item faces[idx] back to the caller.
    return faces[idx]

# Function: Defines add_or_update(name, face_hex, kind, locked) to handle add or update behavior.
def add_or_update(name, face_hex, kind="custom", locked=False):
    # Variable: faces stores the selected item load()[:].
    faces = load()[:]
    # Variable: hx stores the result returned by _clean_hex().
    hx = _clean_hex(face_hex)
    # Variable: is_default stores the comparison result hx in DEFAULT_HEXES.
    is_default = hx in DEFAULT_HEXES
    # Variable: typ stores the conditional expression "default" if is_default else ("part" if str(kind).lower() in ("part", "parts", "compo....
    typ = "default" if is_default else ("part" if str(kind).lower() in ("part", "parts", "component", "表情部件") else "custom")
    # Variable: item stores the lookup table used by this module.
    item = {"name": _clean_name(name, "custom"), "hex": hx, "ts": 0 if is_default else 1, "default": is_default, "type": typ, "locked": _as_bool(locked, True if is_default else False)}
    # Update existing non-default with same name/hex, otherwise append. Defaults are not duplicated.
    # Loop: Iterates idx, it over enumerate(faces) so each item can be processed.
    for idx, it in enumerate(faces):
        # Logic: Branches when it.get("hex") == hx and (is_default or it.get("name") == item["name"]) so the correct firmware path runs.
        if it.get("hex") == hx and (is_default or it.get("name") == item["name"]):
            # Expression: Calls update() for its side effects.
            faces[idx].update(item)
            # Expression: Calls save() for its side effects.
            save(faces)
            # Return: Sends the selected item faces[idx] back to the caller.
            return faces[idx]
    # Expression: Calls faces.append() for its side effects.
    faces.append(item)
    # Expression: Calls save() for its side effects.
    save(faces)
    # Return: Sends the current item value back to the caller.
    return item

# Function: Defines rename_by_name(old_name, new_name) to handle rename by name behavior.
def rename_by_name(old_name, new_name):
    # Variable: faces stores the selected item load()[:].
    faces = load()[:]
    # Variable: old_name stores the result returned by str().
    old_name = str(old_name or "")
    # Variable: new_name stores the result returned by _clean_name().
    new_name = _clean_name(new_name, "custom")
    # Logic: Branches when not old_name or not new_name so the correct firmware path runs.
    if not old_name or not new_name:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Loop: Iterates it over faces so each item can be processed.
    for it in faces:
        # Logic: Branches when it.get("name") == old_name so the correct firmware path runs.
        if it.get("name") == old_name:
            # Variable: it[...] stores the current new_name value.
            it["name"] = new_name
            # Expression: Calls save() for its side effects.
            save(faces)
            # Return: Sends the enabled/disabled flag value back to the caller.
            return True
    # Return: Sends the enabled/disabled flag value back to the caller.
    return False

# Function: Defines delete_by_name(name) to handle delete by name behavior.
def delete_by_name(name):
    # Variable: faces stores the selected item load()[:].
    faces = load()[:]
    # Variable: name stores the result returned by str().
    name = str(name or "")
    # Variable: kept stores the collection of values used later in this module.
    kept = []
    # Variable: changed stores the enabled/disabled flag value.
    changed = False
    # Loop: Iterates it over faces so each item can be processed.
    for it in faces:
        # Logic: Branches when it.get("name") == name so the correct firmware path runs.
        if it.get("name") == name:
            # Logic: Branches when it.get("type") == "default" or is_default_hex(it.get("hex", "")) or _as_bool(it.get("... so the correct firmware path runs.
            if it.get("type") == "default" or is_default_hex(it.get("hex", "")) or _as_bool(it.get("locked"), False):
                # Expression: Calls kept.append() for its side effects.
                kept.append(it)
            # Logic: Runs this fallback branch when the earlier condition did not match.
            else:
                # Variable: changed stores the enabled/disabled flag value.
                changed = True
        # Logic: Runs this fallback branch when the earlier condition did not match.
        else:
            # Expression: Calls kept.append() for its side effects.
            kept.append(it)
    # Logic: Branches when changed so the correct firmware path runs.
    if changed:
        # Expression: Calls save() for its side effects.
        save(kept)
    # Return: Sends the current changed value back to the caller.
    return changed

# Function: Defines json_list() to handle json list behavior.
def json_list():
    # Return: Sends the result returned by json.dumps() back to the caller.
    return json.dumps(load())


# Function: Defines _coerce_index(index, allow_end) to handle coerce index behavior.
def _coerce_index(index, allow_end=False):
    # Variable: faces stores the result returned by load().
    faces = load()
    # Logic: Branches when not faces so the correct firmware path runs.
    if not faces:
        # Return: Sends the configured literal value back to the caller.
        return 0
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: idx stores the result returned by int().
        idx = int(index)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: idx stores the configured literal value.
        idx = 0
    # Variable: hi stores the conditional expression len(faces) if allow_end else len(faces) - 1.
    hi = len(faces) if allow_end else len(faces) - 1
    # Logic: Branches when idx < 0 so the correct firmware path runs.
    if idx < 0:
        # Variable: idx stores the configured literal value.
        idx = 0
    # Logic: Branches when idx > hi so the correct firmware path runs.
    if idx > hi:
        # Variable: idx stores the current hi value.
        idx = hi
    # Return: Sends the current idx value back to the caller.
    return idx

# Function: Defines get_by_number(number) to handle get by number behavior.
def get_by_number(number):
    # Variable: faces stores the result returned by load().
    faces = load()
    # Variable: n stores the result returned by str.strip.lstrip().
    n = str(number or "").strip().lstrip("*")
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: row stores the calculated expression int(n) - 1.
        row = int(n) - 1
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: row stores the configured literal value.
        row = 0
    # Return: Sends the result returned by get() back to the caller.
    return get(row)

# Function: Defines update_by_index(index, name, typ, locked) to handle update by index behavior.
def update_by_index(index, name=None, typ=None, locked=None):
    # Variable: faces stores the selected item load()[:].
    faces = load()[:]
    # Logic: Branches when not faces so the correct firmware path runs.
    if not faces:
        # Return: Sends the empty sentinel value back to the caller.
        return None
    # Variable: idx stores the result returned by _coerce_index().
    idx = _coerce_index(index)
    # Variable: it stores the result returned by dict().
    it = dict(faces[idx])
    # Logic: Branches when name is not None and str(name).strip() so the correct firmware path runs.
    if name is not None and str(name).strip():
        # Variable: it[...] stores the result returned by _clean_name().
        it["name"] = _clean_name(name, it.get("name", "custom"))
    # Logic: Branches when not (it.get("type") == "default" or is_default_hex(it.get("hex", ""))) so the correct firmware path runs.
    if not (it.get("type") == "default" or is_default_hex(it.get("hex", ""))):
        # Logic: Branches when typ is not None so the correct firmware path runs.
        if typ is not None:
            # Variable: it[...] stores the result returned by _type_of().
            it["type"] = _type_of({"type": typ}, False)
        # Logic: Branches when locked is not None so the correct firmware path runs.
        if locked is not None:
            # Variable: it[...] stores the result returned by _as_bool().
            it["locked"] = _as_bool(locked, False)
    # Logic: Runs this fallback branch when the earlier condition did not match.
    else:
        # Variable: it[...] stores the configured text value.
        it["type"] = "default"
        # Defaults can be marked unlocked in the UI for clarity, but they are
        # still protected from deletion by delete_by_index/delete_by_name.
        # Logic: Branches when locked is not None so the correct firmware path runs.
        if locked is not None:
            # Variable: it[...] stores the result returned by _as_bool().
            it["locked"] = _as_bool(locked, True)
    # Variable: faces[...] stores the current it value.
    faces[idx] = it
    # Return: Sends the selected item save(faces)[idx] back to the caller.
    return save(faces)[idx]

# Function: Defines set_lock_by_index(index, locked) to handle set lock by index behavior.
def set_lock_by_index(index, locked):
    # Return: Sends the result returned by update_by_index() back to the caller.
    return update_by_index(index, locked=locked)

# Function: Defines set_type_by_index(index, typ) to handle set type by index behavior.
def set_type_by_index(index, typ):
    # Return: Sends the result returned by update_by_index() back to the caller.
    return update_by_index(index, typ=typ)

# Function: Defines rename_by_index(index, new_name) to handle rename by index behavior.
def rename_by_index(index, new_name):
    # Return: Sends the result returned by update_by_index() back to the caller.
    return update_by_index(index, name=new_name)

# Function: Defines delete_by_index(index) to handle delete by index behavior.
def delete_by_index(index):
    # Variable: faces stores the selected item load()[:].
    faces = load()[:]
    # Logic: Branches when not faces so the correct firmware path runs.
    if not faces:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Variable: idx stores the result returned by _coerce_index().
    idx = _coerce_index(index)
    # Variable: it stores the selected item faces[idx].
    it = faces[idx]
    # Logic: Branches when it.get("type") == "default" or is_default_hex(it.get("hex", "")) or _as_bool(it.get("... so the correct firmware path runs.
    if it.get("type") == "default" or is_default_hex(it.get("hex", "")) or _as_bool(it.get("locked"), False):
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Cleanup: Deletes faces[...] after it is no longer needed.
    del faces[idx]
    # Expression: Calls save() for its side effects.
    save(faces)
    # Return: Sends the enabled/disabled flag value back to the caller.
    return True

# Function: Defines move_index(from_index, to_index) to handle move index behavior.
def move_index(from_index, to_index):
    # Variable: faces stores the selected item load()[:].
    faces = load()[:]
    # Logic: Branches when not faces so the correct firmware path runs.
    if not faces:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return False
    # Variable: src stores the result returned by _coerce_index().
    src = _coerce_index(from_index)
    # Error handling: Attempts the protected operation so failures can be handled safely.
    try:
        # Variable: dst stores the result returned by int().
        dst = int(to_index)
    # Error handling: Runs this recovery branch when the protected operation fails.
    except Exception:
        # Variable: dst stores the current src value.
        dst = src
    # Logic: Branches when dst < 0 so the correct firmware path runs.
    if dst < 0:
        # Variable: dst stores the configured literal value.
        dst = 0
    # Logic: Branches when dst >= len(faces) so the correct firmware path runs.
    if dst >= len(faces):
        # Variable: dst stores the calculated expression len(faces) - 1.
        dst = len(faces) - 1
    # Logic: Branches when src == dst so the correct firmware path runs.
    if src == dst:
        # Return: Sends the enabled/disabled flag value back to the caller.
        return True
    # Variable: item stores the result returned by faces.pop().
    item = faces.pop(src)
    # Expression: Calls faces.insert() for its side effects.
    faces.insert(dst, item)
    # Expression: Calls save() for its side effects.
    save(faces)
    # Return: Sends the enabled/disabled flag value back to the caller.
    return True

# Function: Defines replace_all(items) to handle replace all behavior.
def replace_all(items):
    # Return: Sends the result returned by save() back to the caller.
    return save(items)
