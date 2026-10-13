#pragma once
#include <Arduino.h>
constexpr int HTTP_GET = 0, HTTP_POST = 1;
struct FakeWebClient { void flush() {} };
class WebServer {
  public:
    inline static bool running = false;
    explicit WebServer(uint16_t) {}
    void on(const char*, int, void (*)()) {}
    void onNotFound(void (*)()) {}
    bool hasArg(const char*) { return false; }
    String arg(const char*) { return ""; }
    void send(int, const char*, const String&) {}
    void send_P(int, const char*, const char*) {}
    FakeWebClient client() { return {}; }
    void begin() { running = true; }
    void stop() { running = false; }
    void handleClient() {}
};
