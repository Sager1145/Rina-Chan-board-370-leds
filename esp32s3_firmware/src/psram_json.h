#pragma once

#include <ArduinoJson.h>
#include <esp_heap_caps.h>


// 本文件为 ArduinoJson 文档选择 PSRAM 优先的内存分配器；注释保留必要 English identifier，便于和代码/API 对照。
struct SpiRamAllocator {
    void* allocate(size_t size) {
        void* ptr = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_malloc(size, MALLOC_CAP_8BIT);
    }

    void deallocate(void* pointer) {
        heap_caps_free(pointer);
    }

    void* reallocate(void* pointer, size_t newSize) {
        void* ptr = heap_caps_realloc(pointer, newSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_realloc(pointer, newSize, MALLOC_CAP_8BIT);
    }
};

using PsramJsonDocument = BasicJsonDocument<SpiRamAllocator>;
