#!/usr/bin/env python3
"""Verify receive-overflow recovery is wired to reset or close the stream."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = (ROOT / "esp32s3_firmware/src/protocol.cpp").read_text()
BLE = (ROOT / "esp32s3_firmware/src/transport_ble.cpp").read_text()


def block_after(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"unterminated block after {marker!r}")


mark_resync = block_after(PROTOCOL, "void transportMarkResyncNeeded(ClientId id)")
critical_start = mark_resync.index("portENTER_CRITICAL(&c.mux);")
critical = mark_resync[critical_start:mark_resync.index("portEXIT_CRITICAL(&c.mux);", critical_start)]
assert "c.inboundLen = 0;" in critical
assert "c.oversizedBytesRemaining = 0;" in critical
assert "c.resyncNeeded = true;" in critical

rx_written = block_after(BLE, "void onRxWritten(uint16_t connHandle")
overflow = block_after(rx_written, "if (len > free)")
assert "transportUnregisterClient(activeId);" in overflow
assert "transportMarkResyncNeeded(activeId);" not in overflow

process_inbound = block_after(PROTOCOL, "static void processClientInbound")
oversized_block = block_after(process_inbound, "if (popped.oversized)")
assert "transportUnregisterClient(" in oversized_block
assert "return;" in oversized_block

ble_disconnect = block_after(BLE, "void disconnect(rinalink::ClientId id) override")
assert "terminate_failed" in ble_disconnect
assert "mTerminatePending = true" in ble_disconnect

ble_service = block_after(BLE, "void service()")
assert "mTerminatePending" in ble_service

ble_peer_disconnected = block_after(BLE, "void onPeerDisconnected(")
assert "mTerminatePending = false" in ble_peer_disconnected

print("PASS: resync clears oversized discard state; BLE overflow disconnects its client; "
      "oversized-frame path disconnects; BLE terminate failures retry via mTerminatePending")
