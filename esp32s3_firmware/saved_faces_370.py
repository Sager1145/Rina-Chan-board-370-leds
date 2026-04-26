# ---------------------------------------------------------------------------
# saved_faces_370.py
# Shared face store for the 370-LED physical matrix.
# v1.5.6: firmware-side source of truth for WebUI face manager,
# order-preserving row numbering, lock state, and face type (default/custom/part).
# ---------------------------------------------------------------------------
import json

STORE_PATH = "saved_faces_370.json"
RENAME_PATH = "saved_faces_370_names.json"  # kept for migration compatibility
MAX_FACES = 99
DEFAULT_FACES = [{'name': '惊讶眨眼大嘴', 'hex': '0000000000700408804044020020080100200000001002000000006180027900080400402004F20030C0000000000'}, {'name': '眼镜方嘴', 'hex': '00000000000000000000300301A0160780780C00E000014000020000000000000FFC00402003FC000000000000000'}, {'name': '困惑挑眉', 'hex': '0000000000000000000000000000000800041E01E000000000000A00140000000408001F800000000000000000000'}, {'name': '难过斜眼', 'hex': '000000000000000000003000C0C00C0300400C00C00000C000000A001401FE0004080010800090000600000000000'}, {'name': '中性偷笑', 'hex': '00000000000000000000300300C00C0300300C00C000000000000A00140201000408001F800000000000000000000'}, {'name': '开心眯眼', 'hex': '00000000000000000000000000C00C03C0F006018000000000000540A800840003F00010800204000000000000000'}, {'name': '宽眉小嘴', 'hex': '0000000000000000000000000000000FC0FC000028000040000000000000780002100020400204003FC0000000000'}, {'name': '三角眼委屈', 'hex': '00000000000000000000100200A014044088000000000000000005002829FE5004080010800090000600000000000'}, {'name': '竖眼皱眉', 'hex': '000000000000000000001806006018018060060180000000000005002801FE0004080010800090000600000000000'}, {'name': 'X眼皱眉', 'hex': '00000000000000000000C000C0C00C0080400C00C0C000C0000005002829FE5004080010800090000600000000000'}, {'name': '强强', 'hex': '0000000001C423A242451212208844042108108420000001084200000000FC0004080040200402004020040801F80'}]
DEFAULT_HEXES = set([it.get("hex", "") for it in DEFAULT_FACES])
_cache = None
_name_cache = None

def _clean_hex(face_hex):
    s = str(face_hex or "").strip()
    if s.upper().startswith("M370:"):
        s = s[5:]
    out = ""
    for ch in s:
        if ch in "0123456789abcdefABCDEF":
            out += ch.upper()
    if len(out) < 93:
        out += "0" * (93 - len(out))
    return out[:93]

def _clean_name(name, fallback="未命名"):
    s = str(name or fallback).replace("|", " ").replace("\r", " ").replace("\n", " ").replace("\t", " ")
    s = " ".join(s.split())
    # Remove redundant old prefixes such as "默认 01" from migrated builds.
    if s.startswith("默认"):
        rest = s[2:].strip()
        while rest and (rest[0].isdigit() or rest[0] in "*：:-_. "):
            rest = rest[1:].strip()
        if rest:
            s = rest
    return (s or fallback)[:48]

def _as_bool(v, default=False):
    if isinstance(v, bool):
        return v
    if v is None:
        return default
    return str(v).strip().lower() in ("1", "true", "yes", "on", "locked")

def _type_of(item, is_default):
    if is_default:
        return "default"
    try:
        raw = str(item.get("type", item.get("kind", item.get("source", "custom")))).lower()
    except Exception:
        raw = "custom"
    if raw in ("part", "parts", "component", "表情部件"):
        return "part"
    return "custom"

def _load_name_overrides():
    global _name_cache
    if _name_cache is not None:
        return _name_cache
    data = {}
    try:
        with open(RENAME_PATH, "r") as f:
            raw = json.loads(f.read())
        if isinstance(raw, dict):
            for k, v in raw.items():
                hx = _clean_hex(k)
                nm = _clean_name(v, "")
                if hx and nm:
                    data[hx] = nm
    except Exception:
        data = {}
    _name_cache = data
    return data

