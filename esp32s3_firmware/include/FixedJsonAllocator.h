#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include <ArduinoJson.h>

namespace rina {

template <size_t Capacity>
class FixedJsonAllocator : public ArduinoJson::Allocator {
public:
    void* allocate(size_t size) override {
        if (size == 0) {
            return nullptr;
        }

        const size_t headerOffset = alignUp(used_);
        const size_t dataOffset = headerOffset + kHeaderBytes;
        const size_t endOffset = alignUp(dataOffset + size);
        if (endOffset > buffer_.size()) {
            return nullptr;
        }

        auto* header = reinterpret_cast<Header*>(buffer_.data() + headerOffset);
        header->size = size;
        header->endOffset = endOffset;
        used_ = endOffset;
        return buffer_.data() + dataOffset;
    }

    void deallocate(void* ptr) override {
        (void)ptr;
    }

    void* reallocate(void* ptr, size_t newSize) override {
        if (ptr == nullptr) {
            return allocate(newSize);
        }
        if (newSize == 0 || !owns(ptr)) {
            return nullptr;
        }

        auto* header = headerFor(ptr);
        const size_t dataOffset = static_cast<uint8_t*>(ptr) - buffer_.data();
        const size_t newEndOffset = alignUp(dataOffset + newSize);
        if (header->endOffset == used_ && newEndOffset <= buffer_.size()) {
            header->size = newSize;
            header->endOffset = newEndOffset;
            used_ = newEndOffset;
            return ptr;
        }

        void* next = allocate(newSize);
        if (next == nullptr) {
            return nullptr;
        }

        memcpy(next, ptr, std::min(header->size, newSize));
        return next;
    }

private:
    struct Header {
        size_t size;
        size_t endOffset;
    };

    static constexpr size_t kAlign = alignof(std::max_align_t);
    static constexpr size_t kHeaderBytes = ((sizeof(Header) + kAlign - 1U) / kAlign) * kAlign;

    static size_t alignUp(size_t value) {
        return (value + kAlign - 1U) & ~(kAlign - 1U);
    }

    bool owns(const void* ptr) const {
        const auto* bytePtr = static_cast<const uint8_t*>(ptr);
        return bytePtr >= buffer_.data() && bytePtr < buffer_.data() + buffer_.size();
    }

    Header* headerFor(void* ptr) {
        return reinterpret_cast<Header*>(static_cast<uint8_t*>(ptr) - kHeaderBytes);
    }

    alignas(std::max_align_t) std::array<uint8_t, Capacity> buffer_{};
    size_t used_ = 0;
};

}  // namespace rina
