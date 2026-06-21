import xml.etree.ElementTree as ET

tree = ET.parse("ark12.ttx")
root = tree.getroot()

char_strings = root.findall(".//CharString")
targets = [f"u003{i}" for i in range(10)] + [f"uFF1{i}" for i in range(10)]

for cs in char_strings:
    name = cs.get("name")
    if name in targets:
        text = cs.text.strip()
        tokens = text.split()
        op_idx = -1
        for i, t in enumerate(tokens):
            if not (t[-1].isdigit() or t.startswith("-") or t == "0"):
                op_idx = i
                break

        if op_idx != -1:
            op = tokens[op_idx]
            args = tokens[:op_idx]

            if op == "rmoveto":
                if len(args) == 3:
                    args[2] = str(int(args[2]) + 100)
                elif len(args) == 2:
                    args[1] = str(int(args[1]) + 100)
            elif op == "hmoveto":
                if len(args) == 2:
                    args.append("100")
                    op = "rmoveto"
                elif len(args) == 1:
                    args.append("100")
                    op = "rmoveto"
            elif op == "vmoveto":
                if len(args) == 2:
                    args[1] = str(int(args[1]) + 100)
                elif len(args) == 1:
                    args[0] = str(int(args[0]) + 100)

            tokens[:op_idx+1] = args + [op]
            cs.text = "\n" + " ".join(tokens) + "\n"

with open('ark12_patched_all.ttx', 'w', encoding='utf-8') as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    tree.write(f, encoding='unicode')

print("Patched TTX written to ark12_patched_all.ttx")
