// Temp-directory backed fake of the LittleFS API subset used by storage.cpp and
// protocol.cpp, with fault injection. Test shim only.
#pragma once
#include <Arduino.h>
#include <string>

struct FakeFsFaults {
    long writeLimitBytes = -1;   // >=0: each open-for-write accepts at most this many bytes (ENOSPC)
    bool failRename = false;
    bool failOpenWrite = false;
    unsigned renames = 0;
    unsigned partialWrites = 0;
};
extern FakeFsFaults g_fsFaults;
extern std::string g_fsRoot;

class File {
public:
    File() = default;
    File(const std::string& full, const char* mode);
    explicit operator bool() const { return open_; }
    size_t size() const { return data_.size(); }
    String readString();
    size_t readBytes(char* out, size_t n);
    size_t read(uint8_t* out, size_t n);
    bool seek(size_t pos) { pos_ = pos <= data_.size() ? pos : data_.size(); return true; }
    size_t print(const String& s) { return write(reinterpret_cast<const uint8_t*>(s.c_str()), s.length()); }
    size_t write(const uint8_t* p, size_t n);
    void flush() {}
    void close();
private:
    std::string full_;
    std::string data_;
    size_t pos_ = 0;
    bool open_ = false;
    bool writing_ = false;
    long budget_ = -1;
};

class FakeLittleFS {
public:
    bool begin(bool, const char*, int, const char*) { return true; }
    bool exists(const char* p);
    bool exists(const String& p) { return exists(p.c_str()); }
    bool mkdir(const char* p);
    bool remove(const char* p);
    bool remove(const String& p) { return remove(p.c_str()); }
    bool rename(const String& from, const char* to);
    File open(const char* p, const char* mode);
    File open(const String& p, const char* mode) { return open(p.c_str(), mode); }
};
extern FakeLittleFS LittleFS;
