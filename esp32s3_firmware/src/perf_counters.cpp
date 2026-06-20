#include "perf_counters.h"

#if ENABLE_PERF_PROFILING

#include "sync.h"
#include <freertos/portmacro.h>

static portMUX_TYPE sPerfMux = portMUX_INITIALIZER_UNLOCKED;

volatile uint32_t currentFrameAcceptedUs = 0;
volatile uint32_t lastRenderRequestUs = 0;
volatile uint32_t renderStartUs = 0;
volatile uint32_t showDoneUs = 0;

// Helper to track min/max/sum/count
struct PerfStat {
    uint32_t maxVal = 0;
    uint64_t sumVal = 0;
    uint32_t count = 0;

    void record(uint32_t val) {
        if (val > maxVal) maxVal = val;
        sumVal += val;
        count++;
    }

    void clear() {
        maxVal = 0;
        sumVal = 0;
        count = 0;
    }
};

static struct {
    PerfStat apiTotal;
    PerfStat apiParse;
    PerfStat apiApply;
    PerfStat apiResponse;
    PerfStat bodySize;
    uint32_t apiFrameCount = 0;
    uint32_t apiLiveCount = 0;
    uint32_t apiDeltaCount = 0;

    PerfStat renderRequestToStart;
    PerfStat renderPixelLoop;
    PerfStat renderShow;
    PerfStat renderTotal;
    PerfStat renderFrameAcceptedToStart;
    PerfStat renderStartToShowDone;
    PerfStat renderFrameAcceptedToShowDone;

    uint32_t queueEnqueued = 0;
    uint32_t queueDequeued = 0;
    uint32_t queueDropped = 0;
    PerfStat queueDequeueAge;

    PerfStat buttonScan;
    PerfStat buttonAction;
    PerfStat powerService;

    uint64_t serialAttemptedBytes = 0;
    uint64_t serialEmittedBytes = 0;
    uint64_t serialDroppedBytes = 0;
} gPerfData;