def _default_by_hex():
    return dict([(_clean_hex(it.get("hex", "")), it) for it in DEFAULT_FACES])

def _default_item(item):
    hx = _clean_hex(item.get("hex", ""))
    name = _load_name_overrides().get(hx, _clean_name(item.get("name", "默认表情"), "默认表情"))
    return {"name": name, "hex": hx, "ts": 0, "default": True, "type": "default", "locked": True}

def _normalize_item(item, fallback_name):
    try:
        hx = _clean_hex(item.get("hex", ""))
    except Exception:
        hx = _clean_hex("")
    defaults = _default_by_hex()
    is_default = hx in defaults
    if is_default:
        base_name = defaults[hx].get("name", fallback_name)
    else:
        base_name = fallback_name
    try:
        name = _clean_name(item.get("name", base_name), base_name)
        ts = int(item.get("ts", 0) or 0)
    except Exception:
        name, ts = _clean_name(base_name), 0
    if is_default:
        name = _load_name_overrides().get(hx, _clean_name(name, base_name))
    typ = _type_of(item if isinstance(item, dict) else {}, is_default)
    locked = _as_bool(item.get("locked", True if is_default else False), True if is_default else False) if isinstance(item, dict) else (True if is_default else False)
    return {"name": name, "hex": hx, "ts": ts, "default": is_default, "type": typ, "locked": locked}

def _renumber(items):
    # Display number is the visible row number from top to bottom.
    # Defaults use the same row number with a leading '*'.  typeNumber remains
    # available for code that wants default/custom counters separated.
    d = 1
    c = 1
    for idx, it in enumerate(items):
        row_no = idx + 1
        it["order"] = row_no
        it["rowNumber"] = "%02d" % row_no
        if it.get("type") == "default":
            it["typeNumber"] = "*%02d" % d
            it["number"] = "*%02d" % row_no
            d += 1
        else:
            it["typeNumber"] = "%02d" % c
            it["number"] = "%02d" % row_no
            c += 1
    return items

def _merge_defaults(items):
    defaults = [_default_item(it) for it in DEFAULT_FACES]
    default_hexes = set([it.get("hex", "") for it in defaults])
    normalized = []
    seen = set()
    for idx, it in enumerate(items or []):
        if not isinstance(it, dict):
            continue
        n = _normalize_item(it, "custom %02d" % (idx + 1))
        # Keep one row per default hex; allow duplicate custom bitmaps only when names/types differ.
        key = n["hex"] if n["type"] == "default" else (n["hex"], n["name"], n["type"])
        if key in seen:
            continue
        normalized.append(n)
        seen.add(key)
    existing_defaults = set([it["hex"] for it in normalized if it.get("type") == "default"])
    missing_defaults = [it for it in defaults if it["hex"] not in existing_defaults]
    if existing_defaults:
        merged = normalized + missing_defaults
    else:
        merged = missing_defaults + normalized
    return _renumber(merged[:MAX_FACES])

def load(force=False):
    global _cache
    if _cache is not None and not force:
        return _cache
    items = []
    try:
        with open(STORE_PATH, "r") as f:
            raw = json.loads(f.read())
        if isinstance(raw, list):
            items = raw
    except Exception:
        items = []
    _cache = _merge_defaults(items)
    return _cache

def save(items):
    global _cache
    _cache = _merge_defaults(items)
    try:
        with open(STORE_PATH, "w") as f:
            f.write(json.dumps(_cache))
    except Exception as exc:
        print("saved_faces_370 save failed:", exc)
    return _cache

def save_json(json_text):
    try:
        raw = json.loads(str(json_text or "[]"))
    except Exception:
        return False
    if not isinstance(raw, list):
        return False
    save(raw)
    return True

def all_faces():
    return load()

def is_default_hex(face_hex):
    return _clean_hex(face_hex) in DEFAULT_HEXES

def count():
    return len(load())

