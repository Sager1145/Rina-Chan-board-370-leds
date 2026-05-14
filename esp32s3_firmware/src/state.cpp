#include "state.h"

RuntimeState      state;
RuntimeFace       autoFaces[MAX_AUTO_FACES];
uint16_t          autoFaceCount       = 0;

uint8_t           frameBits[FRAME_BYTES]                      = {};
uint8_t           scrollFrameBits[MAX_SCROLL_FRAMES][FRAME_BYTES] = {};

bool              fsMounted           = false;

SemaphoreHandle_t frameMutex          = nullptr;
SemaphoreHandle_t scrollMutex         = nullptr;
TaskHandle_t      scrollTaskHandle    = nullptr;

portMUX_TYPE      ledRenderRequestMux = portMUX_INITIALIZER_UNLOCKED;
volatile bool     ledRenderRequested  = false;
uint32_t          lastLedShowUs       = 0;

uint16_t          logicalToPhysicalMap[LED_COUNT] = {};