void perfRecordApiFrame(uint32_t totalUs, uint32_t parseUs, uint32_t applyUs, uint32_t responseUs, size_t bodySize, uint16_t deltaCount, bool isLive, bool isDelta) {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.apiTotal.record(totalUs);
    gPerfData.apiParse.record(parseUs);
    gPerfData.apiApply.record(applyUs);
    gPerfData.apiResponse.record(responseUs);
    gPerfData.bodySize.record(bodySize);
    gPerfData.apiFrameCount++;
    if (isLive) gPerfData.apiLiveCount++;
    if (isDelta) gPerfData.apiDeltaCount++;
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordRender(uint32_t requestToStartUs, uint32_t pixelLoopUs, uint32_t showUs, uint32_t totalUs) {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.renderRequestToStart.record(requestToStartUs);
    gPerfData.renderPixelLoop.record(pixelLoopUs);
    gPerfData.renderShow.record(showUs);
    gPerfData.renderTotal.record(totalUs);

    // Calculate render age tracking values
    uint32_t frameAcceptedToStart = renderStartUs > currentFrameAcceptedUs ? (renderStartUs - currentFrameAcceptedUs) : 0;
    uint32_t startToShowDone = showDoneUs > renderStartUs ? (showDoneUs - renderStartUs) : 0;
    uint32_t frameAcceptedToShowDone = showDoneUs > currentFrameAcceptedUs ? (showDoneUs - currentFrameAcceptedUs) : 0;

    gPerfData.renderFrameAcceptedToStart.record(frameAcceptedToStart);
    gPerfData.renderStartToShowDone.record(startToShowDone);
    gPerfData.renderFrameAcceptedToShowDone.record(frameAcceptedToShowDone);
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordQueueEnqueue() {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.queueEnqueued++;
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordQueueDequeue(uint32_t ageUs) {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.queueDequeued++;
    gPerfData.queueDequeueAge.record(ageUs);
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordQueueDropped() {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.queueDropped++;
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordButtonScan(uint32_t scanUs) {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.buttonScan.record(scanUs);
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordButtonAction(uint32_t actionUs) {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.buttonAction.record(actionUs);
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordPowerService(uint32_t serviceUs) {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.powerService.record(serviceUs);
    portEXIT_CRITICAL(&sPerfMux);
}

void perfRecordSerialLogBytes(size_t attempted, size_t emitted, size_t dropped) {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.serialAttemptedBytes += attempted;
    gPerfData.serialEmittedBytes += emitted;
    gPerfData.serialDroppedBytes += dropped;
    portEXIT_CRITICAL(&sPerfMux);
}

void perfClearCounters() {
    portENTER_CRITICAL(&sPerfMux);
    gPerfData.apiTotal.clear();
    gPerfData.apiParse.clear();
    gPerfData.apiApply.clear();
    gPerfData.apiResponse.clear();
    gPerfData.bodySize.clear();
    gPerfData.apiFrameCount = 0;
    gPerfData.apiLiveCount = 0;
    gPerfData.apiDeltaCount = 0;

    gPerfData.renderRequestToStart.clear();
    gPerfData.renderPixelLoop.clear();
    gPerfData.renderShow.clear();
    gPerfData.renderTotal.clear();
    gPerfData.renderFrameAcceptedToStart.clear();
    gPerfData.renderStartToShowDone.clear();
    gPerfData.renderFrameAcceptedToShowDone.clear();

    gPerfData.queueEnqueued = 0;
    gPerfData.queueDequeued = 0;
    gPerfData.queueDropped = 0;
    gPerfData.queueDequeueAge.clear();

    gPerfData.buttonScan.clear();
    gPerfData.buttonAction.clear();
    gPerfData.powerService.clear();

    gPerfData.serialAttemptedBytes = 0;
    gPerfData.serialEmittedBytes = 0;
    gPerfData.serialDroppedBytes = 0;
    portEXIT_CRITICAL(&sPerfMux);
}

void perfSerializeCounters(JsonDocument& doc) {
    portENTER_CRITICAL(&sPerfMux);
    JsonObject apiFrame = doc.createNestedObject("apiFrame");
    apiFrame["count"] = gPerfData.apiFrameCount;
    apiFrame["liveCount"] = gPerfData.apiLiveCount;
    apiFrame["deltaCount"] = gPerfData.apiDeltaCount;
    apiFrame["maxTotalUs"] = gPerfData.apiTotal.maxVal;
    apiFrame["avgTotalUs"] = gPerfData.apiTotal.count ? (gPerfData.apiTotal.sumVal / gPerfData.apiTotal.count) : 0;
    apiFrame["maxParseUs"] = gPerfData.apiParse.maxVal;
    apiFrame["avgParseUs"] = gPerfData.apiParse.count ? (gPerfData.apiParse.sumVal / gPerfData.apiParse.count) : 0;
    apiFrame["maxApplyUs"] = gPerfData.apiApply.maxVal;
    apiFrame["avgApplyUs"] = gPerfData.apiApply.count ? (gPerfData.apiApply.sumVal / gPerfData.apiApply.count) : 0;
    apiFrame["maxResponseUs"] = gPerfData.apiResponse.maxVal;
    apiFrame["avgResponseUs"] = gPerfData.apiResponse.count ? (gPerfData.apiResponse.sumVal / gPerfData.apiResponse.count) : 0;
    apiFrame["maxBodySize"] = gPerfData.bodySize.maxVal;

    JsonObject render = doc.createNestedObject("render");
    render["count"] = gPerfData.renderRequestToStart.count;
    render["maxRequestToStartUs"] = gPerfData.renderRequestToStart.maxVal;
    render["avgRequestToStartUs"] = gPerfData.renderRequestToStart.count ? (gPerfData.renderRequestToStart.sumVal / gPerfData.renderRequestToStart.count) : 0;
    render["maxPixelLoopUs"] = gPerfData.renderPixelLoop.maxVal;
    render["avgPixelLoopUs"] = gPerfData.renderPixelLoop.count ? (gPerfData.renderPixelLoop.sumVal / gPerfData.renderPixelLoop.count) : 0;
    render["maxShowUs"] = gPerfData.renderShow.maxVal;
    render["avgShowUs"] = gPerfData.renderShow.count ? (gPerfData.renderShow.sumVal / gPerfData.renderShow.count) : 0;
    render["maxTotalUs"] = gPerfData.renderTotal.maxVal;
    render["avgTotalUs"] = gPerfData.renderTotal.count ? (gPerfData.renderTotal.sumVal / gPerfData.renderTotal.count) : 0;

    render["maxFrameAcceptedToRenderStartUs"] = gPerfData.renderFrameAcceptedToStart.maxVal;
    render["avgFrameAcceptedToRenderStartUs"] = gPerfData.renderFrameAcceptedToStart.count ? (gPerfData.renderFrameAcceptedToStart.sumVal / gPerfData.renderFrameAcceptedToStart.count) : 0;
    render["maxRenderRequestToRenderStartUs"] = gPerfData.renderRequestToStart.maxVal;
    render["avgRenderRequestToRenderStartUs"] = gPerfData.renderRequestToStart.count ? (gPerfData.renderRequestToStart.sumVal / gPerfData.renderRequestToStart.count) : 0;
    render["maxRenderStartToShowDoneUs"] = gPerfData.renderStartToShowDone.maxVal;
    render["avgRenderStartToShowDoneUs"] = gPerfData.renderStartToShowDone.count ? (gPerfData.renderStartToShowDone.sumVal / gPerfData.renderStartToShowDone.count) : 0;
    render["maxFrameAcceptedToShowDoneUs"] = gPerfData.renderFrameAcceptedToShowDone.maxVal;
    render["avgFrameAcceptedToShowDoneUs"] = gPerfData.renderFrameAcceptedToShowDone.count ? (gPerfData.renderFrameAcceptedToShowDone.sumVal / gPerfData.renderFrameAcceptedToShowDone.count) : 0;

    JsonObject m370Queue = doc.createNestedObject("m370Queue");
    m370Queue["enqueued"] = gPerfData.queueEnqueued;
    m370Queue["dequeued"] = gPerfData.queueDequeued;
    m370Queue["dropped"] = gPerfData.queueDropped;
    m370Queue["maxAgeUs"] = gPerfData.queueDequeueAge.maxVal;
    m370Queue["avgAgeUs"] = gPerfData.queueDequeueAge.count ? (gPerfData.queueDequeueAge.sumVal / gPerfData.queueDequeueAge.count) : 0;

    JsonObject power = doc.createNestedObject("power");
    power["maxServiceUs"] = gPerfData.powerService.maxVal;
    power["avgServiceUs"] = gPerfData.powerService.count ? (gPerfData.powerService.sumVal / gPerfData.powerService.count) : 0;

    JsonObject buttons = doc.createNestedObject("buttons");
    buttons["maxScanUs"] = gPerfData.buttonScan.maxVal;
    buttons["avgScanUs"] = gPerfData.buttonScan.count ? (gPerfData.buttonScan.sumVal / gPerfData.buttonScan.count) : 0;
    buttons["maxActionUs"] = gPerfData.buttonAction.maxVal;
    buttons["avgActionUs"] = gPerfData.buttonAction.count ? (gPerfData.buttonAction.sumVal / gPerfData.buttonAction.count) : 0;

    JsonObject serial = doc.createNestedObject("serial");
    serial["attemptedBytes"] = gPerfData.serialAttemptedBytes;
    serial["emittedBytes"] = gPerfData.serialEmittedBytes;
    serial["droppedBytes"] = gPerfData.serialDroppedBytes;
    portEXIT_CRITICAL(&sPerfMux);
}

#endif
