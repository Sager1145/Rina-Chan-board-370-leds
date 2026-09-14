#pragma once
#include <cstdlib>
#define MALLOC_CAP_SPIRAM 1
#define MALLOC_CAP_8BIT 2
#define MALLOC_CAP_INTERNAL 4
extern size_t g_fakeMallocFailAbove; // allocations larger than this fail (SIZE_MAX = never)
inline void* heap_caps_malloc(size_t n, int) { return n > g_fakeMallocFailAbove ? nullptr : std::malloc(n); }
inline void* heap_caps_realloc(void* p, size_t n, int) { return n > g_fakeMallocFailAbove ? nullptr : std::realloc(p, n); }
inline void heap_caps_free(void* p) { std::free(p); }
