import ujson as json
try:
    import os
except ImportError:
    os = None
from config import FACES_FILE, ROWS, COLS
from default_faces import DEFAULT_SAVED_FACES, DEFAULT_START_INDEX
from face_codec import normalize_bitmap
_DEFAULT_IDS = set([f.get('default_id') for f in DEFAULT_SAVED_FACES])
def _exists(path):
    try:
        open(path, 'r').close()
        return True
    except Exception:
        return False
def _clone(obj):
    return json.loads(json.dumps(obj))
def _sanitize_data(data):
    return normalize_bitmap(data)
def _sanitize_item(item, fallback_name='Face'):
    if not isinstance(item, dict):
        item = {}
    out = {}
    out['name'] = str(item.get('name') or fallback_name)[:48]
    typ = item.get('type') or 'custom'
    out['type'] = typ if typ in ('default', 'custom', 'part') else 'custom'
    out['locked'] = bool(item.get('locked', False))
    if 'default_id' in item:
        out['default_id'] = str(item.get('default_id'))
    if item.get('builtin'):
        out['builtin'] = True
    out['data'] = _sanitize_data(item.get('data') or [])
    return out
def _forced_default(item):
    did = item.get('default_id')
    base = None
    for d in DEFAULT_SAVED_FACES:
        if d.get('default_id') == did:
            base = d
            break
    if base is None:
        return _sanitize_item(item)
    out = _clone(base)
    if item.get('name'):
        out['name'] = str(item.get('name'))[:48]
    out['type'] = 'default'
    out['locked'] = True
    out['builtin'] = True
    out['data'] = _sanitize_data(base.get('data'))
    return out
class SavedFaceStore:
    def __init__(self, path=FACES_FILE):
        self.path = path
        self.faces = []
        self.load()
    def load(self):
        faces = None
        if _exists(self.path):
            try:
                with open(self.path, 'r') as f:
                    faces = json.load(f)
            except Exception as e:
                print('faces load failed:', e)
                faces = None
        if not isinstance(faces, list):
            faces = _clone(DEFAULT_SAVED_FACES)
        self.faces = self._merge_defaults(faces)
        self.save()
        return self.faces
    def _merge_defaults(self, incoming):
        output = []
        seen_defaults = set()
        for idx, item in enumerate(incoming):
            if isinstance(item, dict) and item.get('default_id') in _DEFAULT_IDS:
                fixed = _forced_default(item)
                seen_defaults.add(fixed.get('default_id'))
                output.append(fixed)
            else:
                output.append(_sanitize_item(item, 'Face %02d' % (idx + 1)))
        for d in DEFAULT_SAVED_FACES:
            if d.get('default_id') not in seen_defaults:
                output.append(_forced_default(d))
        return output
    def save(self):
        with open(self.path, 'w') as f:
            json.dump(self.faces, f)
    def to_json(self):
        return json.dumps(self.faces)
    def count(self):
        return len(self.faces)
    def get(self, index):
        if not self.faces:
            return None
        return self.faces[int(index) % len(self.faces)]
    def set_all(self, items):
        if isinstance(items, str):
            items = json.loads(items)
        if not isinstance(items, list):
            raise ValueError('saved faces JSON must be a list')
        self.faces = self._merge_defaults(items)
        self.save()
        return True
    def add(self, item):
        item = _sanitize_item(item, 'Custom %02d' % (len(self.faces) + 1))
        if item.get('default_id') in _DEFAULT_IDS or item.get('type') == 'default':
            raise ValueError('cannot add user default face')
        item.pop('default_id', None)
        item.pop('builtin', None)
        self.faces.append(item)
        self.save()
        return len(self.faces) - 1
    def delete(self, index):
        index = int(index)
        if index < 0 or index >= len(self.faces):
            return False, 'index out of range'
        item = self.faces[index]
        if item.get('type') == 'default' or item.get('builtin') or item.get('default_id') in _DEFAULT_IDS:
            return False, 'default face is locked and cannot be deleted'
        if item.get('locked'):
            return False, 'locked face cannot be deleted'
        del self.faces[index]
        self.save()
        return True, 'ok'
    def move(self, src, dst):
        src = int(src); dst = int(dst)
        n = len(self.faces)
        if src < 0 or src >= n:
            return False
        if dst < 0:
            dst = 0
        if dst >= n:
            dst = n - 1
        item = self.faces.pop(src)
        self.faces.insert(dst, item)
        self.save()
        return True
    def rename(self, index, name):
        index = int(index)
        self.faces[index]['name'] = str(name)[:48]
        self.save()
        return True
    def lock(self, index, locked):
        index = int(index)
        item = self.faces[index]
        if item.get('type') == 'default' or item.get('builtin'):
            item['locked'] = True
        else:
            item['locked'] = bool(int(locked)) if isinstance(locked, str) else bool(locked)
        self.save()
        return True
    def set_type(self, index, typ):
        index = int(index)
        if typ not in ('custom', 'part'):
            raise ValueError('type must be custom or part')
        item = self.faces[index]
        if item.get('type') == 'default' or item.get('builtin'):
            raise ValueError('cannot change default face type')
        item['type'] = typ
        self.save()
        return True
    def update_meta(self, index, name=None, typ=None, locked=None):
        index = int(index)
        if name is not None:
            self.rename(index, name)
        if typ is not None and typ != 'default':
            self.set_type(index, typ)
        if locked is not None:
            self.lock(index, locked)
        self.save()
        return True
