# Independent IPC stack interposer review

## Result

No concrete correctness findings in `esp32s3_firmware/src/ipc_stack.cpp`, the common PlatformIO linker flag, or `test/host/ipc_stack_test.py` for the pinned ESP32-S3 SDK. Read-only review; no source edits, builds, host test runs, serial/port actions, or process changes. Read `/tmp/rina-hardware-boot-diagnosis.md`; did not infer panic-free hardware operation from source/host evidence.

## Verified evidence

- **ABI and units:** Pinned `framework-arduinoespressif32-libs/esp32s3/include/freertos/esp_additions/include/freertos/idf_additions.h:63` declares BaseType_t return with TaskFunction_t, const char*, uint32_t stack depth, void*, UBaseType_t priority, TaskHandle_t*, BaseType_t core. Its documented ulStackDepth is explicitly NUMBER OF BYTES, unlike vanilla FreeRTOS. FreeRTOSConfig.h:126 defines configSTACK_DEPTH_TYPE asuint32_t. Xtensa portmacro.h:87–93 defines StackType_t asuint8_t, BaseType_t asint and UBaseType_t asunsignedint. The wrapper's C ABI matches;2048 means2048bytes, not2048words.
- **Actual SDK creation seam:** Independently inspected pinned qio_opi libesp_system.a using xtensa nm/objdump. esp_ipc.c.obj has undefined xTaskCreatePinnedToCore; libfreertos.a:tasks.c.obj defines it. The constructor's literal relocation at0x34 and call relocation at0x66 target that external symbol, so GNU --wrap can intercept it. The task is not created via a static/WithCaps alternate seam excluded by this wrapper.
- **Actual constructor request:** Disassembly shows priority24 and stack argument0x400 (1024) before the xTaskCreatePinnedToCore call. Constructor name storage begins `ipcX`; it replaces byte3 with `'0' + core` and iterates cores0/1. It passes that same core value as the task affinity. Thus exact ipc0/core0 and ipc1/core1 matching includes both realSDK tasks. Null, lookalike, mismatched-core, and unpinned task requests are intentionally forwarded unchanged.
- **Budget handling:** Only matching requests below2048 are increased. Requests already2048or larger remainunchanged. No application/BLE/LED taskname matches these pairs in the reviewed taskcallers.
- **Forwarding:** Function pointer, original name pointer, argument pointer, priority, output handle pointer and core are passed unchanged. The exact BaseType_t result from the real allocator is returned directly, preserving both success and failure codes. The wrapper has no allocation, retry, handle manipulation, or task-entry substitution.
- **Link wiring and recursion:** Both wrapper/real declarations use externC and exact GNU `__wrap_`/`__real_` names. The sole forwarding call goes to `__real_xTaskCreatePinnedToCore`, which GNU wrapping resolves to the original allocator; it does not call the wrapped public symbol again. The common `-Wl,--wrap=xTaskCreatePinnedToCore` flag is inherited by all four configured environments, which all target ESP32-S3; the CONFIG_IDF_TARGET_ESP32S3 guard is defined in the pinned qio_opi sdkconfig. No configured environment loses the wrapper implementation while retaining its flag.
- **Host oracle:** The test includes the actual production translation unit and checks both IPC pairs, existing larger/equal budgets, mismatched pairs, lookalike/null names and unrelated task names. Its fake returns17 and writes an output handle; assertions require the exact return, handle and all original argument pointers/values, rather than treating the result as a Boolean. The host test is explicit that direct invocation does not itself prove GNU link wrapping.
- **Whitespace:** Scoped git diff --check returned0 with no diagnostics.

## Remaining build/hardware evidence boundary

At review completion `/tmp/rina-repair-firmware-bootfix-build.log` was still at dependency scanning and no new firmware.elf/map was available. Root must inspect the completed ELF/map/disassembly to establish the constructor reference resolves to __wrap_xTaskCreatePinnedToCore and the wrapper forwarding resolves to the original allocator, then perform its already-authorized repeated boot checks. Those are final integration/runtime verification steps, not defects found in this patch.

The recorded matching-image canary fault identifies ipc0 during BLE IRQ allocation; increasing these SDK callback stacks addresses that exact demonstrated seam. This review does not claim2048 has already been shown sufficient on the physical boards, nor recommend unrelated stack changes.

Read-only SDK artifacts saved to `/tmp/rina-sdk-ipc.o` and `/tmp/rina-ipc-sdk-disassembly.txt` for root inspection.
