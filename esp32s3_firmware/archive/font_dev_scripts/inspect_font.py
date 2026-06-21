from fontTools.ttLib import TTFont

font = TTFont("./data/resources/fonts/ark12.woff2")
upem = font['head'].unitsPerEm
print(f"unitsPerEm: {upem}")

cmap = font.getBestCmap()
for cp in range(0x30, 0x3A):
    glyph_name = cmap.get(cp)
    print(f"Char {chr(cp)} (U+{cp:04X}) -> glyph name: {glyph_name}")

    if glyph_name and glyph_name in font['glyf']:
        glyph = font['glyf'][glyph_name]
        print(f"  Coordinates: {getattr(glyph, 'coordinates', 'No coordinates (composite?)')}")
