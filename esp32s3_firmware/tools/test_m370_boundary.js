#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");

const LED_COUNT = 370;
const M370_HEX_CHARS = 93;
const FRAME_BYTES = Math.ceil(LED_COUNT / 8);

function normalizeM370(input) {
  const payload = String(input || "").trim();
  const body = payload.toUpperCase().startsWith("M370:") ? payload.slice(5) : payload;
  const compact = body.replace(/[ \r\n\t]/g, "").toUpperCase();
  assert.equal(compact.length, M370_HEX_CHARS, "M370 payload length");
  assert.match(compact, /^[0-9A-F]+$/, "M370 payload hex");
  return `M370:${compact}`;
}

function m370ToPackedBits(input) {
  const normalized = normalizeM370(input);
  const bits = new Uint8Array(FRAME_BYTES);
  const hex = normalized.slice(5);
  for (let nib = 0; nib < M370_HEX_CHARS; nib++) {
    const value = Number.parseInt(hex[nib], 16);
    if (value <= 0) continue;
    const baseBit = nib * 4;
    for (let k = 0; k < 4; k++) {
      if ((value & (1 << (3 - k))) === 0) continue;
      const bit = baseBit + k;
      if (bit < LED_COUNT) bits[bit >> 3] |= 1 << (bit & 7);
    }
  }
  return bits;
}

function packedBitsToM370(bits) {
  let hex = "";
  for (let nib = 0; nib < M370_HEX_CHARS; nib++) {
    let value = 0;
    const baseBit = nib * 4;
    for (let k = 0; k < 4; k++) {
      const bit = baseBit + k;
      if (bit < LED_COUNT && (bits[bit >> 3] & (1 << (bit & 7)))) {
        value |= 1 << (3 - k);
      }
    }
    hex += value.toString(16).toUpperCase();
  }
  return `M370:${hex}`;
}

function bitIsSet(bits, bit) {
  return (bits[bit >> 3] & (1 << (bit & 7))) !== 0;
}

const blank = `M370:${"0".repeat(M370_HEX_CHARS)}`;
assert.equal(packedBitsToM370(m370ToPackedBits(blank)), blank);

const bit369 = new Uint8Array(FRAME_BYTES);
bit369[369 >> 3] |= 1 << (369 & 7);
const encoded369 = packedBitsToM370(bit369);
assert.equal(encoded369.slice(-1), "4", "bit 369 maps to the second valid bit of final nibble");
assert.equal(packedBitsToM370(m370ToPackedBits(encoded369)), encoded369);

const paddingOnly = m370ToPackedBits(`M370:${"0".repeat(M370_HEX_CHARS - 1)}3`);
assert.equal(bitIsSet(paddingOnly, 368), false, "padding bit 370 must not light LED 368");
assert.equal(bitIsSet(paddingOnly, 369), false, "padding bit 371 must not light LED 369");
assert.equal(packedBitsToM370(paddingOnly).slice(-1), "0", "padding bits roundtrip cleared");

const finalNibbleAllSet = m370ToPackedBits(`M370:${"0".repeat(M370_HEX_CHARS - 1)}F`);
assert.equal(bitIsSet(finalNibbleAllSet, 368), true);
assert.equal(bitIsSet(finalNibbleAllSet, 369), true);
assert.equal(packedBitsToM370(finalNibbleAllSet).slice(-1), "C", "padding bits are ignored on encode");

console.log("M370 boundary tests passed");
