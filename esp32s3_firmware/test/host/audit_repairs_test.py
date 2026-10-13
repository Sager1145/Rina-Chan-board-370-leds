#!/usr/bin/env python3
"""Fault regressions linked against production firmware translation units.

Only hardware, NVS, radio and scheduling are faked. Each case runs in a fresh
process so firmware file statics have the same initial lifetime as a reboot.
"""
from pathlib import Path
import concurrent.futures
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
FW = ROOT / 'esp32s3_firmware'
HERE = Path(__file__).resolve().parent
HARNESS = ROOT / 'docs/stress-20260912-211559/tools/firmware'


def remove_function(text, signature):
    start = text.index(signature)
    brace = text.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[:start] + text[end:]


with tempfile.TemporaryDirectory(prefix='rina-audit-repairs-') as directory:
    sandbox = Path(directory)
    fakes = sandbox / 'fakes'
    shutil.copytree(HARNESS / 'stress_fakes', fakes)
    shutil.copy2(HARNESS / 'stress_common.h', sandbox / 'stress_common.h')
    for path in (HERE / 'audit_fakes').rglob('*.h'):
        destination = fakes / path.relative_to(HERE / 'audit_fakes')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    platform = (fakes / 'fake_platform.cpp').read_text()
    # Replace only hardware adapters needed by this test with configurable ones;
    # Wi-Fi and button-animation behavior comes from the actual production TUs.
    start = platform.index('void startButtonAnimationForGpioAction(')
    end = platform.index('void initHardwareButtons()', start)
    platform = platform[:start] + platform[end:]
    start = platform.index('bool g_fakeWifiChanged =')
    end = platform.index('PowerStatus powerStatus;', start)
    platform = platform[:start] + platform[end:]
    for sig in ('void setPixel(', 'void clear()', 'bool refresh()'):
        platform = remove_function(platform, sig)
    # The shared adapter now provides this weak default; this harness supplies
    # its own adapter in the same TU, so remove the default before appending it.
    platform = remove_function(platform, '__attribute__((weak)) bool isBrightnessButtonCode(')
    platform += '\n' + (HERE / 'audit_fakes/platform_hooks.cpp').read_text()
    (fakes / 'fake_platform.cpp').write_text(platform)
    arduino = (fakes / 'Arduino.h').read_text()
    arduino = arduino.replace('void toLowerCase()', 'void toUpperCase() { for (auto& ch : s) ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch))); }\n    void toLowerCase()')
    arduino += '\nusing std::min; using std::max;\n#define OUTPUT 1\n#define LOW 0\n#define PROGMEM\ninline void pinMode(int, int) {}\ninline void digitalWrite(int, int) {}\n'
    (fakes / 'Arduino.h').write_text(arduino)
    task = (fakes / 'freertos/task.h').read_text()
    task = task.replace('inline BaseType_t xTaskCreatePinnedToCore', 'extern BaseType_t g_fakeTaskCreateResult;\ninline BaseType_t xTaskCreatePinnedToCore')
    task = task.replace('if (h) *h = nullptr; return pdPASS;', 'if (h) *h = g_fakeTaskCreateResult == pdPASS ? reinterpret_cast<TaskHandle_t>(1) : nullptr; return g_fakeTaskCreateResult;')
    (fakes / 'freertos/task.h').write_text(task)
    aj = FW / '.pio/libdeps/esp32s3-rmt-dma/ArduinoJson/src'
    common = ['c++', '-std=c++17', '-g', '-O0', '-Wall', '-Wextra', '-Werror',
              '-fsanitize=address,undefined', '-fno-sanitize-recover=undefined',
              '-fno-omit-frame-pointer', '-DARDUINOJSON_ENABLE_ARDUINO_STRING=1',
              '-I' + str(fakes), '-I' + str(FW / 'src'), '-I' + str(aj),
              '-I' + str(sandbox)]
    sources = [FW / 'src' / (name + '.cpp') for name in
               ('state', 'utils', 'scroll_session', 'led_renderer', 'storage',
                'faces', 'config', 'button_animations', 'wifi_manager', 'web_setup')]
    sources += [fakes / 'fake_platform.cpp',
                Path(os.environ.get('RINA_AUDIT_CASE_SOURCE', HERE / 'audit_repairs_cases.cpp'))]
    objects = [sandbox / (str(i) + '.o') for i in range(len(sources))]
    def compile_one(pair):
        source, obj = pair
        subprocess.run(common + ['-c', str(source), '-o', str(obj)], check=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(compile_one, zip(sources, objects)))
    binary = sandbox / 'audit_repairs'
    subprocess.run(common + [str(obj) for obj in objects] + ['-o', str(binary)], check=True)
    cases = sys.argv[1:] or ['battery', 'group_end', 'group_loop',
                            'scroll_phase', 'scroll_end_stall', 'scroll_pause_phase', 'scroll_clock_wrap', 'ap_validation',
                            'ap_failure', 'ap_initial_failure', 'scan_visibility', 'scan_restore',
                            'clear_home', 'clear_hotspot', 'clear_pending', 'clear_ap', 'clear_off', 'clear_ap_retained',
                            'face_identity', 'render_fallback', 'registry_teardown',
                            'presentation_retry', 'hint_priority', 'wifi_reply_home',
                            'wifi_reply_hotspot', 'wifi_reply_mode', 'wifi_reply_replace']
    failed = []
    for case in cases:
        result = subprocess.run([str(binary), case, str(sandbox / ('fs-' + case))])
        if result.returncode:
            failed.append(case)
    if failed:
        raise SystemExit('FAIL: ' + ', '.join(failed))
