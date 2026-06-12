from fontTools.ttLib import TTFont
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.t2CharStringPen import T2CharStringPen

font = TTFont("./data/resources/fonts/ark12.woff2")
cff = font['CFF '].cff
topDict = cff.topDictIndex[0]
charStrings = topDict.CharStrings

cmap = font.getBestCmap()
glyph_name = cmap.get(0x30)
cs = charStrings[glyph_name]
cs.decompile()
print("Old program:", cs.program)

pen = T2CharStringPen(cs.width, charStrings)
tpen = TransformPen(pen, (1, 0, 0, 1, 0, 100))
cs.draw(tpen)
new_cs = pen.getCharString(private=cs.private, globalSubrs=cs.globalSubrs)
print("New program:", new_cs.program)
