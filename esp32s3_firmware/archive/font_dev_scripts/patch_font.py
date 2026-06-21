import json


def patch_file(filepath):
    print(f"Patching {filepath}")
    with open(filepath, 'r', encoding='utf-8') as f:
        data = json.load(f)

    changed = False
    if "glyphs" in data:
        for i in range(10):
            # '0' is 0x30 ... '9' is 0x39
            hex_key = f"003{i}"
            if hex_key in data["glyphs"]:
                # The format is [advance, width, height, xOffset, yOffset, dstY, "HEX/ROWS"]
                entry = data["glyphs"][hex_key]
                old_dstY = entry[5]
                entry[5] -= 1
                print(f"Changed {hex_key} dstY from {old_dstY} to {entry[5]}")
                changed = True

            hex_key_short = f"3{i}"
            if hex_key_short in data["glyphs"]:
                entry = data["glyphs"][hex_key_short]
                old_dstY = entry[5]
                entry[5] -= 1
                print(f"Changed {hex_key_short} dstY from {old_dstY} to {entry[5]}")
                changed = True

    if changed:
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
        print(f"Saved {filepath}")


patch_file("./tools/font_fusion/ark12_fusion.json")
patch_file("./data/resources/fonts/ark12.json")
