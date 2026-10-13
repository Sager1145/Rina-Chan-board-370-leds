#!/usr/bin/env python3
"""Exercise the production SDK IPC stack interposer and its forwarding contract.

The final firmware link map must also confirm GNU --wrap redirects the SDK's
constructor call. On macOS this test calls the actual interposer directly.
"""
from pathlib import Path
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[2] / 'src/ipc_stack.cpp'
types = r'''
#pragma once
#include <cstdint>
using BaseType_t = int32_t;
using UBaseType_t = uint32_t;
using TaskHandle_t = void*;
using TaskFunction_t = void (*)(void*);
'''
code = r'''
#include <freertos/task.h>
#include <cassert>
#include <iostream>
#include <cstring>
struct Creation {
    TaskFunction_t function;
    const char* name;
    uint32_t stack;
    void* argument;
    UBaseType_t priority;
    TaskHandle_t* handle;
    BaseType_t core;
} created;
extern "C" BaseType_t __real_xTaskCreatePinnedToCore(TaskFunction_t function,
        const char* name, uint32_t stack, void* argument, UBaseType_t priority,
        TaskHandle_t* handle, BaseType_t core) {
    created = {function, name, stack, argument, priority, handle, core};
    *handle = reinterpret_cast<TaskHandle_t>(0x1234);
    return 17;
}
'''
# With no interposer, the SDK calls the original allocator with its 1024-byte
# request. This alias makes that existing behavior observable for the red run.
code += ('#include "' + str(SOURCE) + '"\n' if SOURCE.exists() else
         '#define __wrap_xTaskCreatePinnedToCore __real_xTaskCreatePinnedToCore\n')
code += r'''
void task(void*) {}
void check(const char* name, uint32_t requested, uint32_t expected, BaseType_t core) {
    int argument = 3; TaskHandle_t handle = nullptr;
    const auto result = __wrap_xTaskCreatePinnedToCore(task, name, requested,
        &argument, 24, &handle, core);
    if (created.stack != expected) {
        std::cerr << "FAIL: " << (name ? name : "null") << " stack " << created.stack
                  << " expected " << expected << '\n'; std::exit(1);
    }
    assert(result == 17 && handle == reinterpret_cast<TaskHandle_t>(0x1234));
    assert(created.function == task && created.name == name && created.argument == &argument);
    assert(created.priority == 24 && created.handle == &handle && created.core == core);
}
int main() {
    check("ipc0", 1024, 2048, 0);
    check("ipc1", 1024, 2048, 1);
    check("ipc0", 4096, 4096, 0);
    check("ipc1", 2048, 2048, 1);
    check("ipc0", 1024, 1024, 1); // not the SDK's core/name pair
    check("ipc1", 1024, 1024, 0);
    for (const char* name : {"loopTask", "led_scroll_render", "nimble_host", "ipc", "ipc01", "ipc2", "IPC0", static_cast<const char*>(nullptr)})
        check(name, 1024, 1024, 0);
    std::cout << "PASS: SDK ipc0/ipc1 minimum, larger stacks and other tasks unchanged, all arguments/result forwarded\n";
}
'''
with tempfile.TemporaryDirectory(prefix='rina-ipc-stack-') as temporary:
    directory = Path(temporary)
    (directory / 'freertos').mkdir()
    (directory / 'freertos/FreeRTOS.h').write_text(types)
    (directory / 'freertos/task.h').write_text('#include "FreeRTOS.h"\n')
    source = directory / 'test.cpp'; source.write_text(code)
    binary = directory / 'test'
    subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                    '-DESP_PLATFORM=1', '-DCONFIG_IDF_TARGET_ESP32S3=1',
                    '-I' + str(directory), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
