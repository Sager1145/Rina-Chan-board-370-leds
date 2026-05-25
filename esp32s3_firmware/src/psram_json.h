#pragma once

#include <ArduinoJson.h>
#include <esp_heap_caps.h>

struct SpiRamAllocator {
    /**
     * @brief Allocate ArduinoJson storage, preferring PSRAM.
     * @param size Requested bytes.
     * @return Allocated pointer, or nullptr when both memory tiers fail.
     */
    void* allocate(size_t size) {
        void* ptr = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_malloc(size, MALLOC_CAP_8BIT);
    }

    /**
     * @brief Free memory allocated by this allocator.
     * @param pointer Pointer returned by allocate/reallocate.
     * @return None.
     */
    void deallocate(void* pointer) {
        heap_caps_free(pointer);
    }

    /**
     * @brief Resize ArduinoJson storage, preferring PSRAM.
     * @param pointer Existing allocation.
     * @param newSize Requested new size in bytes.
     * @return Reallocated pointer, or nullptr on failure.
     */
    void* reallocate(void* pointer, size_t newSize) {
        void* ptr = heap_caps_realloc(pointer, newSize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (ptr != nullptr) return ptr;
        return heap_caps_realloc(pointer, newSize, MALLOC_CAP_8BIT);
    }
};

using PsramJsonDocument = BasicJsonDocument<SpiRamAllocator>;
