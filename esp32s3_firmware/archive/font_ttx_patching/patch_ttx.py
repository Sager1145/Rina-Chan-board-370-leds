import xml.etree.ElementTree as ET

tree = ET.parse("ark12.ttx")
root = tree.getroot()

# The CharStrings are under <CFF><CFFFont><CharStrings>
char_strings = root.findall(".//CharString")
for cs in char_strings:
    name = cs.get("name")
    if name in [f"u003{i}" for i in range(10)]:
        text = cs.text.strip()
        print(f"Old {name}: {text}")
        
        # We want to shift the character UP by 100 units.
        # This can be done by inserting '0 100 rmoveto' at the beginning of the drawing commands.
        # However, the FIRST argument is the width if the number of arguments is odd for the first moveto.
        # Let's inspect the first few tokens.
        tokens = text.split()
        
        # If it starts with width, it will be: <width> <dx> <dy> rmoveto
        # or <width> <dx> hmoveto
        # or <width> <dy> vmoveto
        # Or just <dx> <dy> rmoveto if width is default.
        
        # Actually, fontTools decompiles them cleanly. Let's just manipulate the tokens.
        # In ttx output, standard T2 operations are used.
        # Let's see the first operator.
        op_idx = -1
        for i, t in enumerate(tokens):
            if not (t[-1].isdigit() or t.startswith("-") or t == "0"):
                # It's an operator
                op_idx = i
                break
                
        if op_idx != -1:
            op = tokens[op_idx]
            args = tokens[:op_idx]
            
            if op == "rmoveto":
                if len(args) == 3: # width, dx, dy
                    args[2] = str(int(args[2]) + 100)
                elif len(args) == 2: # dx, dy
                    args[1] = str(int(args[1]) + 100)
            elif op == "hmoveto":
                if len(args) == 2: # width, dx
                    # convert to rmoveto: width, dx, dy
                    args.append("100")
                    op = "rmoveto"
                elif len(args) == 1: # dx
                    args.append("100")
                    op = "rmoveto"
            elif op == "vmoveto":
                if len(args) == 2: # width, dy
                    args[1] = str(int(args[1]) + 100)
                elif len(args) == 1: # dy
                    args[0] = str(int(args[0]) + 100)
                    
            tokens[:op_idx+1] = args + [op]
            cs.text = "\n" + " ".join(tokens) + "\n"
            print(f"New {name}: {cs.text.strip()}")

tree.write("ark12_patched.ttx")
