from fontTools.ttLib import TTFont
font = TTFont("./data/resources/fonts/ark12.woff2")
print("Tables:", font.keys())
