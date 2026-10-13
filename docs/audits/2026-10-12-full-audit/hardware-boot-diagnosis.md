# Hardware boot panic initial diagnosis

The exact uploaded image is identified: current firmware.elf SHA256 is `912c718e26fe094e42693cc0e9a018df1c6175a3b2394e5b998e96b911618285`, matching panic's `ELF file SHA256: 912c718e2`.

Pinned xtensa-esp32s3-elf-addr2line decoded the full backtrace:

1. _xt_context_save (xtensa_context.S:134)
2. _frxt_int_enter (FreeRTOS portasm.S:133)
3. vPortExitCriticalSafe / multi_heap_internal_unlock (multi_heap.c:176)
4. multi_heap_malloc (multi_heap_poisoning.c:265)
5. aligned_or_unaligned_alloc / heap_caps_aligned_alloc_base (heap_caps_base.c:93/175)
6. heap_caps_malloc_base (heap_caps_base.c:202)
7. heap_caps_malloc (heap_caps.c:84)
8. esp_intr_alloc_intrstatus_bind (intr_alloc.c:574)
9. esp_intr_alloc_intrstatus (intr_alloc.c:717)
10. esp_intr_alloc (intr_alloc.c:728)
11. btdm_intr_alloc (binary BT controller bt.c.obj)
12. ipc_task (esp_ipc.c:84)
13. vPortTaskWrapper (port.c:139)

The task named by the canary is correctly ipc0, not loop/LED/NimBLE host. BLE controller initialization invoked interrupt allocation on its pinned core via the ESP-IDF IPC task; an interrupt entry while deep in heap/interrupt allocation hit the task's canary. Pinned qio_opi sdkconfig sets CONFIG_ESP_IPC_TASK_STACK_SIZE=1024, CONFIG_HEAP_POISONING_LIGHT=1, CONFIG_FREERTOS_WATCHPOINT_END_OF_STACK=1, CONFIG_FREERTOS_ISR_STACKSIZE=2096.

This is not presently evidence of a regression in firmware audit business logic or of RMT transmission failure. Further disassembly/source work is in progress to identify the precise IPC callback and a minimal initialization fix. No source edits, stack-budget changes, hardware commands or uploads yet.

## Root cause and implemented correction

The official pinned [ESP-IDF v5.5.4 Bluetooth controller source](https://raw.githubusercontent.com/espressif/esp-idf/v5.5.4/components/bt/controller/esp32c3/bt.c) (shared by this target) confirms `interrupt_alloc_wrapper` routes the BLE interrupt allocation through `esp_ipc_call_blocking` on dual-core builds. Its `btdm_intr_alloc` callback invokes esp_intr_alloc, matching the binary frame exactly. Moving NimBLE init to another task or changing its caller/core would therefore leave the work on an SDK IPC task with the same inadequate stack.

The [pinned IPC implementation](https://raw.githubusercontent.com/espressif/esp-idf/v5.5.4/components/esp_system/esp_ipc.c) creates the two tasks from an early constructor using its compiled IPC_STACK_SIZE. The local qio_opi configuration fixes that at1024bytes. A source-level -D override in the application cannot resize tasks created inside this precompiled library.

Actual archive-symbol evidence:
- libesp_system.a:esp_ipc.c.obj has undefined xTaskCreatePinnedToCore and private ipc_task/esp_ipc_init.
- libfreertos.a:tasks.c.obj defines xTaskCreatePinnedToCore.
- SDK object relocations explicitly target xTaskCreatePinnedToCore from .literal.startup.esp_ipc_init+0x34 and call slot .text.startup.esp_ipc_init+0x66. Thus GNU link wrapping intercepts the SDK creation reference without a vendor fork.

The recorded bottom/top frame addresses span720bytes (0x3fcba780 minus0x3fcba4b0), including interrupt-entry context-save frames, while additional task-entry/register-window overhead remains. The direct context-save watchpoint is concrete runtime evidence that the1024-byte IPC capacity is insufficient on this image. The correction reserves2048bytes for these two existing callbacks; it does not alter application, LED, Wi-Fi or NimBLE task budgets and adds no retry/allocation fallback.

Implemented:
- New src/ipc_stack.cpp supplies __wrap_xTaskCreatePinnedToCore and forwards to __real_xTaskCreatePinnedToCore.
- platformio.ini common flags add -Wl,--wrap=xTaskCreatePinnedToCore (explicitly root-authorized).
- Only exact `ipc0` with core0 or `ipc1` with core1 requests below2048bytes change. Larger existing SDK budgets remain untouched. The S3-only guard matches the configured board.
- Every caller's task function, name pointer, argument, priority, core, output-handle pointer and return result is preserved.

Regression evidence: `python3 esp32s3_firmware/test/host/ipc_stack_test.py` first failed as `ipc0 stack1024 expected2048` while the original allocator was unwrapped; after adding the actual production interposer it passed. The test includes the real production translation unit, tests both SDK tasks, larger stacks, mismatched core/name pairs, lookalike/null names and all other argument forwarding. macOS linker does not provide GNU --wrap, so host behavior is tested by direct interposer invocation; final firmware ELF/map must separately establish SDK reference redirection. git diff --check passed.

Root is rebuilding/link-verifying and owns both reflashes plus repeated boot checks. This worker performed no port operations. Hardware closure remains pending; the diagnosis and host checks do not themselves establish panic-free boots.
