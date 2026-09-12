#!/usr/bin/env python3
"""Exercise production serial input scheduling and bounded TX queue helpers."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SERIAL_CONSOLE = (ROOT / "src/serial_console.cpp").read_text()
SERIAL_LOG = (ROOT / "src/serial_log.cpp").read_text()


def function(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


# Ownership checks cover the calls surrounding hardware-only APIs that cannot
# run in the host binary.
run_line = function(SERIAL_CONSOLE, "void runLine(")
assert run_line.count("takeOverExternalFrame();") == 2
assert run_line.index("takeOverExternalFrame();") < run_line.index('applyBlankFrame("serial_frame_clear")')
assert run_line.rindex("takeOverExternalFrame();") < run_line.index("applyPackedFrameQueued(")


serial_code = r'''
#include <algorithm>
#include <cassert>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

constexpr uint16_t SERIAL_CMD_MAX = 192;
constexpr uint16_t SERIAL_RX_BUDGET_PER_PORT = 64;
enum class SerialByteResult : uint8_t { None, LineReady, LineTooLong };
struct SerialLineBuffer {
    char bytes[SERIAL_CMD_MAX];
    uint16_t length = 0;
    bool discarding = false;
};
static std::vector<std::string> commands;
static unsigned errors = 0;
void runLine(char* line) { commands.emplace_back(line); }
void sout(const char*, ...) { ++errors; }
struct Stream {
    std::deque<char> input;
    int available() const { return static_cast<int>(input.size()); }
    int read() { char c = input.front(); input.pop_front(); return c; }
    void add(const std::string& s) { input.insert(input.end(), s.begin(), s.end()); }
};
'''
serial_code += function(SERIAL_CONSOLE, "SerialByteResult acceptSerialByte(")
serial_code += "\n" + function(SERIAL_CONSOLE, "void serviceSerialInput(")
serial_code += r'''
int main() {
    Stream usb;
    SerialLineBuffer line;
    usb.add(std::string(SERIAL_CMD_MAX, 'x') + "status\nstatus\r\n");
    while (usb.available()) {
        const int before = usb.available();
        serviceSerialInput(usb, line);
        assert(before - usb.available() <= SERIAL_RX_BUDGET_PER_PORT);
    }
    assert(errors == 1);
    assert(commands.size() == 1 && commands[0] == "status");

    Stream uart;
    SerialLineBuffer uartLine;
    uart.add("help\nstatus\n");
    serviceSerialInput(uart, uartLine);
    assert(commands.size() == 3);
    assert(commands[1] == "help" && commands[2] == "status");

    Stream burst;
    SerialLineBuffer burstLine;
    for (int i = 0; i < 200; ++i)
        burst.add("help\n");
    unsigned turns = 0;
    while (burst.available()) {
        const int before = burst.available();
        serviceSerialInput(burst, burstLine);
        assert(before - burst.available() <= SERIAL_RX_BUDGET_PER_PORT);
        ++turns;
    }
    assert(turns > 1);
    assert(commands.size() == 203);
}
'''


queue_code = r'''
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <vector>
#define portENTER_CRITICAL(x) ((void)(x))
#define portEXIT_CRITICAL(x) ((void)(x))
using portMUX_TYPE = int;
static portMUX_TYPE sSerialTxMux = 0;
static constexpr size_t SERIAL_TX_QUEUE_BYTES = 2048;
static constexpr size_t SERIAL_TX_CONSOLE_RESERVE = 768;
static constexpr size_t SERIAL_TX_PUMP_BUDGET = 128;
struct SerialTxQueue {
    uint8_t bytes[SERIAL_TX_QUEUE_BYTES] = {};
    size_t head = 0;
    size_t count = 0;
    bool pumping = false;
};
'''
queue_code += function(SERIAL_LOG, "static bool enqueueSerialBytes(")
queue_code += "\ntemplate <typename Port>\n" + function(SERIAL_LOG, "static void pumpSerialQueue(")
queue_code += r'''
struct Port {
    int room = 0;
    std::vector<uint8_t> output;
    int availableForWrite() const { return room; }
    size_t write(const uint8_t* bytes, size_t size) {
        output.insert(output.end(), bytes, bytes + size);
        return size;
    }
};
int main() {
    SerialTxQueue queue;
    std::vector<uint8_t> logLine(240, 1);
    for (int i = 0; i < 5; ++i)
        assert(enqueueSerialBytes(queue, logLine.data(), logLine.size(), SERIAL_TX_CONSOLE_RESERVE));
    assert(!enqueueSerialBytes(queue, logLine.data(), logLine.size(), SERIAL_TX_CONSOLE_RESERVE));
    std::vector<uint8_t> reply(700, 2);
    assert(enqueueSerialBytes(queue, reply.data(), reply.size(), 0));
    assert(queue.count == 1900);

    Port port;
    port.room = 17;
    pumpSerialQueue(queue, port);
    assert(port.output.size() == 17 && queue.count == 1883);
    port.room = 1000;
    pumpSerialQueue(queue, port);
    assert(port.output.size() == 17 + SERIAL_TX_PUMP_BUDGET);
    assert(queue.count == 1883 - SERIAL_TX_PUMP_BUDGET);
}
'''


with tempfile.TemporaryDirectory(prefix="rina-serial-network-test-") as directory:
    directory = Path(directory)
    for name, code in (("serial", serial_code), ("queue", queue_code)):
        source = directory / f"{name}.cpp"
        binary = directory / name
        source.write_text(code)
        subprocess.run(
            ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)],
            check=True,
        )
        subprocess.run([str(binary)], check=True)

print("PASS: serial budgets/overflow, takeover ordering, response reserve/non-blocking TX pump")