def get(index):
    faces = load()
    if not faces:
        return {"name": "empty", "hex": _clean_hex("")}
    try:
        idx = int(index) % len(faces)
    except Exception:
        idx = 0
    return faces[idx]

def add_or_update(name, face_hex, kind="custom", locked=False):
    faces = load()[:]
    hx = _clean_hex(face_hex)
    is_default = hx in DEFAULT_HEXES
    typ = "default" if is_default else ("part" if str(kind).lower() in ("part", "parts", "component", "表情部件") else "custom")
    item = {"name": _clean_name(name, "custom"), "hex": hx, "ts": 0 if is_default else 1, "default": is_default, "type": typ, "locked": _as_bool(locked, True if is_default else False)}
    # Update existing non-default with same name/hex, otherwise append. Defaults are not duplicated.
    for idx, it in enumerate(faces):
        if it.get("hex") == hx and (is_default or it.get("name") == item["name"]):
            faces[idx].update(item)
            save(faces)
            return faces[idx]
    faces.append(item)
    save(faces)
    return item

def rename_by_name(old_name, new_name):
    faces = load()[:]
    old_name = str(old_name or "")
    new_name = _clean_name(new_name, "custom")
    if not old_name or not new_name:
        return False
    for it in faces:
        if it.get("name") == old_name:
            it["name"] = new_name
            save(faces)
            return True
    return False

def delete_by_name(name):
    faces = load()[:]
    name = str(name or "")
    kept = []
    changed = False
    for it in faces:
        if it.get("name") == name:
            if it.get("type") == "default" or is_default_hex(it.get("hex", "")) or _as_bool(it.get("locked"), False):
                kept.append(it)
            else:
                changed = True
        else:
            kept.append(it)
    if changed:
        save(kept)
    return changed

def json_list():
    return json.dumps(load())


def _coerce_index(index, allow_end=False):
    faces = load()
    if not faces:
        return 0
    try:
        idx = int(index)
    except Exception:
        idx = 0
    hi = len(faces) if allow_end else len(faces) - 1
    if idx < 0:
        idx = 0
    if idx > hi:
        idx = hi
    return idx

def get_by_number(number):
    faces = load()
    n = str(number or "").strip().lstrip("*")
    try:
        row = int(n) - 1
    except Exception:
        row = 0
    return get(row)

def update_by_index(index, name=None, typ=None, locked=None):
    faces = load()[:]
    if not faces:
        return None
    idx = _coerce_index(index)
    it = dict(faces[idx])
    if name is not None and str(name).strip():
        it["name"] = _clean_name(name, it.get("name", "custom"))
    if not (it.get("type") == "default" or is_default_hex(it.get("hex", ""))):
        if typ is not None:
            it["type"] = _type_of({"type": typ}, False)
        if locked is not None:
            it["locked"] = _as_bool(locked, False)
    else:
        it["type"] = "default"
        # Defaults can be marked unlocked in the UI for clarity, but they are
        # still protected from deletion by delete_by_index/delete_by_name.
        if locked is not None:
            it["locked"] = _as_bool(locked, True)
    faces[idx] = it
    return save(faces)[idx]

def set_lock_by_index(index, locked):
    return update_by_index(index, locked=locked)

def set_type_by_index(index, typ):
    return update_by_index(index, typ=typ)

def rename_by_index(index, new_name):
    return update_by_index(index, name=new_name)

def delete_by_index(index):
    faces = load()[:]
    if not faces:
        return False
    idx = _coerce_index(index)
    it = faces[idx]
    if it.get("type") == "default" or is_default_hex(it.get("hex", "")) or _as_bool(it.get("locked"), False):
        return False
    del faces[idx]
    save(faces)
    return True

def move_index(from_index, to_index):
    faces = load()[:]
    if not faces:
        return False
    src = _coerce_index(from_index)
    try:
        dst = int(to_index)
    except Exception:
        dst = src
    if dst < 0:
        dst = 0
    if dst >= len(faces):
        dst = len(faces) - 1
    if src == dst:
        return True
    item = faces.pop(src)
    faces.insert(dst, item)
    save(faces)
    return True

def replace_all(items):
    return save(items)
