#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <string.h>

#if defined(CONFIG_IDF_TARGET_ESP32S3)
// Arduino's prebuilt IDF 5.5.4 creates ipc0/ipc1 with 1024 bytes. On the
// verified 912c718e2 image, BLE's btdm_intr_alloc -> esp_intr_alloc -> heap
// allocation exhausted ipc0's stack when Xtensa saved interrupt context.
// The recorded call-stack addresses span 720 bytes before the remaining
// task-entry/window-spill overhead; the canary proves 1024 is insufficient.
// Reserve 2048 bytes for these two SDK callbacks, including exception entry.
// A -D sdkconfig override cannot resize tasks inside the prebuilt library.
// The linker wraps only this creation seam; application/BLE/LED task budgets
// and every other creation argument retain the caller's values.
namespace {
constexpr uint32_t SDK_IPC_MIN_STACK_BYTES = 2048;
}

extern "C" BaseType_t __real_xTaskCreatePinnedToCore(
    TaskFunction_t function, const char* name, uint32_t stackBytes,
    void* argument, UBaseType_t priority, TaskHandle_t* handle, BaseType_t core);

extern "C" BaseType_t __wrap_xTaskCreatePinnedToCore(
    TaskFunction_t function, const char* name, uint32_t stackBytes,
    void* argument, UBaseType_t priority, TaskHandle_t* handle, BaseType_t core) {
    const bool sdkIpcTask = name &&
        ((core == 0 && strcmp(name, "ipc0") == 0) ||
         (core == 1 && strcmp(name, "ipc1") == 0));
    if (sdkIpcTask && stackBytes < SDK_IPC_MIN_STACK_BYTES)
        stackBytes = SDK_IPC_MIN_STACK_BYTES;
    return __real_xTaskCreatePinnedToCore(function, name, stackBytes,
                                         argument, priority, handle, core);
}
#endif
