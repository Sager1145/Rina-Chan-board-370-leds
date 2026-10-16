#!/usr/bin/env python3
"""Verify every firmware call against the App catalog and independent placement."""
from pathlib import Path
import json
import random
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
FW = ROOT / 'esp32s3_firmware'
subprocess.run(['python3', str(FW / 'tools/generate_expression_parts.py'), '--check'], check=True)
catalog = json.loads((ROOT / 'ios/RinaBoard/Resources/expression_parts.json').read_text())
fields = ('leye', 'reye', 'mouth', 'cheek')
# Independently reconstruct every logical bitmap from local row data and placement,
# including mirrored cheeks; never apply the physical serpentine permutation here.
ranges = catalog['matrix']['row_valid_x_ranges']
lengths = catalog['matrix']['row_lengths']
for key, part in catalog['parts'].items():
    packed = bytearray(47)
    for placement in part['placement']:
        for y, row in enumerate(part['row_hex']):
            for x in range(part['size'][0]):
                if not int(row, 16) & (1 << (7-x)):
                    continue
                gx = placement['x'] + (part['size'][0]-1-x if placement.get('mirror_x') else x)
                gy = placement['y'] + y
                if not 0 <= gy < len(ranges) or not ranges[gy][0] <= gx <= ranges[gy][1]:
                    continue
                index = sum(lengths[:gy]) + gx-ranges[gy][0]
                packed[index >> 3] |= 1 << (index & 7)
    assert packed == bytes.fromhex(part['frame']), key

cases = []
for group, field in enumerate(fields):
    for call in catalog['call']['map'][field]:
        case = ['0'] * 4
        case[group] = call
        cases.append(case)
rng = random.Random(370)
for _ in range(256):
    cases.append([rng.choice(list(catalog['call']['map'][field])) for field in fields])
# Unknown ID and a known ID in the wrong group must never resolve.
cases += [['999', '0', '0', '0'], ['201', '0', '0', '0']]
with tempfile.TemporaryDirectory(prefix='rina-parts-') as directory:
    scratch = Path(directory)
    source = scratch / 'parts.cpp'
    source.write_text(r'''
#include "expression_parts.h"
#include <cstdio>
#include <iostream>
int main() {
    uint16_t ids[4];
    while (std::cin >> ids[0] >> ids[1] >> ids[2] >> ids[3]) {
        uint8_t out[47];
        if (!expression_parts::compose(ids, out)) { puts("invalid"); continue; }
        for (uint8_t byte : out) printf("%02x", byte);
        puts("");
    }
}
''')
    binary = scratch / 'parts'
    subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    '-I'+str(FW / 'src'), str(source), '-o', str(binary)], check=True)
    actual = subprocess.run([str(binary)], input='\n'.join(' '.join(case) for case in cases)+'\n',
                            capture_output=True, text=True, check=True).stdout.splitlines()
    assert len(actual) == len(cases)
    for case, result in zip(cases, actual):
        if any(call not in catalog['call']['map'][field] for field, call in zip(fields, case)):
            assert result == 'invalid', case
            continue
        parts = [bytes.fromhex(catalog['parts'][catalog['call']['map'][field][call]]['frame'])
                 for field, call in zip(fields, case)]
        expected = bytes(a|b|c|d for a,b,c,d in zip(*parts)).hex()
        assert result == expected, case
print(f'Expression parts: all 92 placements, {len(cases)} firmware call/composition cases passed.')
