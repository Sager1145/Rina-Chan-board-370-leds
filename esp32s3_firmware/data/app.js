"use strict";

/*
 * RinaChanBoard WebUI runtime.
 *
 * This file is intentionally written for a single browser runtime: ESP32 serves it directly as a static resource,
 * The page does not use a bundler. The following code blocks are arranged in dependency order:
 *
 * 1. WEBUI_CONFIG: All adjustable constants. Before changing the running logic, you should modify it here first.
 * The following constants are aliases for these values.
 * 2. EXPRESSION_PARTS and color presets: static data for use, storage, and
 * parts combination and firmware payload generation use.
 * 3. Runtime aliases, matrix geometry and global state: bridge static data into fast lookup tables
 * and mutable UI/firmware state.
 * 4. Sharing tools, API clients and queue: Before any page-specific controls are initialized,
 * Common underlying logic used in every functional page.
 * 5. Function modules: navigation, navigation, editing, color/brightness,
 * Save face, parts combination, text scroll, and debug control.
 * 6. bootstrapWebUi(): Connect all the previous code blocks and perform the first firmware synchronization.
 * Then reveal the UI.
 *
 * index.html is responsible for tags and element ids, styles.css is responsible for layout and visual state,
 * This document is responsible for the conduct. The id/class referenced here should exist in index.html.
 * And there are corresponding styles in styles.css.
 */
const WEBUI_CONFIG = Object.freeze({
  // Save the persistence of face. The UI reads this JSON from LittleFS, edits it in memory,
  // and can be written back via the firmware API or local file tools.
  faces: {
    resourcePath: "/resources/saved_faces.json",
    localFilename: "saved_faces.json",
    schemaFormat: "rina_packed_faces_370_v2",
    startupFaceId: "face_08_triangle_eyes_frown",
  },
  // Device connection defaults: displayed in the debug/status UI and opened directly on the page
  // (rather than via ESP32's captive portal).
  device: {
    apSsid: "RinaChanBoard-V2",
    apPassword: "rinachan",
    apDomain: "rina.io",
    defaultApIp: "192.168.1.14",
  },
  // Navigation metadata. Each tuple maps a logical page id to a visible chapter number and tag;
  // initNav() will generate the top menu button accordingly.
  navigation: {
    pages: [
      ["basic", "6.1", "基础功能"],
      ["custom", "6.2", "自定义表情"],
      ["parts", "6.3", "表情部件"],
      ["scroll", "6.4", "文字滚动"],
      ["debug", "6.5", "调试"],
    ],
  },
  // LED hardware limitations and LED size. Renderers, brightness controls, and power estimates
  // are derived from this block.
  led: {
    defaultColor: "#ec3fc7",
    defaultBrightness: 50,
    minBrightness: 10,
    maxBrightness: 200,
    estimatedWattsPerChannel: 0.06,
    channelCount: 5,
    fullBrightness: 255,
    powerWarningWatts: 40,
    previewSize: {
      defaultCell: 18,
      minCell: 5,
      maxCell: 62,
      minWidth: 320,
      maxHeight: 650,
      edgeGap: 12,
    },
  },
  // face The time parameter of automatic rotation. Both UI presets and firmware command payloads use these upper and lower bounds.
  // Keep browser and device behavior consistent.
  autoInterval: {
    minMs: 500,
    maxMs: 10000,
    buttonStepMs: 500,
    presetsMs: [500, 1000, 2000, 3000, 5000, 7500, 10000],
  },
  // HTTP endpoints and timeouts. The following API helper functions will add host/origin,
  // And convert failures into log/status fields.
  api: {
    getTimeoutMs: 2500,
    postTimeoutMs: 5000,
    uploadTimeoutMs: 15000,
    bootStatusTimeoutMs: 2500,
    runtimeStatusQuery: "?runtimeOnly=1&noFrame=1",
    endpoints: {
      frame: "/api/frame",
      currentFrame: "/api/frame/current",
      command: "/api/command",
      scroll: "/api/scroll",
      scrollMeta: "/api/scroll/meta",
      savedFaces: "/api/saved_faces",
      power: "/api/power",
      status: "/api/status",
    },
  },
  // Shared reactive breakpoints. Visual rules are taken care of by CSS; JS only needs to make layout judgments on the script side.
  // Only use these values.
  layout: {
    oneColumnMaxPx: 980,
    threeColumnsMinPx: 1471,
  },
  // Timing of firmware writing to queue. These values are used to protect single-threaded ESP32 web servers,
  // Avoid getting overwhelmed by fast browser events like dragging sliders.
  firmwareQueues: {
    frameSendIntervalMs: 20,
    frameQueueMax: 6,
    buttonCommandIntervalMs: 120,
    buttonCommandQueueMax: 4,
    scrollButtonStopFullSyncDelayMs: 140,
  },
  // Runtime limitations of text scroll.preview, upload chunks and firmware scroll playback
  // All are read from this block.
  scroll: {
    defaultFps: 10,
    fpsMin: 1,
    fpsMax: 60,
    fpsPresets: [1, 10, 20, 30, 40, 50, 60],
    firmwareMaxFramesDefault: 3072,
    uploadChunkFrames: 24,
    maxTextChars: 1000,
  },
  // 6.4 Page browser and firmware bitmap settings. This JSON table is large, so it is loaded lazily;
  // The CSS font face is declared in styles.css.
  textScroll: {
    fontModel: "ark_pixel_12px_fusion_bitmap_v4",
    // The "?v=dev" token is rewritten to a content hash at build time by
    // scripts/gzip_webui_assets.py (app.js is in REWRITE_TARGETS). This lets the
    // browser cache the ~2.5MB bitmap table immutably (firmware serves it with
    // Cache-Control: immutable) while still busting the cache whenever the font
    // bytes change. The fetch in ensureArkPixelFontReady() therefore must NOT use
    // cache:"no-store" -- doing so would re-stream the whole table out of LittleFS
    // on every refresh/page-entry and freeze the WebUI during text scroll.
    fontResource: "/resources/fonts/ark12.json?v=dev",
    fontFamily: "Ark Pixel 12px Monospaced",
    fontFallbackFamily: "",
    browserFontSample:
      "RinaChanBoard 370 LED \u7ee7\u7eed \u6682\u505c \u3053\u3093\u306b\u3061\u306f \u7483\u5948\u3061\u3083\u3093\u30dc\u30fc\u30c9 \u7136\u71c3\u6eda\u6efe \ud83c\udfe0\ufe0e\ud83d\ude00\ufe0e",
    browserFallbackFontSample: "",
    charSpacing: 0,
    spaceColumns: 6,
    missingGlyphCodePoint: 0x25a1,
  },
  // The UI font family that the loader expects to use. The real embedded data URI is located in styles.css,
  // And will be waited for loading to complete before the first screen is revealed.
  fonts: {
    uiFamily: "GNU Unifont",
  },
  // Interaction timing and keyboard routing used by shared controls.
  interaction: {
    buttonPressDownMs: 90,
    buttonPressUpMs: 150,
    selectMenuHideDelayMs: 260,
    pageScrollKeys: [
      "ArrowUp",
      "ArrowDown",
      "ArrowLeft",
      "ArrowRight",
      "PageUp",
      "PageDown",
      "Home",
      "End",
      " ",
    ],
  },
  // Arrangement parameters of bootloader. bootstrapWebUi() while loading mask is still visible
  // Use these values to synchronize firmware status.
  boot: {
    loadingIconBefore: "./resources/loading/rina_icon1_default.png",
    loadingIconAfter: "./resources/loading/rina_icon2_hover.png",
    holdMs: 260,
    haloBreathMs: 1620,
    haloPeakRatio: 0.5,
    haloToleranceMs: 24,
    haloContractMs: 520,
    imageReleaseMs: 2100,
    blurDurationMs: 850,
    extraMs: 180,
    minDisplayMs: 400,
    firstPageRevealSelector: [
      "#page-basic .basic-preview-card",
      // 6.1 的控制卡片（亮度控制 / 自动表情切换间隔 / A-M 模式 / 颜色控制）现在位于
      // .face-manager-stack 内（旧的 .control-panel 结构已不存在），逐个纳入瀑布揭示。
      "#page-basic .face-manager-stack > .card",
    ],
  },
  // The refresh rhythm of the power panel. The poller refreshes at this interval after applying the first state snapshot.
  power: {
    statusRefreshMs: 900,
  },
});
// Data: Expression/part library
// Connection relationship:
// - initParts() uses call.ids and parts to generate 6.3 parts buttons.
// - composePartsFrame() superimposes the selected parts into partsFrame.
// - queueFirmwareFrame() sends the final 370 LED frame (as a 47-byte packed frame) to the firmware.
// - The saved-face logic will merge these static expressions and user-saved expressions into one library.
// This block only holds static data, does not read or write the DOM, and does not directly send APIs.
// Embedded LED expression/widget library for preview and firmware payload.
const EXPRESSION_PARTS = {
  format: "rina_expression_parts_370_runtime_v4",
  version: 4,
  matrix: {
    cols: 22,
    rows: 18,
    num_leds: 370,
    row_lengths: [18, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 22, 20, 20, 20, 18, 16],
    row_valid_x_ranges: [
      [2, 19],
      [1, 20],
      [1, 20],
      [1, 20],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [0, 21],
      [1, 20],
      [1, 20],
      [1, 20],
      [2, 19],
      [3, 18],
    ],
    serpentine: true,
    serpentine_odd_rows_reversed: true,
  },
  encoding: {
    row_hex: "local bitmap rows; bit7 is local x=0; use only size[0] bits",
    frame: "94 hex chars; 47 bytes packed LSB-first (LED i in byte i>>3, mask 1<<(i&7)); the theoretical minimum 370-LED frame",
    strip_indices:
      "physical serpentine LED indices mapped back to logical packed-frame cells when used as fallback",
  },
  layout: {
    eye_left: [
      {
        x: 2,
        y: 1,
        w: 8,
        h: 8,
        mirror_x: false,
        role: "left_eye",
      },
    ],
    eye_right: [
      {
        x: 12,
        y: 1,
        w: 8,
        h: 8,
        mirror_x: false,
        role: "right_eye",
      },
    ],
    mouth: [
      {
        x: 7,
        y: 9,
        w: 8,
        h: 8,
        mirror_x: false,
        role: "mouth",
      },
    ],
    cheek: [
      {
        x: 2,
        y: 9,
        w: 4,
        h: 4,
        mirror_x: true,
        role: "left_cheek",
      },
      {
        x: 16,
        y: 9,
        w: 4,
        h: 4,
        mirror_x: false,
        role: "right_cheek",
      },
    ],
  },
  call: {
    fields: {
      leye: "left eye ID",
      reye: "right eye ID",
      mouth: "mouth ID",
      cheek: "cheek ID",
    },
    default_face: {
      leye: 101,
      reye: 201,
      mouth: 301,
      cheek: 400,
    },
    ids: {
      leye: [
        "0",
        "101",
        "102",
        "103",
        "104",
        "105",
        "106",
        "107",
        "108",
        "109",
        "110",
        "111",
        "112",
        "113",
        "114",
        "115",
        "116",
        "117",
        "118",
        "119",
        "120",
        "121",
        "122",
        "123",
        "124",
        "125",
        "126",
        "127",
      ],
      reye: [
        "0",
        "201",
        "202",
        "203",
        "204",
        "205",
        "206",
        "207",
        "208",
        "209",
        "210",
        "211",
        "212",
        "213",
        "214",
        "215",
        "216",
        "217",
        "218",
        "219",
        "220",
        "221",
        "222",
        "223",
        "224",
        "225",
        "226",
        "227",
      ],
      mouth: [
        "0",
        "301",
        "302",
        "303",
        "304",
        "305",
        "306",
        "307",
        "308",
        "309",
        "310",
        "311",
        "312",
        "313",
        "314",
        "315",
        "316",
        "317",
        "318",
        "319",
        "320",
        "321",
        "322",
        "323",
        "324",
        "325",
        "326",
        "327",
        "328",
        "329",
        "330",
        "331",
        "332",
      ],
      cheek: ["400", "401", "402", "403", "404", "405"],
    },
    map: {
      leye: {
        0: "0",
        101: "101",
        102: "102",
        103: "103",
        104: "104",
        105: "105",
        106: "106",
        107: "107",
        108: "108",
        109: "109",
        110: "110",
        111: "111",
        112: "112",
        113: "113",
        114: "114",
        115: "115",
        116: "116",
        117: "117",
        118: "118",
        119: "119",
        120: "120",
        121: "121",
        122: "122",
        123: "123",
        124: "124",
        125: "125",
        126: "126",
        127: "127",
      },
      reye: {
        0: "0",
        201: "201",
        202: "202",
        203: "203",
        204: "204",
        205: "205",
        206: "206",
        207: "207",
        208: "208",
        209: "209",
        210: "210",
        211: "211",
        212: "212",
        213: "213",
        214: "214",
        215: "215",
        216: "216",
        217: "217",
        218: "218",
        219: "219",
        220: "220",
        221: "221",
        222: "222",
        223: "223",
        224: "224",
        225: "225",
        226: "226",
        227: "227",
      },
      mouth: {
        0: "0",
        301: "301",
        302: "302",
        303: "303",
        304: "304",
        305: "305",
        306: "306",
        307: "307",
        308: "308",
        309: "309",
        310: "310",
        311: "311",
        312: "312",
        313: "313",
        314: "314",
        315: "315",
        316: "316",
        317: "317",
        318: "318",
        319: "319",
        320: "320",
        321: "321",
        322: "322",
        323: "323",
        324: "324",
        325: "325",
        326: "326",
        327: "327",
        328: "328",
        329: "329",
        330: "330",
        331: "331",
        332: "332",
      },
      cheek: {
        400: "0",
        401: "401",
        402: "402",
        403: "403",
        404: "404",
        405: "405",
        0: "0",
      },
    },
    compose:
      "Resolve call IDs through call.map, OR selected parts by frame or strip_indices, then apply selected color and global brightness.",
  },
  groups: {
    empty: ["0"],
    eye_left: [
      "101",
      "102",
      "103",
      "104",
      "105",
      "106",
      "107",
      "108",
      "109",
      "110",
      "111",
      "112",
      "113",
      "114",
      "115",
      "116",
      "117",
      "118",
      "119",
      "120",
      "121",
      "122",
      "123",
      "124",
      "125",
      "126",
      "127",
    ],
    eye_right: [
      "201",
      "202",
      "203",
      "204",
      "205",
      "206",
      "207",
      "208",
      "209",
      "210",
      "211",
      "212",
      "213",
      "214",
      "215",
      "216",
      "217",
      "218",
      "219",
      "220",
      "221",
      "222",
      "223",
      "224",
      "225",
      "226",
      "227",
    ],
    mouth: [
      "301",
      "302",
      "303",
      "304",
      "305",
      "306",
      "307",
      "308",
      "309",
      "310",
      "311",
      "312",
      "313",
      "314",
      "315",
      "316",
      "317",
      "318",
      "319",
      "320",
      "321",
      "322",
      "323",
      "324",
      "325",
      "326",
      "327",
      "328",
      "329",
      "330",
      "331",
      "332",
    ],
    cheek: ["401", "402", "403", "404", "405"],
  },
  counts: {
    stored_unique_parts: 92,
    callable_ids: 93,
    stored_by_group: {
      empty: 1,
      eye_left: 27,
      eye_right: 27,
      mouth: 32,
      cheek: 5,
    },
    callable_by_group: {
      empty: 1,
      eye_left: 27,
      eye_right: 27,
      mouth: 32,
      cheek: 6,
    },
    deduped_call_ids: ["400"],
  },
  parts: {
    0: {
      id: 0,
      name: "empty_000",
      type: "empty",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "00", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        "........",
        "........",
        "........",
      ],
      placement: [],
      frame: "0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [],
      lit_count: 0,
      bbox: null,
    },
    101: {
      id: 101,
      name: "left_eye_101",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "30", "30", "30", "30", "00"],
      preview: [
        "........",
        "........",
        "........",
        "..##....",
        "..##....",
        "..##....",
        "..##....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000C00000300C000003000000000000000000000000000000000000000000000000000000000",
      strip_indices: [82, 83, 116, 117, 126, 127, 160, 161],
      lit_count: 8,
      bbox: [4, 4, 5, 7],
    },
    102: {
      id: 102,
      name: "left_eye_102",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "40", "30", "30", "30", "30", "00"],
      preview: [
        "........",
        "........",
        ".#......",
        "..##....",
        "..##....",
        "..##....",
        "..##....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000001000000C00000300C000003000000000000000000000000000000000000000000000000000000000",
      strip_indices: [75, 82, 83, 116, 117, 126, 127, 160, 161],
      lit_count: 9,
      bbox: [3, 3, 5, 7],
    },
    103: {
      id: 103,
      name: "left_eye_103",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "10", "28", "44", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "...#....",
        "..#.#...",
        ".#...#..",
        "........",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000008000005002002000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [83, 115, 117, 125, 129],
      lit_count: 5,
      bbox: [3, 4, 7, 6],
    },
    104: {
      id: 104,
      name: "left_eye_104",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "18", "24", "42", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "...##...",
        "..#..#..",
        ".#....#.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000018000009002004000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [83, 84, 114, 117, 125, 130],
      lit_count: 6,
      bbox: [3, 4, 8, 6],
    },
    105: {
      id: 105,
      name: "left_eye_105",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "10", "28", "44", "82", "00", "00"],
      preview: [
        "........",
        "........",
        "...#....",
        "..#.#...",
        ".#...#..",
        "#.....#.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000040000014008008001004000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [73, 82, 84, 114, 118, 124, 130],
      lit_count: 7,
      bbox: [2, 3, 8, 6],
    },
    106: {
      id: 106,
      name: "left_eye_106",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "60", "18", "04", "18", "60", "00"],
      preview: [
        "........",
        "........",
        ".##.....",
        "...##...",
        ".....#..",
        "...##...",
        ".##.....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000030000018000008008001001800000000000000000000000000000000000000000000000000000000",
      strip_indices: [74, 75, 83, 84, 114, 127, 128, 161, 162],
      lit_count: 9,
      bbox: [3, 3, 7, 7],
    },
    107: {
      id: 107,
      name: "left_eye_107",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "60", "18", "04", "78", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".##.....",
        "...##...",
        ".....#..",
        ".####...",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000006000006000002007800000000000000000000000000000000000000000000000000000000",
      strip_indices: [81, 82, 115, 116, 129, 159, 160, 161, 162],
      lit_count: 9,
      bbox: [3, 4, 7, 7],
    },
    108: {
      id: 108,
      name: "left_eye_108",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "7E", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        ".######.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000000000000E007000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [125, 126, 127, 128, 129, 130],
      lit_count: 6,
      bbox: [3, 6, 8, 6],
    },
    109: {
      id: 109,
      name: "left_eye_109",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "7E", "A0", "40"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        ".######.",
        "#.#.....",
        ".#......",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000000000000E007001400000200000000000000000000000000000000000000000000000000",
      strip_indices: [125, 126, 127, 128, 129, 130, 161, 163, 169],
      lit_count: 9,
      bbox: [2, 6, 8, 8],
    },
    110: {
      id: 110,
      name: "left_eye_110",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "40", "3C", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        ".#......",
        "..####..",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000000000000200000F000000000000000000000000000000000000000000000000000000000",
      strip_indices: [125, 158, 159, 160, 161],
      lit_count: 5,
      bbox: [3, 6, 7, 7],
    },
    111: {
      id: 111,
      name: "left_eye_111",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "44", "38", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        ".#...#..",
        "..###...",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000002002007000000000000000000000000000000000000000000000000000000000",
      strip_indices: [125, 129, 159, 160, 161],
      lit_count: 5,
      bbox: [3, 6, 7, 7],
    },
    112: {
      id: 112,
      name: "left_eye_112",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "42", "24", "18", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".#....#.",
        "..#..#..",
        "...##...",
        "........",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000042000009008001000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [81, 86, 114, 117, 127, 128],
      lit_count: 6,
      bbox: [3, 4, 8, 6],
    },
    113: {
      id: 113,
      name: "left_eye_113",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "60", "1E", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        ".##.....",
        "...####.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000008001008007000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [117, 118, 127, 128, 129, 130],
      lit_count: 6,
      bbox: [3, 5, 8, 6],
    },
    114: {
      id: 114,
      name: "left_eye_114",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "70", "0C", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        ".###....",
        "....##..",
        "........",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000008003000003000000000000000000000000000000000000000000000000000000000000",
      strip_indices: [116, 117, 118, 128, 129],
      lit_count: 5,
      bbox: [3, 5, 7, 6],
    },
    115: {
      id: 115,
      name: "left_eye_115",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "60", "10", "0C", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        ".##.....",
        "...#....",
        "....##..",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000000800100800000C000000000000000000000000000000000000000000000000000000000",
      strip_indices: [117, 118, 127, 158, 159],
      lit_count: 5,
      bbox: [3, 5, 7, 7],
    },
    116: {
      id: 116,
      name: "left_eye_116",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "30", "3C", "18", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "..##....",
        "..####..",
        "...##...",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000000000300C003006000000000000000000000000000000000000000000000000000000000",
      strip_indices: [116, 117, 126, 127, 128, 129, 159, 160],
      lit_count: 8,
      bbox: [4, 5, 7, 7],
    },
    117: {
      id: 117,
      name: "left_eye_117",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "08", "10", "70", "30", "30", "00"],
      preview: [
        "........",
        "........",
        "....#...",
        "...#....",
        ".###....",
        "..##....",
        "..##....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000008000000800800300C000003000000000000000000000000000000000000000000000000000000000",
      strip_indices: [72, 83, 116, 117, 118, 126, 127, 160, 161],
      lit_count: 9,
      bbox: [3, 3, 6, 7],
    },
    118: {
      id: 118,
      name: "left_eye_118",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "40", "20", "38", "30", "30", "00"],
      preview: [
        "........",
        "........",
        ".#......",
        "..#.....",
        "..###...",
        "..##....",
        "..##....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000001000000400000700C000003000000000000000000000000000000000000000000000000000000000",
      strip_indices: [75, 82, 115, 116, 117, 126, 127, 160, 161],
      lit_count: 9,
      bbox: [3, 3, 6, 7],
    },
    119: {
      id: 119,
      name: "left_eye_119",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "30", "68", "78", "30", "00"],
      preview: [
        "........",
        "........",
        "........",
        "..##....",
        ".##.#...",
        ".####...",
        "..##....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000C00800500E001003000000000000000000000000000000000000000000000000000000000",
      strip_indices: [82, 83, 115, 117, 118, 125, 126, 127, 128, 160, 161],
      lit_count: 11,
      bbox: [3, 4, 6, 7],
    },
    120: {
      id: 120,
      name: "left_eye_120",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "30", "68", "78", "B0", "40"],
      preview: [
        "........",
        "........",
        "........",
        "..##....",
        ".##.#...",
        ".####...",
        "#.##....",
        ".#......",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000C00800500E001003400000200000000000000000000000000000000000000000000000000",
      strip_indices: [82, 83, 115, 117, 118, 125, 126, 127, 128, 160, 161, 163, 169],
      lit_count: 13,
      bbox: [2, 4, 6, 8],
    },
    121: {
      id: 121,
      name: "left_eye_121",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "00", "30", "70", "78", "30", "00"],
      preview: [
        "........",
        "........",
        "........",
        "..##....",
        ".###....",
        ".####...",
        "..##....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000C00800300E001003000000000000000000000000000000000000000000000000000000000",
      strip_indices: [82, 83, 116, 117, 118, 125, 126, 127, 128, 160, 161],
      lit_count: 11,
      bbox: [3, 4, 6, 7],
    },
    122: {
      id: 122,
      name: "left_eye_122",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "38", "44", "08", "10", "00", "10"],
      preview: [
        "........",
        "........",
        "..###...",
        ".#...#..",
        "....#...",
        "...#....",
        "........",
        "...#....",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000E0000022000004008000000000000800000000000000000000000000000000000000000000000000",
      strip_indices: [72, 73, 74, 81, 85, 115, 127, 171],
      lit_count: 8,
      bbox: [3, 3, 7, 8],
    },
    123: {
      id: 123,
      name: "left_eye_123",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "44", "28", "10", "28", "44", "00"],
      preview: [
        "........",
        "........",
        ".#...#..",
        "..#.#...",
        "...#....",
        "..#.#...",
        ".#...#..",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000010010014000002004001008800000000000000000000000000000000000000000000000000000000",
      strip_indices: [71, 75, 82, 84, 116, 126, 128, 158, 162],
      lit_count: 9,
      bbox: [3, 3, 7, 7],
    },
    124: {
      id: 124,
      name: "left_eye_124",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "10", "38", "7C", "38", "10", "00"],
      preview: [
        "........",
        "........",
        "...#....",
        "..###...",
        ".#####..",
        "..###...",
        "...#....",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "000000000000004000001C00800F00C001002000000000000000000000000000000000000000000000000000000000",
      strip_indices: [73, 82, 83, 84, 114, 115, 116, 117, 118, 126, 127, 128, 160],
      lit_count: 13,
      bbox: [3, 3, 7, 7],
    },
    125: {
      id: 125,
      name: "left_eye_125",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "38", "44", "44", "44", "38", "00"],
      preview: [
        "........",
        "........",
        "..###...",
        ".#...#..",
        ".#...#..",
        ".#...#..",
        "..###...",
        "........",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000E0000022008008002002007000000000000000000000000000000000000000000000000000000000",
      strip_indices: [72, 73, 74, 81, 85, 114, 118, 125, 129, 159, 160, 161],
      lit_count: 12,
      bbox: [3, 3, 7, 7],
    },
    126: {
      id: 126,
      name: "left_eye_126",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "10", "28", "44", "82", "44", "28", "10"],
      preview: [
        "........",
        "...#....",
        "..#.#...",
        ".#...#..",
        "#.....#.",
        ".#...#..",
        "..#.#...",
        "...#....",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000400A0000022004010002002005000000800000000000000000000000000000000000000000000000000",
      strip_indices: [42, 72, 74, 81, 85, 113, 119, 125, 129, 159, 161, 171],
      lit_count: 12,
      bbox: [2, 2, 8, 8],
    },
    127: {
      id: 127,
      name: "left_eye_127",
      type: "eye_left",
      size: [8, 8],
      row_hex: ["00", "00", "6C", "92", "82", "44", "28", "10"],
      preview: [
        "........",
        "........",
        ".##.##..",
        "#..#..#.",
        "#.....#.",
        ".#...#..",
        "..#.#...",
        "...#....",
      ],
      placement: [
        {
          x: 2,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000B0010049004010002002005000000800000000000000000000000000000000000000000000000000",
      strip_indices: [71, 72, 74, 75, 80, 83, 86, 113, 119, 125, 129, 159, 161, 171],
      lit_count: 14,
      bbox: [2, 3, 8, 8],
    },
    201: {
      id: 201,
      name: "right_eye_201",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "0C", "0C", "0C", "0C", "00"],
      preview: [
        "........",
        "........",
        "........",
        "....##..",
        "....##..",
        "....##..",
        "....##..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000C000003000000C0000030000000000000000000000000000000000000000000000000000",
      strip_indices: [94, 95, 104, 105, 138, 139, 148, 149],
      lit_count: 8,
      bbox: [16, 4, 17, 7],
    },
    202: {
      id: 202,
      name: "right_eye_202",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "02", "0C", "0C", "0C", "0C", "00"],
      preview: [
        "........",
        "........",
        "......#.",
        "....##..",
        "....##..",
        "....##..",
        "....##..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000800C000003000000C0000030000000000000000000000000000000000000000000000000000",
      strip_indices: [60, 94, 95, 104, 105, 138, 139, 148, 149],
      lit_count: 9,
      bbox: [16, 3, 18, 7],
    },
    203: {
      id: 203,
      name: "right_eye_203",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "08", "14", "22", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "....#...",
        "...#.#..",
        "..#...#.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000400000280000110000000000000000000000000000000000000000000000000000000000",
      strip_indices: [94, 104, 106, 136, 140],
      lit_count: 5,
      bbox: [14, 4, 18, 6],
    },
    204: {
      id: 204,
      name: "right_eye_204",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "18", "24", "42", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "...##...",
        "..#..#..",
        ".#....#.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000600000240080100000000000000000000000000000000000000000000000000000000000",
      strip_indices: [93, 94, 104, 107, 135, 140],
      lit_count: 6,
      bbox: [13, 4, 18, 6],
    },
    205: {
      id: 205,
      name: "right_eye_205",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "08", "14", "22", "41", "00", "00"],
      preview: [
        "........",
        "........",
        "....#...",
        "...#.#..",
        "..#...#.",
        ".#.....#",
        "........",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000200A00000440080200000000000000000000000000000000000000000000000000000000000",
      strip_indices: [62, 93, 95, 103, 107, 135, 141],
      lit_count: 7,
      bbox: [13, 3, 19, 6],
    },
    206: {
      id: 206,
      name: "right_eye_206",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "06", "18", "20", "18", "06", "00"],
      preview: [
        "........",
        "........",
        ".....##.",
        "...##...",
        "..#.....",
        "...##...",
        ".....##.",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000C00600000040000060000060000000000000000000000000000000000000000000000000000",
      strip_indices: [60, 61, 93, 94, 107, 137, 138, 147, 148],
      lit_count: 9,
      bbox: [14, 3, 18, 7],
    },
    207: {
      id: 207,
      name: "right_eye_207",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "06", "18", "20", "1E", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".....##.",
        "...##...",
        "..#.....",
        "...####.",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000800100180000010080070000000000000000000000000000000000000000000000000000",
      strip_indices: [95, 96, 105, 106, 136, 147, 148, 149, 150],
      lit_count: 9,
      bbox: [14, 4, 18, 7],
    },
    208: {
      id: 208,
      name: "right_eye_208",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "7E", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        ".######.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000801F0000000000000000000000000000000000000000000000000000000000",
      strip_indices: [135, 136, 137, 138, 139, 140],
      lit_count: 6,
      bbox: [13, 6, 18, 6],
    },
    209: {
      id: 209,
      name: "right_eye_209",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "7E", "05", "02"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        ".######.",
        ".....#.#",
        "......#.",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000801F00000A0000010000000000000000000000000000000000000000000000",
      strip_indices: [135, 136, 137, 138, 139, 140, 146, 148, 184],
      lit_count: 9,
      bbox: [13, 6, 19, 8],
    },
    210: {
      id: 210,
      name: "right_eye_210",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "02", "3C", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        "......#.",
        "..####..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000001000C0030000000000000000000000000000000000000000000000000000",
      strip_indices: [140, 148, 149, 150, 151],
      lit_count: 5,
      bbox: [14, 6, 18, 7],
    },
    211: {
      id: 211,
      name: "right_eye_211",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "00", "22", "1C", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "........",
        "..#...#.",
        "...###..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000110080030000000000000000000000000000000000000000000000000000",
      strip_indices: [136, 140, 148, 149, 150],
      lit_count: 5,
      bbox: [14, 6, 18, 7],
    },
    212: {
      id: 212,
      name: "right_eye_212",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "42", "24", "18", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".#....#.",
        "..#..#..",
        "...##...",
        "........",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000080100240000060000000000000000000000000000000000000000000000000000000000",
      strip_indices: [91, 96, 104, 107, 137, 138],
      lit_count: 6,
      bbox: [13, 4, 18, 6],
    },
    213: {
      id: 213,
      name: "right_eye_213",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "06", "78", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        ".....##.",
        ".####...",
        "........",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000600080070000000000000000000000000000000000000000000000000000000000",
      strip_indices: [103, 104, 135, 136, 137, 138],
      lit_count: 6,
      bbox: [13, 5, 18, 6],
    },
    214: {
      id: 214,
      name: "right_eye_214",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "0E", "30", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "....###.",
        "..##....",
        "........",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000700000030000000000000000000000000000000000000000000000000000000000",
      strip_indices: [103, 104, 105, 136, 137],
      lit_count: 5,
      bbox: [14, 5, 18, 6],
    },
    215: {
      id: 215,
      name: "right_eye_215",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "06", "08", "30", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        ".....##.",
        "....#...",
        "..##....",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000006000000400C0000000000000000000000000000000000000000000000000000000",
      strip_indices: [103, 104, 138, 150, 151],
      lit_count: 5,
      bbox: [14, 5, 18, 7],
    },
    216: {
      id: 216,
      name: "right_eye_216",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "0C", "3C", "18", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        "....##..",
        "..####..",
        "...##...",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000003000000F0080010000000000000000000000000000000000000000000000000000",
      strip_indices: [104, 105, 136, 137, 138, 139, 149, 150],
      lit_count: 8,
      bbox: [14, 5, 17, 7],
    },
    217: {
      id: 217,
      name: "right_eye_217",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "10", "08", "0E", "0C", "0C", "00"],
      preview: [
        "........",
        "........",
        "...#....",
        "....#...",
        "....###.",
        "....##..",
        "....##..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000001004000007000000C0000030000000000000000000000000000000000000000000000000000",
      strip_indices: [63, 94, 103, 104, 105, 138, 139, 148, 149],
      lit_count: 9,
      bbox: [15, 3, 18, 7],
    },
    218: {
      id: 218,
      name: "right_eye_218",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "02", "04", "1C", "0C", "0C", "00"],
      preview: [
        "........",
        "........",
        "......#.",
        ".....#..",
        "...###..",
        "....##..",
        "....##..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000008008000003800000C0000030000000000000000000000000000000000000000000000000000",
      strip_indices: [60, 95, 104, 105, 106, 138, 139, 148, 149],
      lit_count: 9,
      bbox: [15, 3, 18, 7],
    },
    219: {
      id: 219,
      name: "right_eye_219",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "0C", "16", "1E", "0C", "00"],
      preview: [
        "........",
        "........",
        "........",
        "....##..",
        "...#.##.",
        "...####.",
        "....##..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000C000006800001E0000030000000000000000000000000000000000000000000000000000",
      strip_indices: [94, 95, 103, 104, 106, 137, 138, 139, 140, 148, 149],
      lit_count: 11,
      bbox: [15, 4, 18, 7],
    },
    220: {
      id: 220,
      name: "right_eye_220",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "0C", "16", "1E", "0D", "02"],
      preview: [
        "........",
        "........",
        "........",
        "....##..",
        "...#.##.",
        "...####.",
        "....##.#",
        "......#.",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000C000006800001E00000B0000010000000000000000000000000000000000000000000000",
      strip_indices: [94, 95, 103, 104, 106, 137, 138, 139, 140, 146, 148, 149, 184],
      lit_count: 13,
      bbox: [15, 4, 19, 8],
    },
    221: {
      id: 221,
      name: "right_eye_221",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "00", "0C", "0E", "1E", "0C", "00"],
      preview: [
        "........",
        "........",
        "........",
        "....##..",
        "....###.",
        "...####.",
        "....##..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000C000007000001E0000030000000000000000000000000000000000000000000000000000",
      strip_indices: [94, 95, 103, 104, 105, 137, 138, 139, 140, 148, 149],
      lit_count: 11,
      bbox: [15, 4, 18, 7],
    },
    222: {
      id: 222,
      name: "right_eye_222",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "08", "08", "08", "08", "00", "08"],
      preview: [
        "........",
        "........",
        "....#...",
        "....#...",
        "....#...",
        "....#...",
        "........",
        "....#...",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000200400000100000040000000040000000000000000000000000000000000000000000000000",
      strip_indices: [62, 94, 105, 138, 182],
      lit_count: 5,
      bbox: [16, 3, 16, 8],
    },
    223: {
      id: 223,
      name: "right_eye_223",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "22", "14", "08", "14", "22", "00"],
      preview: [
        "........",
        "........",
        "..#...#.",
        "...#.#..",
        "....#...",
        "...#.#..",
        "..#...#.",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000800800A000001000000A0040040000000000000000000000000000000000000000000000000000",
      strip_indices: [60, 64, 93, 95, 105, 137, 139, 147, 151],
      lit_count: 9,
      bbox: [14, 3, 18, 7],
    },
    224: {
      id: 224,
      name: "right_eye_224",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "08", "1C", "3E", "1C", "08", "00"],
      preview: [
        "........",
        "........",
        "....#...",
        "...###..",
        "..#####.",
        "...###..",
        "....#...",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000200E000007C00000E0000010000000000000000000000000000000000000000000000000000",
      strip_indices: [62, 93, 94, 95, 103, 104, 105, 106, 107, 137, 138, 139, 149],
      lit_count: 13,
      bbox: [14, 3, 18, 7],
    },
    225: {
      id: 225,
      name: "right_eye_225",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "1C", "22", "22", "22", "1C", "00"],
      preview: [
        "........",
        "........",
        "...###..",
        "..#...#.",
        "..#...#.",
        "..#...#.",
        "...###..",
        "........",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000700100100440000110080030000000000000000000000000000000000000000000000000000",
      strip_indices: [61, 62, 63, 92, 96, 103, 107, 136, 140, 148, 149, 150],
      lit_count: 12,
      bbox: [14, 3, 18, 7],
    },
    226: {
      id: 226,
      name: "right_eye_226",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "08", "14", "22", "41", "22", "14", "08"],
      preview: [
        "........",
        "....#...",
        "...#.#..",
        "..#...#.",
        ".#.....#",
        "..#...#.",
        "...#.#..",
        "....#...",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000002000000500100100820000110080020040000000000000000000000000000000000000000000000000",
      strip_indices: [53, 61, 63, 92, 96, 102, 108, 136, 140, 148, 150, 182],
      lit_count: 12,
      bbox: [13, 2, 19, 8],
    },
    227: {
      id: 227,
      name: "right_eye_227",
      type: "eye_right",
      size: [8, 8],
      row_hex: ["00", "00", "36", "49", "41", "22", "14", "08"],
      preview: [
        "........",
        "........",
        "..##.##.",
        ".#..#..#",
        ".#.....#",
        "..#...#.",
        "...#.#..",
        "....#...",
      ],
      placement: [
        {
          x: 12,
          y: 1,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000800D00480200820000110080020040000000000000000000000000000000000000000000000000",
      strip_indices: [60, 61, 63, 64, 91, 94, 97, 102, 108, 136, 140, 148, 150, 182],
      lit_count: 14,
      bbox: [13, 3, 19, 8],
    },
    301: {
      id: 301,
      name: "mouth_301",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "7E", "00", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        ".######.",
        "........",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000000000F80100000000000000000000",
      strip_indices: [283, 284, 285, 286, 287, 288],
      lit_count: 6,
      bbox: [8, 13, 13, 13],
    },
    302: {
      id: 302,
      name: "mouth_302",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "81", "7E", "00", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "#......#",
        ".######.",
        "........",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000201000F80100000000000000000000",
      strip_indices: [261, 268, 283, 284, 285, 286, 287, 288],
      lit_count: 8,
      bbox: [7, 12, 14, 13],
    },
    303: {
      id: 303,
      name: "mouth_303",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "00", "7E", "81", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "........",
        ".######.",
        "#......#",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000000000F80140200000000000000000",
      strip_indices: [283, 284, 285, 286, 287, 288, 302, 309],
      lit_count: 8,
      bbox: [7, 13, 14, 14],
    },
    304: {
      id: 304,
      name: "mouth_304",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "81", "42", "3C", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "#......#",
        ".#....#.",
        "..####..",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000000000000000000000000000000000002010000801000F0000000000000000",
      strip_indices: [261, 268, 283, 288, 304, 305, 306, 307],
      lit_count: 8,
      bbox: [7, 12, 14, 14],
    },
    305: {
      id: 305,
      name: "mouth_305",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "81", "42", "24", "18", "00", "00"],
      preview: [
        "........",
        "........",
        "#......#",
        ".#....#.",
        "..#..#..",
        "...##...",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000804000400800900000060000000000000000",
      strip_indices: [239, 246, 262, 267, 284, 287, 305, 306],
      lit_count: 8,
      bbox: [7, 11, 14, 14],
    },
    306: {
      id: 306,
      name: "mouth_306",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "42", "24", "18", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".#....#.",
        "..#..#..",
        "...##...",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000400800900000060000000000000000",
      strip_indices: [262, 267, 284, 287, 305, 306],
      lit_count: 6,
      bbox: [8, 12, 13, 14],
    },
    307: {
      id: 307,
      name: "mouth_307",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "18", "24", "42", "81", "00", "00"],
      preview: [
        "........",
        "........",
        "...##...",
        "..#..#..",
        ".#....#.",
        "#......#",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000C00800400080140200000000000000000",
      strip_indices: [242, 243, 263, 266, 283, 288, 302, 309],
      lit_count: 8,
      bbox: [7, 11, 14, 14],
    },
    308: {
      id: 308,
      name: "mouth_308",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "18", "24", "42", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "...##...",
        "..#..#..",
        ".#....#.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000000300900080100000000000000000",
      strip_indices: [264, 265, 284, 287, 303, 308],
      lit_count: 6,
      bbox: [8, 12, 13, 14],
    },
    309: {
      id: 309,
      name: "mouth_309",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "02", "85", "46", "3C", "00", "00"],
      preview: [
        "........",
        "........",
        "......#.",
        "#....#.#",
        ".#...##.",
        "..####..",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000000000000000000000000000000020002014008801000F0000000000000000",
      strip_indices: [240, 261, 266, 268, 283, 284, 288, 304, 305, 306, 307],
      lit_count: 11,
      bbox: [7, 11, 14, 14],
    },
    310: {
      id: 310,
      name: "mouth_310",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "FF", "81", "42", "24", "18", "00"],
      preview: [
        "........",
        "........",
        "########",
        "#......#",
        ".#....#.",
        "..#..#..",
        "...##...",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000807F00201000080100090060000000000000",
      strip_indices: [
        239, 240, 241, 242, 243, 244, 245, 246, 261, 268, 283, 288, 304, 307, 325, 326,
      ],
      lit_count: 16,
      bbox: [7, 11, 14, 15],
    },
    311: {
      id: 311,
      name: "mouth_311",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "FF", "81", "81", "42", "3C", "00"],
      preview: [
        "........",
        "........",
        "########",
        "#......#",
        "#......#",
        ".#....#.",
        "..####..",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000807F002010000402801000F0000000000000",
      strip_indices: [
        239, 240, 241, 242, 243, 244, 245, 246, 261, 268, 282, 289, 303, 308, 324, 325, 326, 327,
      ],
      lit_count: 18,
      bbox: [7, 11, 14, 15],
    },
    312: {
      id: 312,
      name: "mouth_312",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "3C", "42", "42", "24", "18", "00"],
      preview: [
        "........",
        "........",
        "..####..",
        ".#....#.",
        ".#....#.",
        "..#..#..",
        "...##...",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000001E00400800080100090060000000000000",
      strip_indices: [241, 242, 243, 244, 262, 267, 283, 288, 304, 307, 325, 326],
      lit_count: 12,
      bbox: [8, 11, 13, 15],
    },
    313: {
      id: 313,
      name: "mouth_313",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "7E", "42", "24", "18", "00", "00"],
      preview: [
        "........",
        "........",
        ".######.",
        ".#....#.",
        "..#..#..",
        "...##...",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000003F00400800900000060000000000000000",
      strip_indices: [240, 241, 242, 243, 244, 245, 262, 267, 284, 287, 305, 306],
      lit_count: 12,
      bbox: [8, 11, 13, 14],
    },
    314: {
      id: 314,
      name: "mouth_314",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "3C", "42", "81", "81", "FF", "00"],
      preview: [
        "........",
        "........",
        "..####..",
        ".#....#.",
        "#......#",
        "#......#",
        "########",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000001E004008000402402000FC030000000000",
      strip_indices: [
        241, 242, 243, 244, 262, 267, 282, 289, 302, 309, 322, 323, 324, 325, 326, 327, 328, 329,
      ],
      lit_count: 18,
      bbox: [7, 11, 14, 15],
    },
    315: {
      id: 315,
      name: "mouth_315",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "3C", "42", "42", "81", "7E", "00"],
      preview: [
        "........",
        "........",
        "..####..",
        ".#....#.",
        ".#....#.",
        "#......#",
        ".######.",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000001E004008000801402000F8010000000000",
      strip_indices: [
        241, 242, 243, 244, 262, 267, 283, 288, 302, 309, 323, 324, 325, 326, 327, 328,
      ],
      lit_count: 16,
      bbox: [7, 11, 14, 15],
    },
    316: {
      id: 316,
      name: "mouth_316",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "18", "24", "42", "42", "24", "18"],
      preview: [
        "........",
        "........",
        "...##...",
        "..#..#..",
        ".#....#.",
        ".#....#.",
        "..#..#..",
        "...##...",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000C00800400080180100090000003000000",
      strip_indices: [242, 243, 263, 266, 283, 288, 303, 308, 324, 327, 344, 345],
      lit_count: 12,
      bbox: [8, 11, 13, 16],
    },
    317: {
      id: 317,
      name: "mouth_317",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "18", "24", "24", "24", "24", "18", "00"],
      preview: [
        "........",
        "...##...",
        "..#..#..",
        "..#..#..",
        "..#..#..",
        "..#..#..",
        "...##...",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000003000001200800400900000090060000000000000",
      strip_indices: [220, 221, 241, 244, 263, 266, 284, 287, 304, 307, 325, 326],
      lit_count: 12,
      bbox: [9, 10, 12, 15],
    },
    318: {
      id: 318,
      name: "mouth_318",
      type: "mouth",
      size: [8, 8],
      row_hex: ["18", "24", "24", "24", "24", "24", "18", "00"],
      preview: [
        "...##...",
        "..#..#..",
        "..#..#..",
        "..#..#..",
        "..#..#..",
        "..#..#..",
        "...##...",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "000000000000000000000000000000000000000000000000C000004800001200800400900000090060000000000000",
      strip_indices: [198, 199, 219, 222, 241, 244, 263, 266, 284, 287, 304, 307, 325, 326],
      lit_count: 14,
      bbox: [9, 9, 12, 15],
    },
    319: {
      id: 319,
      name: "mouth_319",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "18", "24", "24", "18", "00", "00"],
      preview: [
        "........",
        "........",
        "...##...",
        "..#..#..",
        "..#..#..",
        "...##...",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000C00800400900000060000000000000000",
      strip_indices: [242, 243, 263, 266, 284, 287, 305, 306],
      lit_count: 8,
      bbox: [9, 11, 12, 14],
    },
    320: {
      id: 320,
      name: "mouth_320",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "FF", "81", "FF", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "########",
        "#......#",
        "########",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000E01F000402C03F0000000000000000",
      strip_indices: [
        261, 262, 263, 264, 265, 266, 267, 268, 282, 289, 302, 303, 304, 305, 306, 307, 308, 309,
      ],
      lit_count: 18,
      bbox: [7, 12, 14, 14],
    },
    321: {
      id: 321,
      name: "mouth_321",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "FF", "81", "7E", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "########",
        "#......#",
        ".######.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000E01F000402801F0000000000000000",
      strip_indices: [
        261, 262, 263, 264, 265, 266, 267, 268, 282, 289, 303, 304, 305, 306, 307, 308,
      ],
      lit_count: 16,
      bbox: [7, 12, 14, 14],
    },
    322: {
      id: 322,
      name: "mouth_322",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "7E", "81", "FF", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".######.",
        "#......#",
        "########",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000C00F000402C03F0000000000000000",
      strip_indices: [
        262, 263, 264, 265, 266, 267, 282, 289, 302, 303, 304, 305, 306, 307, 308, 309,
      ],
      lit_count: 16,
      bbox: [7, 12, 14, 14],
    },
    323: {
      id: 323,
      name: "mouth_323",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "7E", "42", "3C", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".######.",
        ".#....#.",
        "..####..",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000C00F000801000F0000000000000000",
      strip_indices: [262, 263, 264, 265, 266, 267, 283, 288, 304, 305, 306, 307],
      lit_count: 12,
      bbox: [8, 12, 13, 14],
    },
    324: {
      id: 324,
      name: "mouth_324",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "3C", "42", "7E", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "..####..",
        ".#....#.",
        ".######.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000000000000000000000000000000000008007000801801F0000000000000000",
      strip_indices: [263, 264, 265, 266, 283, 288, 303, 304, 305, 306, 307, 308],
      lit_count: 12,
      bbox: [8, 12, 13, 14],
    },
    325: {
      id: 325,
      name: "mouth_325",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "7E", "42", "7E", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".######.",
        ".#....#.",
        ".######.",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000C00F000801801F0000000000000000",
      strip_indices: [262, 263, 264, 265, 266, 267, 283, 288, 303, 304, 305, 306, 307, 308],
      lit_count: 14,
      bbox: [8, 12, 13, 14],
    },
    326: {
      id: 326,
      name: "mouth_326",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "81", "42", "7E", "42", "81", "00"],
      preview: [
        "........",
        "........",
        "#......#",
        ".#....#.",
        ".######.",
        ".#....#.",
        "#......#",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000804000400800F80180100004020000000000",
      strip_indices: [239, 246, 262, 267, 283, 284, 285, 286, 287, 288, 303, 308, 322, 329],
      lit_count: 14,
      bbox: [7, 11, 14, 15],
    },
    327: {
      id: 327,
      name: "mouth_327",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "66", "99", "81", "99", "66", "00"],
      preview: [
        "........",
        "........",
        ".##..##.",
        "#..##..#",
        "#......#",
        "#..##..#",
        ".##..##.",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000003300201300040240260098010000000000",
      strip_indices: [
        240, 241, 244, 245, 261, 264, 265, 268, 282, 289, 302, 305, 306, 309, 323, 324, 327, 328,
      ],
      lit_count: 18,
      bbox: [7, 11, 14, 15],
    },
    328: {
      id: 328,
      name: "mouth_328",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "66", "99", "00", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".##..##.",
        "#..##..#",
        "........",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000C00C00640200000000000000000000",
      strip_indices: [262, 263, 266, 267, 282, 285, 286, 289],
      lit_count: 8,
      bbox: [7, 12, 14, 13],
    },
    329: {
      id: 329,
      name: "mouth_329",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "24", "5A", "00", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "..#..#..",
        ".#.##.#.",
        "........",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000800400680100000000000000000000",
      strip_indices: [263, 266, 283, 285, 286, 288],
      lit_count: 6,
      bbox: [8, 12, 13, 13],
    },
    330: {
      id: 330,
      name: "mouth_330",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "42", "5A", "24", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        ".#....#.",
        ".#.##.#.",
        "..#..#..",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000000000400800680100090000000000000000",
      strip_indices: [262, 267, 283, 285, 286, 288, 304, 307],
      lit_count: 8,
      bbox: [8, 12, 13, 14],
    },
    331: {
      id: 331,
      name: "mouth_331",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "42", "5A", "24", "00", "00", "00"],
      preview: [
        "........",
        "........",
        ".#....#.",
        ".#.##.#.",
        "..#..#..",
        "........",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000000000002100400B00900000000000000000000000",
      strip_indices: [240, 245, 262, 264, 265, 267, 284, 287],
      lit_count: 8,
      bbox: [8, 11, 13, 13],
    },
    332: {
      id: 332,
      name: "mouth_332",
      type: "mouth",
      size: [8, 8],
      row_hex: ["00", "00", "00", "02", "52", "2C", "00", "00"],
      preview: [
        "........",
        "........",
        "........",
        "......#.",
        ".#.#..#.",
        "..#.##..",
        "........",
        "........",
      ],
      placement: [
        {
          x: 7,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000000000000000000000000000000000000008002801000D0000000000000000",
      strip_indices: [267, 283, 286, 288, 304, 306, 307],
      lit_count: 7,
      bbox: [8, 12, 13, 14],
    },
    401: {
      id: 401,
      name: "cheek_401",
      type: "cheek",
      size: [4, 4],
      row_hex: ["00", "60", "00", "00"],
      preview: ["....", ".##.", "....", "...."],
      placement: [
        {
          x: 2,
          y: 9,
          mirror_x: true,
        },
        {
          x: 16,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000600018000000000000000000000000000000000000",
      strip_indices: [213, 214, 227, 228],
      lit_count: 4,
      bbox: [3, 10, 18, 10],
    },
    402: {
      id: 402,
      name: "cheek_402",
      type: "cheek",
      size: [4, 4],
      row_hex: ["00", "50", "00", "00"],
      preview: ["....", ".#.#", "....", "...."],
      placement: [
        {
          x: 2,
          y: 9,
          mirror_x: true,
        },
        {
          x: 16,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000500028000000000000000000000000000000000000",
      strip_indices: [212, 214, 227, 229],
      lit_count: 4,
      bbox: [2, 10, 19, 10],
    },
    403: {
      id: 403,
      name: "cheek_403",
      type: "cheek",
      size: [4, 4],
      row_hex: ["50", "A0", "00", "00"],
      preview: [".#.#", "#.#.", "....", "...."],
      placement: [
        {
          x: 2,
          y: 9,
          mirror_x: true,
        },
        {
          x: 16,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "00000000000000000000000000000000000000000000004001A0A00014000000000000000000000000000000000000",
      strip_indices: [190, 192, 205, 207, 213, 215, 226, 228],
      lit_count: 8,
      bbox: [2, 9, 19, 10],
    },
    404: {
      id: 404,
      name: "cheek_404",
      type: "cheek",
      size: [4, 4],
      row_hex: ["A0", "50", "00", "00"],
      preview: ["#.#.", ".#.#", "....", "...."],
      placement: [
        {
          x: 2,
          y: 9,
          mirror_x: true,
        },
        {
          x: 16,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000800250500028000000000000000000000000000000000000",
      strip_indices: [191, 193, 204, 206, 212, 214, 227, 229],
      lit_count: 8,
      bbox: [2, 9, 19, 10],
    },
    405: {
      id: 405,
      name: "cheek_405",
      type: "cheek",
      size: [4, 4],
      row_hex: ["00", "70", "00", "70"],
      preview: ["....", ".###", "....", ".###"],
      placement: [
        {
          x: 2,
          y: 9,
          mirror_x: true,
        },
        {
          x: 16,
          y: 9,
          mirror_x: false,
        },
      ],
      frame: "0000000000000000000000000000000000000000000000000000700038000000078003000000000000000000000000",
      strip_indices: [212, 213, 214, 227, 228, 229, 256, 257, 258, 271, 272, 273],
      lit_count: 12,
      bbox: [2, 10, 19, 12],
    },
  },
};

// Configure aliases and navigation metadata
// Connection relationship:
// - WEBUI_CONFIG is an editable entry; create a short name here to avoid subsequent logic being scattered in deep access.
// - PAGES drives both the navigation buttons and the target page id of switchPage().
// - API_ENDPOINTS is used uniformly by apiGet()/apiPost()/upload helpers.
// - MATRIX_VIEW_CONFIGS connects the matrix id in index.html to the corresponding frame provider.
// All adjustable values are modified first in WEBUI_CONFIG; only runtime aliases are created here.
const PAGES = WEBUI_CONFIG.navigation.pages;
const MATRIX = EXPRESSION_PARTS.matrix;
const ROW_RANGES = MATRIX.row_valid_x_ranges;
const TOTAL_LEDS = MATRIX.num_leds;
// Packed "theoretical minimum frame" geometry: 370 LEDs -> ceil(370/8) = 47 bytes (94 hex chars).
const PACKED_FRAME_BYTES = Math.ceil(TOTAL_LEDS / 8);
const PACKED_FRAME_HEX_CHARS = PACKED_FRAME_BYTES * 2;
const COLS = MATRIX.cols;
const ROWS = MATRIX.rows;
const FACE_LIBRARY_RESOURCE = WEBUI_CONFIG.faces.resourcePath;
const FACE_LIBRARY_FILENAME = WEBUI_CONFIG.faces.localFilename;
const FACE_SCHEMA_FORMAT = WEBUI_CONFIG.faces.schemaFormat;
const DEFAULT_STARTUP_FACE_ID = WEBUI_CONFIG.faces.startupFaceId;
const DEFAULT_LED_COLOR = WEBUI_CONFIG.led.defaultColor;
const LED_PREVIEW_SIZE = Object.freeze(WEBUI_CONFIG.led.previewSize);
const DEFAULT_LED_BRIGHTNESS = WEBUI_CONFIG.led.defaultBrightness;
const LED_ESTIMATED_WATTS_PER_CHANNEL = WEBUI_CONFIG.led.estimatedWattsPerChannel;
const LED_CHANNEL_COUNT = WEBUI_CONFIG.led.channelCount;
const LED_FULL_BRIGHTNESS = WEBUI_CONFIG.led.fullBrightness;
const LED_POWER_WARNING_WATTS = WEBUI_CONFIG.led.powerWarningWatts;
const MIN_LED_BRIGHTNESS = WEBUI_CONFIG.led.minBrightness;
const MAX_LED_BRIGHTNESS = WEBUI_CONFIG.led.maxBrightness;
const MAX_SCROLL_TEXT_CHARS = WEBUI_CONFIG.scroll.maxTextChars;
// Firmware bounds sourceText by UTF-8 BYTES (MAX_SCROLL_TEXT_BYTES), not characters.
// 1000 CJK/emoji chars can exceed 4096 bytes, so a char-only limit lets the upload
// hit a firmware 413. This default mirrors config.h and is overwritten by the live
// value from /api/status (data.scrollLimits.maxTextBytes) in applyFirmwareRuntimeState.
let firmwareScrollMaxTextBytes = 4096;
const DEVICE_AP_SSID = WEBUI_CONFIG.device.apSsid;
const DEVICE_AP_PASSWORD = WEBUI_CONFIG.device.apPassword;
const DEVICE_AP_DOMAIN = WEBUI_CONFIG.device.apDomain;
const DEFAULT_AP_IP = WEBUI_CONFIG.device.defaultApIp;
const AUTO_INTERVAL_MIN_MS = WEBUI_CONFIG.autoInterval.minMs;
const AUTO_INTERVAL_MAX_MS = WEBUI_CONFIG.autoInterval.maxMs;
const AUTO_INTERVAL_BUTTON_STEP_MS = WEBUI_CONFIG.autoInterval.buttonStepMs;
const AUTO_INTERVAL_PRESETS_MS = WEBUI_CONFIG.autoInterval.presetsMs;
const POWER_STATUS_REFRESH_MS = WEBUI_CONFIG.power.statusRefreshMs;
const API_GET_TIMEOUT_MS = WEBUI_CONFIG.api.getTimeoutMs;
const API_POST_TIMEOUT_MS = WEBUI_CONFIG.api.postTimeoutMs;
const API_UPLOAD_TIMEOUT_MS = WEBUI_CONFIG.api.uploadTimeoutMs;
const LAYOUT_ONE_COLUMN_MAX_PX = WEBUI_CONFIG.layout.oneColumnMaxPx;
const LAYOUT_THREE_COLUMNS_MIN_PX = WEBUI_CONFIG.layout.threeColumnsMinPx;
const API_ENDPOINTS = Object.freeze(WEBUI_CONFIG.api.endpoints);
const MATRIX_VIEW_CONFIGS = [
  ["matrix-basic", () => currentFrame, false, null, false],
  ["matrix-custom-edit", () => editFrame, true, editCell, false],
  ["matrix-parts", () => partsFrame, false, null, false],
  ["matrix-scroll", () => scrollFrame, false, null, false],
  ["matrix-debug", () => debugPreviewFrame, false, null, false],
];
const DEFAULT_SCROLL_FPS = WEBUI_CONFIG.scroll.defaultFps;
const SCROLL_FPS_MIN = WEBUI_CONFIG.scroll.fpsMin;
const SCROLL_FPS_MAX = WEBUI_CONFIG.scroll.fpsMax;
const SCROLL_FPS_PRESETS = WEBUI_CONFIG.scroll.fpsPresets;
const FIRMWARE_SCROLL_MAX_FRAMES_DEFAULT = WEBUI_CONFIG.scroll.firmwareMaxFramesDefault;
let firmwareScrollMaxFrames = FIRMWARE_SCROLL_MAX_FRAMES_DEFAULT;
const SCROLL_UPLOAD_CHUNK_FRAMES = WEBUI_CONFIG.scroll.uploadChunkFrames;
// Text scrolling source text synchronization: generator identity versus first block byte budget.
// fontId = TEXT_SCROLL_FONT_MODEL. Both ID constants must be passed through the firmware
// [A-Za-z0-9._:-] Rules (D9, test mandatory).
// Any reference to TEXT_SCROLL_CHAR_SPACING, whitespace margins, textScrollVerticalOffset() or
// Modifications to extractFrameFromTextImage must bump SCROLL_GENERATOR_VERSION;
// bump fontModel when ark12.json changes.
const SCROLL_GENERATOR_VERSION = "webui-scrollgen-6.4.2";
const SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES = 12 * 1024;
// Firmware scroll-rate sync: estimate the device's ACTUAL scroll fps from periodic frame-index
// samples and retune only the preview timer (never the fps slider/buttons or frame data).
const HW_RATE_WINDOW_MS = 8000;     // keep ~8s of (time, index) samples
const HW_RATE_MIN_SAMPLES = 3;      // need at least this many samples before estimating
const HW_RATE_MIN_SPAN_MS = 2000;   // ...spanning at least this much time
const HW_RATE_MIN_FRAMES = 3;       // ...and at least this many advanced frames
const HW_RATE_FPS_MIN = 0.2;        // ignore estimates outside a sane range
const HW_RATE_FPS_MAX = 120;
const HW_RATE_EMA_ALPHA = 0.4;      // smoothing of the measured fps
const HW_RATE_RETUNE_RATIO = 0.05;  // only retune the preview timer on >5% interval change
const HW_PHASE_GAIN = 0.12;         // proportional gain: preview speed factor = 1 + gain*phaseError
const HW_PHASE_MAX_ADJ = 0.25;      // cap preview speed change to +/-25% (smooth, no skip/hold/jump)
const RUNTIME_STATUS_QUERY = WEBUI_CONFIG.api.runtimeStatusQuery;
const SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS =
  WEBUI_CONFIG.firmwareQueues.scrollButtonStopFullSyncDelayMs;
const WEBUI_FRAME_SEND_INTERVAL_MS = WEBUI_CONFIG.firmwareQueues.frameSendIntervalMs;
const WEBUI_FRAME_QUEUE_MAX = WEBUI_CONFIG.firmwareQueues.frameQueueMax;
const WEBUI_BUTTON_COMMAND_INTERVAL_MS = WEBUI_CONFIG.firmwareQueues.buttonCommandIntervalMs;
const WEBUI_BUTTON_COMMAND_QUEUE_MAX = WEBUI_CONFIG.firmwareQueues.buttonCommandQueueMax;
const BUTTON_PRESS_DOWN_MS = WEBUI_CONFIG.interaction.buttonPressDownMs;
const BUTTON_PRESS_UP_MS = WEBUI_CONFIG.interaction.buttonPressUpMs;
const SELECT_MENU_HIDE_DELAY_MS = WEBUI_CONFIG.interaction.selectMenuHideDelayMs;
const PAGE_SCROLL_KEYS = new Set(WEBUI_CONFIG.interaction.pageScrollKeys);
const UI_WEB_FONT_FAMILY = WEBUI_CONFIG.fonts.uiFamily;
const TEXT_SCROLL_FONT_MODEL = WEBUI_CONFIG.textScroll.fontModel;
const TEXT_SCROLL_FONT_RESOURCE = WEBUI_CONFIG.textScroll.fontResource;
const TEXT_SCROLL_FONT_FAMILY = WEBUI_CONFIG.textScroll.fontFamily;
const TEXT_SCROLL_FALLBACK_FONT_FAMILY = WEBUI_CONFIG.textScroll.fontFallbackFamily || "";
const TEXT_SCROLL_BROWSER_FONT_SAMPLE = WEBUI_CONFIG.textScroll.browserFontSample;
const TEXT_SCROLL_BROWSER_FALLBACK_FONT_SAMPLE =
  WEBUI_CONFIG.textScroll.browserFallbackFontSample || "";
const TEXT_SCROLL_FONT_STACK = TEXT_SCROLL_FALLBACK_FONT_FAMILY
  ? `"${TEXT_SCROLL_FALLBACK_FONT_FAMILY}", "${TEXT_SCROLL_FONT_FAMILY}"`
  : `"${TEXT_SCROLL_FONT_FAMILY}"`;
const TEXT_SCROLL_CHAR_SPACING = WEBUI_CONFIG.textScroll.charSpacing;
const TEXT_SCROLL_SPACE_COLUMNS = WEBUI_CONFIG.textScroll.spaceColumns;
const TEXT_SCROLL_MISSING_GLYPH_CP = WEBUI_CONFIG.textScroll.missingGlyphCodePoint; // Fallback without using system fonts.
const BOOT_STATUS_ENDPOINT = `${API_ENDPOINTS.status}${RUNTIME_STATUS_QUERY}`;
const BOOT_STATUS_TIMEOUT_MS = WEBUI_CONFIG.api.bootStatusTimeoutMs;
const BOOT_MIN_DISPLAY_MS = WEBUI_CONFIG.boot.minDisplayMs;
const FIRST_PAGE_REVEAL_SELECTOR = WEBUI_CONFIG.boot.firstPageRevealSelector.join(",");

// Data: Color Preset Library
// Connection relationship:
// - initColorInput() populates the main color drop-down box with parent_color_groups.
// - child_color_groups Populate the child color drop-down box based on the main color selection.
// - setColor() finally synchronizes the selected color to the preview, button state and firmware frame payload.
const parent_color_groups = [
  {
    id: 0,
    name: "默认璃奈粉色",
    color: "ec3fc7",
    desc: "父级颜色按钮，仅提供父级色",
  },
  {
    id: 1,
    name: "μ's-洋红色",
    color: "e4007f",
    desc: "μ's 子颜色组",
  },
  {
    id: 2,
    name: "Aqours-水蓝色",
    color: "00a1e8",
    desc: "Aqours / Saint Snow / 子团体颜色组",
  },
  {
    id: 3,
    name: "虹咲学园-金色",
    color: "f8b656",
    desc: "虹咲 / 子团体颜色组",
  },
  {
    id: 4,
    name: "Liella!-紫色",
    color: "a5469b",
    desc: "Liella! / 子团体颜色组",
  },
  {
    id: 5,
    name: "蓮ノ空-粉色",
    color: "fb8a9b",
    desc: "蓮ノ空 子颜色组",
  },
];
const child_color_groups = {
  1: [
    ["高坂穗乃果-橙色", "f38500"],
    ["绚濑绘里-水蓝色", "7aeeff"],
    ["南小鸟-白色", "cebfbf"],
    ["园田海未-蓝色", "1769ff"],
    ["星空凛-黄色", "fff832"],
    ["西木野真姬-红色", "ff503e"],
    ["东条希-紫罗兰色", "c455f6"],
    ["小泉花阳-绿色", "6ae673"],
    ["矢泽妮可-粉色", "ff4f91"],
  ],
  2: [
    ["高海千歌-蜜柑色", "ff9547"],
    ["樱内梨子-樱花粉色", "ff9eac"],
    ["松浦果南-祖母绿色", "27c1b7"],
    ["黑泽黛雅-红色", "db0839"],
    ["渡边曜-亮蓝色", "66c0ff"],
    ["津岛善子-白色", "c1cad4"],
    ["国木田花丸-黄色", "ffd010"],
    ["小原鞠莉-紫罗兰色", "c252c6"],
    ["黑泽露比-粉色", "ff6fbe"],
    ["CYaRon!-橙色", "ffa434"],
    ["AZALEA-粉色", "ff5a79"],
    ["Guilty Kiss-紫色", "825deb"],
    ["YYY-绿色", "53ab7f"],
    ["鹿角圣良-天蓝色", "00ccff"],
    ["鹿角理亚-纯白色", "bbbbbb"],
    ["Saint Snow-红色", "cb3935"],
  ],
  3: [
    ["上原步梦-浅粉色", "ed7d95"],
    ["中须霞-蜡笔黄色", "e7d600"],
    ["樱坂雫-浅蓝色", "01b7ed"],
    ["朝香果林-皇室蓝色", "485ec6"],
    ["宫下爱-超橙色", "ff5800"],
    ["近江彼方-堇色", "a664a0"],
    ["优木雪菜-猩红色", "d81c2f"],
    ["艾玛·维尔德-浅绿色", "84c36e"],
    ["天王寺璃奈-纸白色", "9ca5b9"],
    ["三船栞子-翡翠色", "37b484"],
    ["米雅·泰勒-白金银色", "a9a898"],
    ["钟岚珠-玫瑰金色", "f8c8c4"],
    ["DiverDiva-银紫色", "ab76f7"],
    ["A·ZU·NA-意大利红色", "ff0042"],
    ["QU4RTZ-奶茶色", "d9db83"],
    ["R3BIRTH-坦桑蓝色", "424a9d"],
  ],
  4: [
    ["涩谷香音-金盏花色", "ff7f27"],
    ["唐可可-蜡笔蓝色", "a0fff9"],
    ["岚千砂都-桃粉色", "ff6e90"],
    ["平安名堇-蜜瓜绿色", "74f466"],
    ["叶月恋-宝石蓝色", "0000a0"],
    ["樱小路希奈子-玉米黄色", "fff442"],
    ["米女芽衣-胭脂红色", "ff3535"],
    ["若菜四季-冰绿白色", "b2ffdd"],
    ["鬼冢夏美-鬼夏粉色", "ff51c4"],
    ["薇恩·玛格丽特-优雅紫色", "e49dfd"],
    ["鬼冢冬毬-烟熏蓝色", "4cd2e2"],
    ["CatChu!-红色", "e8243c"],
    ["KALEIDOSCORE-浅紫色", "bcbcde"],
    ["5yncri5e!-黄色", "ffe840"],
  ],
  5: [
    ["日野下花帆-太阳色", "f8b500"],
    ["村野沙耶香-冰蓝色", "5383c3"],
    ["乙宗梢-人鱼绿色", "68be8d"],
    ["夕雾缀理-我的红色", "ba2636"],
    ["大泽瑠璃乃-瑠璃粉色", "e7609e"],
    ["藤岛慈-天使白色", "c8c2c6"],
    ["百生吟子-天之原色", "a2d7dd"],
    ["徒町小铃-长庚星色", "fad764"],
    ["安养寺姬芽-糖果紫色", "9d8de2"],
    ["Cerise Bouquet-玫瑰色", "da645f"],
    ["DOLLCHESTRA-蓝色", "163bca"],
    ["Mira-Cra Park!-黄色", "f3b171"],
  ],
};

// Matrix geometry and physical/logical LED mapping
// Connection relationship:
// - ROW_RANGES describes the effective LED range of each row, used for preview grid and text scrolling and cropping.
// - XY_TO_INDEX/INDEX_TO_XY are bidirectional tables between UI coordinates and logical 370 point indexes.
// - PHYSICAL_TO_LOGICAL_INDEX handles snake wiring and maps the firmware/light strip physical order back to the UI.
// - All frames maintain logical order; only transition when interacting with firmware/physical light strips.
const XY_TO_INDEX = Array.from(
  {
    length: ROWS,
  },
  () => Array(COLS).fill(-1),
);
const INDEX_TO_XY = [];
let ledIndex = 0;
for (let y = 0; y < ROWS; y++) {
  const [x0, x1] = ROW_RANGES[y];
  for (let x = x0; x <= x1; x++) {
    XY_TO_INDEX[y][x] = ledIndex;
    INDEX_TO_XY[ledIndex] = [x, y];
    ledIndex++;
  }
}
const SERPENTINE_WIRING = !!MATRIX.serpentine;
const SERPENTINE_ODD_ROWS_REVERSED = MATRIX.serpentine_odd_rows_reversed !== false;
const PHYSICAL_TO_LOGICAL_INDEX = Array(TOTAL_LEDS).fill(-1);

function logicalToPhysicalIndex(index) {
  const xy = INDEX_TO_XY[index];
  if (!xy || !SERPENTINE_WIRING) return index;
  const [x, y] = xy;
  if (!SERPENTINE_ODD_ROWS_REVERSED || (y & 1) === 0) return index;
  const [x0, x1] = ROW_RANGES[y];
  return XY_TO_INDEX[y][x0 + x1 - x];
}

function physicalToLogicalIndex(index) {
  return PHYSICAL_TO_LOGICAL_INDEX[index] ?? index;
}
for (let logical = 0; logical < TOTAL_LEDS; logical++) {
  PHYSICAL_TO_LOGICAL_INDEX[logicalToPhysicalIndex(logical)] = logical;
}

// runtime status
// Connection relationship:
// - state is a shared snapshot of UI and firmware; renderState() only reads it to update controls.
// - currentFrame/editFrame/partsFrame/scrollFrame are working buffers for different pages.
// - firmware/queue variables record API send, poll and error status to avoid flooding the ESP32 with duplicate requests.
// - The scroll object only saves the timeline, playback and upload status of 6.4 text scrolling.
// Synchronized runtime state between WebUI controls and firmware.
let state = {
  mode: "manual",
  faceIndex: 0,
  brightness: DEFAULT_LED_BRIGHTNESS,
  defaultBrightness: DEFAULT_LED_BRIGHTNESS,
  color: DEFAULT_LED_COLOR,
  parentColorId: 0,
  selectedChildColor: null,
  colorSelection: "parent",
  playback: "idle",
  apDomain: DEVICE_AP_DOMAIN,
  apIp: DEFAULT_AP_IP,
  autoInterval: 3000,
  refreshPolicy: "dirty-frame / 按需刷新",
  lastRefreshReason: "init",
  refreshCount: 0,
  textScrollActive: false,
  actualFps: 0,
  dpsActive: false,
  restoreAutoAfterScroll: false,
  batteryV: null,
  batteryPercent: null,
  batteryPowered: true,
  batteryStateText: "电池",
  batteryMinV: null,
  batteryMaxV: null,
  batteryNominalMin: null,
  batteryNominalMax: null,
  batteryAdcMv: null,
  batteryPrevAdcMv: null,
  batteryDisconnectDropMv: null,
  batteryDisconnectDropThresholdMv: null,
  batteryDisconnectLowThresholdMv: null,
  batteryReconnectThresholdMv: null,
  batteryDisconnected: false,
  batteryLowVoltageUnpowered: false,
  batteryUnpoweredLowThreshold: 5.0,
  batteryLastInstantVbat: null,
  batteryIconClass: "status-dot dim",
  batteryIconColor: "#9aa6b2",
  chargeV: null,
  charging: null,
  chargeAdcMv: null,
  chargeIconClass: "status-dot dim",
  chargeIconColor: "#9aa6b2",
  // Data source tags and sync timestamps (page-debug rewrite): Differentiate between firmware real-time values and local/config fallback values.
  apIpSource: "Config",
  apDomainSource: "Config",
  lastStatusSyncAt: null,
  lastPowerSyncAt: null,
  lastNetworkSyncAt: null,
};
let currentFrame = blankFrame();
let editFrame = blankFrame();
let partsFrame = blankFrame();
let scrollFrame = blankFrame();
// Debug preview dedicated buffer: isolated from global currentFrame, preview-only operations are only written here,
// Don't pollute matrix-basic/DPS/replicated packed frame (page-debug rewrites v2 rule 1).
let debugPreviewFrame = blankFrame();
let debugPreviewSource = "none";
let debugPreviewReason = "init";
let debugPreviewUpdatedAt = null;
let firmwareLastSyncAt = null;
let selectedCall = {
  leye: "101",
  reye: "201",
  mouth: "301",
  cheek: "400",
};
let partsSymmetry = false;
let liveSendEnabled = true;
let liveSyncedFrame = blankFrame();
let defaultFaces = [];
let userFaces = [];
let faceLibraryDocument = null;
let faceLibraryFileHandle = null;
let faceLibraryLoadError = "";
let faceLibraryRefreshTimer = 0;
let faceLibraryRefreshInFlight = null;
let faceLibraryRefreshQueued = false;
let faceLibraryAutoRefreshBound = false;
let pointerFaceDrag = null;
let logs = [];
// Level/rendering status of communication log (6.5 debug page).
// - logLevel filters out low-priority noise (high-frequency entries such as dragging the slider are recorded as debug and hidden by default).
// - renderLog only updates the DOM when visible in 6.5 and merges it by animation frame to avoid rebuilding the entire segment for each log
// Text and forced synchronous reflow; other pages are only marked dirty and will be fully rendered when entering 6.5.
const LOG_LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };
const LOG_BUFFER_MAX = 500;   // Keep full buffer for download/copy
const LOG_VIEW_MAX = 120;     // The most recent row actually rendered to the DOM
let logLevel = LOG_LEVELS.info;
let logRenderRaf = 0;
let logDirty = false;
let pendingFramePacket = null;
let lastApiErrorLogAt = 0;
let colorDomSynced = false;
let lastUserBrightnessMs = 0;
let firmwareStatusPollTimer = null;
let lastFirmwareStatusPollAt = 0;
let firmwareStatusVersion = null;
let firmwareNextPollMs = 1000;
let lastScrollStopEventSeq = 0;
let firmwareScrollStopFullSyncTimer = null;
let firmwareRuntimeSummaryInFlight = false;
let firmwareFullStatusInFlight = false;
let powerStatusPollTimer = null;
let lastPowerStatusRefreshAt = 0;
let powerStatusRefreshInFlight = false;
const firmware = {
  online: false,
  lastRequest: "—",
  lastStatus: "not connected",
  lastError: "—",
  frameEndpoint: API_ENDPOINTS.frame,
  commandEndpoint: API_ENDPOINTS.command,
  savedFacesEndpoint: API_ENDPOINTS.savedFaces,
  savedFacesPath: FACE_LIBRARY_RESOURCE,
  faceLibrarySource: FACE_LIBRARY_FILENAME,
  sentFrames: 0,
  sentCommands: 0,
  droppedFrames: 0,
  droppedCommands: 0,
  frameQueue: 0,
  buttonQueue: 0,
  savedFacesSync: "not loaded",
};
let matrixViews = [];
let scroll = {
  timer: null,
  active: false,
  paused: false,
  userPaused: false,
  systemPaused: false,
  pauseToggleLocked: false,
  firmwareBacked: false,
  uploading: false,
  commandBusy: false,
  startBusy: false,
  pauseBusy: false,
  stopBusy: false,
  fpsBusy: false,
  restoring: false,
  lightSyncing: false,
  stepBusy: false,
  uploadProgress: 0,
  uploadLabel: "",
  uploadProgressToken: 0,
  offset: 0,
  frameIndex: 0,
  frames: [],
  signature: "",
  dirty: false,
  dirtyNoticeLogged: false,
  frameCounter: 0,
  fpsStarted: performance.now(),
  measuredFps: 0,
  // Firmware scroll-rate sync (preview-speed calibration; see recordFirmwareScrollSample).
  hwSamples: [],        // [{t, cum}] cumulative advanced frames vs time
  hwLastIndex: null,    // last raw firmware frame index (for wrap detection)
  hwLastT: 0,
  hwCum: 0,             // running cumulative advanced frames
  hwMeasuredFps: 0,     // smoothed measured device fps (0 = no estimate yet)
  previewIntervalMs: 0, // measured preview-timer interval (0 = use user fps)
  phaseError: 0,        // signed frames the device index leads the WebUI display (ground truth)
  phaseAccum: 0,        // fractional accumulator for smooth integer phase correction
  // Source text synchronization (plan v6):
  // timelineId = current firmware/upload timeline identity
  // framesTimelineId = scroll.frames exactly corresponds to the timeline (only in generator identity +
  // Bind when the frame number is exactly the same and the text is not truncated, C2/D5/E4)
  timelineId: "",
  framesTimelineId: "",
  uploadGeneration: 0,
  returnMode: "manual",
  restoredSourceText: "",
  restoredFromFirmwareMeta: false,
  restoreWarning: "",
  restoredTextTruncated: false, // E4
  textEdited: false, // Whether the user has edited the input box (unsent local modification protection, C5)
};

// Module-level status of source text recovery (plan v6 2.2/2.6).
let pendingScrollMeta = null;
let scrollMetaFetchInFlight = false;
let lastScrollMetaFetchAt = 0;
// Do not trigger the /api/scroll/meta pull before the startup key read is completed to avoid crowding out the single-threaded ESP server.
let scrollMetaRestoreEnabled = false;
let lastFwScrollTimelineId = "";
let lastFwScrollHasSourceText = false;
let lastFwScrollFrameCount = 0;
let lastFwScrollDisplaying = false;
let lastScrollRestoreStatusDebugKey = "";
let postBootScrollMetaRestoreStarted = false;
// The factory default text of the input box in index.html; regarded as "non-user unsent content" and allowed to be overwritten by recovery.
let scrollDefaultText = "";

// Shared helper functions and DOM bindings
// Connection relationship:
// - This group is the underlying tool for all subsequent modules and cannot rely on any page initialization results.
// - bindControls()/setClickHandlers() makes repeated initialization idempotent and avoids repeated binding of events.
// - safeJsonParse()/parseApiJson() is a JSON defense line for API layer and local resource reading.
function safeJsonParse(text, fallback = {}) {
  try {
    return JSON.parse(text);
  } catch (e) {
    return fallback;
  }
}

function parseApiJson(text, path, fallback = {}) {
  if (!text) return fallback;
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new Error(`invalid JSON from ${path}: ${err.message || err}`);
  }
}
const scrollMachine = (function () {
  const machine = {
    state: "IDLE",
    pauseReasons: new Set(),
    epoch: 0,
    gen: { upload: 0, restore: 0, step: 0, statusPoll: 0 },
    device: { hasSession: false },
    cache: { identityBound: false, frameIndex: 0 }
  };

  function token(domain) {
    machine.gen[domain] = (machine.gen[domain] || 0) + 1;
    return { epoch: machine.epoch, dom: machine.gen[domain], domain };
  }

  function isCurrent(t) {
    if (!t) return true;
    return t.epoch === machine.epoch && t.dom === machine.gen[t.domain];
  }

  function bumpEpoch() {
    machine.epoch++;
    machine.cache.identityBound = false;
  }

  function syncPauseBacking() {
    scroll.userPaused = machine.pauseReasons.has("user");
    scroll.systemPaused = machine.pauseReasons.has("system");
    scroll.paused = machine.pauseReasons.size > 0;
    if (scroll.paused) state.playback = "scroll_paused";
  }

  function setPhase(next) {
    machine.state = next;
    scroll.restoring = next === "RESTORING";
    scroll.uploading = next === "UPLOADING" || scroll.uploading;
    scroll.active = next === "ACTIVE" && machine.pauseReasons.size === 0;
    if (next === "IDLE") scroll.active = false;
  }

  function deriveIdentityBound(meta = {}) {
    const frameCount = Number(meta.frameCount ?? meta.scrollFrameCount ?? 0) || 0;
    return (
      !scroll.restoredTextTruncated &&
      exactGeneratorMatch(meta) &&
      scroll.frames.length === frameCount &&
      scroll.framesTimelineId === String(meta.scrollTimelineId || "")
    );
  }

  function applyFirmwareCursor(payload = {}) {
    // FIX 4: Prevent sync preview glitch during upload/starting
    const isBusyState = machine.state === "GENERATING" || machine.state === "UPLOADING" || machine.state === "STARTING";
    if (isBusyState) return;

    const frameCount = Math.max(0, Math.floor(Number(payload.frameCount ?? payload.scrollFrameCount) || 0));
    const frameIndex = Number(payload.frameIndex ?? payload.scrollFrameIndex);
    const active = !!payload.firmwareScrollActive;
    const paused = !!payload.firmwareScrollPaused;
    const hasUserPaused = typeof payload.firmwareScrollUserPaused === "boolean";
    const hasSystemPaused = typeof payload.firmwareScrollSystemPaused === "boolean";
    const uploadComplete = !!(payload.uploadComplete ?? payload.scrollUploadComplete);
    const hasSourceText = !!(payload.hasSourceText ?? payload.scrollHasSourceText);

    // Mirror the firmware pause flags through the reducer's own pause events instead of
    // mutating pauseReasons directly. This gives a single mutation path for pause state
    // and makes PAUSE_SYSTEM/RESUME_SYSTEM live events rather than dead reducer cases
    // (audit fix #4). The events call syncPauseBacking() themselves.
    if (hasUserPaused) {
      dispatch(payload.firmwareScrollUserPaused ? "PAUSE_USER" : "RESUME_USER");
    }
    if (hasSystemPaused) {
      dispatch(payload.firmwareScrollSystemPaused ? "PAUSE_SYSTEM" : "RESUME_SYSTEM");
    } else if (!hasUserPaused) {
      dispatch(paused ? "PAUSE_SYSTEM" : "RESUME_SYSTEM");
    }
    // Hardware -> WebUI scroll synchronization is valid only while the LED panel
    // is actually displaying text scrolling. Cached sourceText/frameCount alone is
    // not a live session and must not resurrect old text after Stop/Clear.
    machine.device.hasSession = active || paused;
    scroll.firmwareBacked = active || paused;
    if (machine.device.hasSession && machine.state === "IDLE") {
      setPhase("ACTIVE");
    } else if (!machine.device.hasSession && machine.state === "ACTIVE") {
      setPhase("IDLE");
    }

    if (machine.device.hasSession && Number.isFinite(frameIndex) && scroll.frames.length) {
      scroll.frameIndex = clamp(frameIndex, 0, Math.max(0, scroll.frames.length - 1));
      scroll.offset = scroll.frameIndex;
      machine.cache.frameIndex = scroll.frameIndex;
    }
    // Sample the device frame index to estimate its real fps and calibrate the preview speed.
    recordFirmwareScrollSample(frameIndex, frameCount, active && !paused);
  }

  // Allowed source phases per event (audit fix #5). `null` = valid from any phase.
  // This enforces the sec 5.2 transition contract so a stale or illegal event cannot
  // silently corrupt phase-derived flags (e.g. a late START_CONFIRMED arriving in IDLE,
  // or a STEP_DONE when not STEPPING). Replacement/sync events
  // (GENERATE/RESTORE_BEGIN/STOP/FW_SYNC/TEXT_EDITED) are intentionally valid from anywhere.
  const ALLOWED_FROM = {
    GENERATE: null,
    UPLOAD_BEGIN: ["GENERATING"],
    UPLOAD_COMMIT_DONE: ["UPLOADING"],
    START_CONFIRMED: ["STARTING"],
    START_FAIL: ["STARTING"],
    UPLOAD_FAIL: ["GENERATING", "UPLOADING"],
    PAUSE_USER: ["IDLE", "ACTIVE", "STARTING", "STEPPING", "RESTORING"],
    RESUME_USER: ["IDLE", "ACTIVE", "STARTING", "STEPPING", "RESTORING"],
    PAUSE_SYSTEM: ["IDLE", "ACTIVE", "STARTING", "STEPPING", "RESTORING"],
    RESUME_SYSTEM: ["IDLE", "ACTIVE", "STARTING", "STEPPING", "RESTORING"],
    STEP: ["ACTIVE", "STEPPING"],
    STEP_DONE: ["STEPPING"],
    STOP: null,
    STOP_DONE: ["STOPPING"],
    RESTORE_BEGIN: null,
    RESTORE_DONE: ["RESTORING"],
    FW_SYNC: null,
    TEXT_EDITED: null,
  };

  function dispatch(event, payload = {}, t = null) {
    if (!isCurrent(t)) return false;
    const allowedFrom = ALLOWED_FROM[event];
    if (allowedFrom && !allowedFrom.includes(machine.state)) return false;
    switch (event) {
      case "GENERATE":
        bumpEpoch();
        setPhase("GENERATING");
        break;
      case "UPLOAD_BEGIN":
        setPhase("UPLOADING");
        break;
      case "UPLOAD_COMMIT_DONE":
        setPhase("STARTING");
        break;
      case "START_CONFIRMED":
        setPhase("ACTIVE");
        machine.pauseReasons.clear();
        syncPauseBacking();
        break;
      case "START_FAIL":
      case "UPLOAD_FAIL":
        setPhase("IDLE");
        break;
      case "PAUSE_USER":
        machine.pauseReasons.add("user");
        syncPauseBacking();
        break;
      case "RESUME_USER":
        machine.pauseReasons.delete("user");
        syncPauseBacking();
        break;
      case "PAUSE_SYSTEM":
        machine.pauseReasons.add("system");
        syncPauseBacking();
        break;
      case "RESUME_SYSTEM":
        machine.pauseReasons.delete("system");
        syncPauseBacking();
        break;
      case "STEP":
        setPhase("STEPPING");
        break;
      case "STEP_DONE":
        setPhase("ACTIVE");
        break;
      case "STOP":
        bumpEpoch();
        setPhase("STOPPING");
        break;
      case "STOP_DONE":
        machine.pauseReasons.clear();
        machine.device.hasSession = false;
        machine.cache.identityBound = false;
        setPhase("IDLE");
        syncPauseBacking();
        break;
      case "RESTORE_BEGIN":
        bumpEpoch();
        setPhase("RESTORING");
        break;
      case "RESTORE_DONE":
        if (payload && typeof payload === "object") {
          machine.device.hasSession =
            !!payload.firmwareScrollActive ||
            !!payload.firmwareScrollPaused;
        }
        machine.cache.identityBound = deriveIdentityBound(payload);
        setPhase(machine.device.hasSession ? "ACTIVE" : "IDLE");
        break;
      case "FW_SYNC":
        applyFirmwareCursor(payload);
        break;
      case "TEXT_EDITED":
        machine.cache.identityBound = false;
        break;
      default:
        return false;
    }
    return true;
  }

  function snapshot() {
    return {
      state: machine.state,
      pauseReasons: new Set(machine.pauseReasons),
      epoch: machine.epoch,
      gen: Object.assign({}, machine.gen),
      device: Object.assign({}, machine.device),
      cache: Object.assign({}, machine.cache),
    };
  }

  return { dispatch, snapshot, token, isCurrent };
})();

const boundControls = new WeakMap();

function bindControls(selector, eventName, handler) {
  document.querySelectorAll(selector).forEach((el) => {
    const token = `${selector}:${eventName}`;
    let bound = boundControls.get(el);
    if (!bound) {
      bound = new Set();
      boundControls.set(el, bound);
    }
    if (bound.has(token)) return;
    bound.add(token);
    el.addEventListener(eventName, handler);
  });
}

function setClickHandlers(entries) {
  for (const [id, handler] of entries) {
    const el = $(id);
    if (el) el.onclick = handler;
  }
}
// Button press feedback
// Connection relationship:
// - Use event delegation to listen to all buttons, without the need for each module to handle the press animation separately.
// - Only the CSS class and short timer are changed, but the business status is not changed.
// - The button active/pressed style in styles.css is responsible for the final visual effect.
let buttonPressAnimationsReady = false;
const buttonPressStates = new WeakMap();
const activeButtonPointers = new Map();

function pressableButtonFromTarget(target) {
  const button = target?.closest?.("button");
  if (!button || button.disabled || button.getAttribute("aria-disabled") === "true") return null;
  return button;
}

function clearButtonPressTimers(state) {
  if (!state) return;
  if (state.releaseTimer) clearTimeout(state.releaseTimer);
  if (state.cleanupTimer) clearTimeout(state.cleanupTimer);
}

function startButtonPressAnimation(button) {
  if (!button) return;
  const existing = buttonPressStates.get(button);
  clearButtonPressTimers(existing);
  const state = {
    startedAt: performance.now(),
    releaseTimer: 0,
    cleanupTimer: 0,
  };
  buttonPressStates.set(button, state);
  button.classList.remove("is-releasing");
  button.classList.add("is-pressing");
}

function releaseButtonPressAnimation(button) {
  if (!button) return;
  const state = buttonPressStates.get(button);
  if (!state) {
    startButtonPressAnimation(button);
    return releaseButtonPressAnimation(button);
  }
  const elapsed = performance.now() - state.startedAt;
  const delay = Math.max(0, BUTTON_PRESS_DOWN_MS - elapsed);
  if (state.releaseTimer) clearTimeout(state.releaseTimer);
  state.releaseTimer = setTimeout(() => {
    button.classList.remove("is-pressing");
    button.classList.add("is-releasing");
    state.cleanupTimer = setTimeout(() => {
      button.classList.remove("is-releasing");
      if (buttonPressStates.get(button) === state) buttonPressStates.delete(button);
    }, BUTTON_PRESS_UP_MS);
  }, delay);
}

function cancelButtonPressAnimation(button) {
  if (!button) return;
  releaseButtonPressAnimation(button);
}

function initButtonPressAnimations() {
  if (buttonPressAnimationsReady) return;
  buttonPressAnimationsReady = true;
  document.addEventListener(
    "pointerdown",
    (ev) => {
      if (ev.button !== undefined && ev.button !== 0) return;
      const button = pressableButtonFromTarget(ev.target);
      if (!button) return;
      activeButtonPointers.set(ev.pointerId, button);
      startButtonPressAnimation(button);
      try {
        button.setPointerCapture?.(ev.pointerId);
      } catch (_) {}
    },
    {
      passive: true,
    },
  );
  document.addEventListener(
    "pointerup",
    (ev) => {
      const button = activeButtonPointers.get(ev.pointerId);
      if (!button) return;
      activeButtonPointers.delete(ev.pointerId);
      releaseButtonPressAnimation(button);
    },
    {
      passive: true,
    },
  );
  document.addEventListener(
    "pointercancel",
    (ev) => {
      const button = activeButtonPointers.get(ev.pointerId);
      if (!button) return;
      activeButtonPointers.delete(ev.pointerId);
      cancelButtonPressAnimation(button);
    },
    {
      passive: true,
    },
  );
  document.addEventListener("keydown", (ev) => {
    if (ev.repeat || (ev.key !== " " && ev.key !== "Enter")) return;
    const button = pressableButtonFromTarget(ev.target);
    if (button) startButtonPressAnimation(button);
  });
  document.addEventListener("keyup", (ev) => {
    if (ev.key !== " " && ev.key !== "Enter") return;
    const button = ev.target?.closest?.("button");
    if (button) releaseButtonPressAnimation(button);
  });
}
// Font loading
// Connection relationship:
// - ensureWebUiFontReady() waits for the GNU Unifont embedded font in styles.css.
// - bootstrapWebUi() waits for the first screen waterfall before it is revealed to avoid text flashing with fallback first.
// - observeWebUiFont() re-adds the font class to the dynamically generated node after the font status changes.
let uiFontObserverStarted = false;

function applyWebUiFont(root = document) {
  const nodes = [];
  if (root && root.nodeType === 1) nodes.push(root);
  const scope = root && root.querySelectorAll ? root : document;
  const selector = root === document ? "body, body *" : "*";
  scope.querySelectorAll(selector).forEach((el) => nodes.push(el));
  for (const el of nodes) {
    if (!el || el.id === "scroll-text") continue;
    el.style.setProperty("font-family", `"${UI_WEB_FONT_FAMILY}"`, "important");
  }
  applyTextScrollInputFont();
}
async function ensureWebUiFontReady() {
  document.documentElement.style.setProperty("--ui-font", `"${UI_WEB_FONT_FAMILY}"`);
  if (document.fonts && document.fonts.load) {
    try {
      await document.fonts.load(
        `16px "${UI_WEB_FONT_FAMILY}"`,
        "RinaChanBoard 网页字体 继续 暂停 发送 停止 清屏 370 LED こんにちは",
      );
      const loaded = document.fonts.check(
        `16px "${UI_WEB_FONT_FAMILY}"`,
        "RinaChanBoard 网页字体 继续 暂停 发送 停止 清屏 370 LED こんにちは",
      );
      document.documentElement.dataset.uiFontLoaded = loaded ? "true" : "false";
    } catch (err) {
      document.documentElement.dataset.uiFontLoaded = "false";
      console.warn("GNU Unifont WebUI font load failed", err);
    }
  }
  applyWebUiFont();
  // GNU Unifont affects the actual width and height of textarea characters, which must be remeasured after loading.
  // Otherwise the old height calculated with the fallback font or when the font was not loaded is retained (worst case
  // The page was display:none and scrollHeight=0, resulting in height:0px being unable to hold text).
  if (typeof autoResizePackedTextareas === "function") autoResizePackedTextareas();
  if (typeof autoResizeScrollTextInput === "function") autoResizeScrollTextInput();
}

function observeWebUiFont() {
  if (uiFontObserverStarted || !document.body || !window.MutationObserver) return;
  uiFontObserverStarted = true;
  new MutationObserver((records) => {
    for (const rec of records) {
      rec.addedNodes &&
        rec.addedNodes.forEach((node) => {
          if (node && node.nodeType === 1) applyWebUiFont(node);
        });
    }
  }).observe(document.body, {
    childList: true,
    subtree: true,
  });
}
// text scroll font model
// Connection relationship:
// - CSS Ark Pixel font only affects the appearance of the input box/preview text.
// - The ark12.json bitmap is used to actually generate the 370 LED scrolling frames.
// - ensureScrollFontsLoaded()/ensureArkPixelFontReady() delays loading of large resources to avoid slow startup.
// - buildTextGlyph()/buildTextScrollBitmap() consumes the data here when building the 6.4 timeline.
let textScrollBrowserFontLoading = null;

function applyTextScrollInputFont() {
  const el = document.getElementById("scroll-text");
  if (!el) return;
  document.documentElement.style.setProperty("--scroll-font", TEXT_SCROLL_FONT_STACK);
  el.style.setProperty("font-family", TEXT_SCROLL_FONT_STACK, "important");
  el.style.setProperty("font-size", "12px", "important");
  el.style.setProperty("line-height", "1.2", "important");
  el.style.setProperty("font-synthesis", "none", "important");
  el.style.setProperty("font-variant-emoji", "text", "important");
}

function ensureTextScrollBrowserFontReady() {
  applyTextScrollInputFont();
  if (textScrollBrowserFontLoading) return textScrollBrowserFontLoading;
  if (!(document.fonts && document.fonts.load)) {
    document.documentElement.dataset.scrollFontLoaded = "unsupported";
    return Promise.resolve(false);
  }
  const loadJobs = [
    document.fonts.load(`12px "${TEXT_SCROLL_FONT_FAMILY}"`, TEXT_SCROLL_BROWSER_FONT_SAMPLE),
  ];
  if (TEXT_SCROLL_FALLBACK_FONT_FAMILY && TEXT_SCROLL_BROWSER_FALLBACK_FONT_SAMPLE) {
    loadJobs.push(
      document.fonts.load(
        `12px "${TEXT_SCROLL_FALLBACK_FONT_FAMILY}"`,
        TEXT_SCROLL_BROWSER_FALLBACK_FONT_SAMPLE,
      ),
    );
  }
  textScrollBrowserFontLoading = Promise.all(loadJobs)
    .then(() => {
      const loadedBase = document.fonts.check(
        `12px "${TEXT_SCROLL_FONT_FAMILY}"`,
        TEXT_SCROLL_BROWSER_FONT_SAMPLE,
      );
      const loadedFallback =
        !TEXT_SCROLL_FALLBACK_FONT_FAMILY ||
        !TEXT_SCROLL_BROWSER_FALLBACK_FONT_SAMPLE ||
        document.fonts.check(
          `12px "${TEXT_SCROLL_FALLBACK_FONT_FAMILY}"`,
          TEXT_SCROLL_BROWSER_FALLBACK_FONT_SAMPLE,
        );
      const loaded = loadedBase && loadedFallback;
      document.documentElement.dataset.scrollFontLoaded = loaded ? "true" : "false";
      applyTextScrollInputFont();
      requestAnimationFrame(autoResizeScrollTextInput);
      return loaded;
    })
    .catch((err) => {
      document.documentElement.dataset.scrollFontLoaded = "false";
      console.warn("Ark Pixel 12px text-scroll textarea font load failed", err);
      applyTextScrollInputFont();
      return false;
    });
  return textScrollBrowserFontLoading;
}
const arkPixelFont = {
  ready: false,
  loading: null,
  error: "",
  glyphs: new Map(),
  ascent: 10,
  descent: 2,
  lineHeight: 12,
  defaultAdvance: 12,
  source: "",
};

function textScrollVerticalOffset() {
  return Math.min(
    Math.max(0, ROWS - 1),
    Math.max(0, Math.floor((ROWS - Math.max(1, arkPixelFont.lineHeight || 12)) / 2)) + 2,
  );
}

function codePointOfChar(ch) {
  return ch.codePointAt(0) || 0;
}

// Emoji format controllers (VS15/VS16 variant selectors, ZWJ connectors, skin color modifiers, tag characters).
// LED text scrolling adopts the model of "one font for each code point, the same width as Chinese characters". These control characters are
// ark12.json is stored as a zero-width placeholder; it is skipped directly before rendering to avoid tofu blocks in the emoji sequence.
function isEmojiFormatControl(cp) {
  return (
    (cp >= 0xfe00 && cp <= 0xfe0f) || // Variant selector VS15/VS16
    cp === 0x200d || // Zero-width connector ZWJ
    (cp >= 0x1f3fb && cp <= 0x1f3ff) || // emoji skin tone modifier
    (cp >= 0xe0000 && cp <= 0xe007f) // tag character
  );
}

function isTextScrollEmojiPresentationBase(cp) {
  return (
    cp === 0x00a9 ||
    cp === 0x00ae ||
    cp === 0x203c ||
    cp === 0x2049 ||
    cp === 0x2122 ||
    cp === 0x2139 ||
    (cp >= 0x2194 && cp <= 0x21aa) ||
    (cp >= 0x231a && cp <= 0x23ff) ||
    (cp >= 0x2460 && cp <= 0x24ff) ||
    (cp >= 0x25aa && cp <= 0x27bf) ||
    (cp >= 0x2934 && cp <= 0x2935) ||
    (cp >= 0x2b05 && cp <= 0x2b55) ||
    cp === 0x3030 ||
    cp === 0x303d ||
    cp === 0x3297 ||
    cp === 0x3299 ||
    (cp >= 0x1f000 && cp <= 0x1faff)
  );
}

function normalizeTextScrollEmojiPresentation(text) {
  const chars = Array.from(String(text ?? ""));
  const out = [];
  for (let i = 0; i < chars.length; i++) {
    const cp = codePointOfChar(chars[i]);
    if (cp >= 0xfe00 && cp <= 0xfe0f) {
      const prev = out[out.length - 1];
      if (prev && isTextScrollEmojiPresentationBase(codePointOfChar(prev))) out.push("\ufe0e");
      continue;
    }
    out.push(chars[i]);
    if (!isTextScrollEmojiPresentationBase(cp)) continue;
    const nextCp = codePointOfChar(chars[i + 1] || "");
    if (nextCp < 0xfe00 || nextCp > 0xfe0f) out.push("\ufe0e");
  }
  return out.join("");
}

function clearTextScrollCaches() {
  buildTextScrollBitmap.cacheKey = "";
  buildTextScrollBitmap.cache = null;
  buildTextGlyph.cache = new Map();
}
async function ensureArkPixelFontReady() {
  if (arkPixelFont.ready) return arkPixelFont;
  if (arkPixelFont.loading) return arkPixelFont.loading;
  // Allow the browser cache to satisfy this fetch. The URL carries a build-time
  // content hash (?v=<hash>) and the firmware serves it Cache-Control: immutable,
  // so a cache hit is correct and avoids re-streaming ~2.5MB out of LittleFS (the
  // main cause of "preparing scroll font" freezes / disconnects on refresh).
  arkPixelFont.loading = fetch(TEXT_SCROLL_FONT_RESOURCE, {
    cache: "force-cache",
  })
    .then(async (res) => {
      if (!res.ok)
        throw new Error(`${res.status} ${res.statusText || "font resource missing"}`.trim());
      return res.json();
    })
    .then((data) => loadArkPixelFontTable(data))
    .catch((err) => {
      arkPixelFont.error = err.message || String(err);
      arkPixelFont.ready = false;
      arkPixelFont.loading = null;
      throw err;
    });
  return arkPixelFont.loading;
}

function decodePackedGlyphRows(rowsHex, width) {
  if (!rowsHex) return [];
  const nibbles = Math.max(1, Math.ceil(Math.max(0, width) / 4));
  return String(rowsHex)
    .split("/")
    .map((rowHex) => {
      let bits = "";
      const clean = String(rowHex || "")
        .replace(/[^0-9a-fA-F]/g, "")
        .padStart(nibbles, "0")
        .slice(-nibbles);
      for (const ch of clean) bits += parseInt(ch, 16).toString(2).padStart(4, "0");
      return bits.slice(0, Math.max(0, width));
    });
}

function loadArkPixelFontTable(data) {
  if (!data || data.format !== "rina_ark_pixel_font_bitmap_v1")
    throw new Error("Ark Pixel bitmap table format mismatch");
  arkPixelFont.glyphs = new Map();
  const rows = Number(data.rows || data.lineHeight || 12);
  arkPixelFont.ascent = Number(data.ascent || 10);
  arkPixelFont.descent = Number(data.descent || Math.max(0, rows - arkPixelFont.ascent));
  arkPixelFont.lineHeight = rows;
  arkPixelFont.defaultAdvance = Number(data.defaultAdvance || 12);
  arkPixelFont.source = data.source || TEXT_SCROLL_FONT_RESOURCE;
  const glyphs = data.glyphs || {};
  for (const [cpHex, g] of Object.entries(glyphs)) {
    const cp = parseInt(cpHex, 16);
    if (!Number.isFinite(cp) || !g) continue;
    let packed = null;
    if (Array.isArray(g)) {
      const tupleWidth = Number(g[1] || 0);
      packed = {
        advance: g[0],
        width: tupleWidth,
        height: g[2],
        xOffset: g[3],
        yOffset: g[4],
        dstY: g[5],
        rows: decodePackedGlyphRows(g[6] || "", tupleWidth),
      };
    } else {
      packed = {
        ...g,
        rows: Array.isArray(g.rows)
          ? g.rows.map(String)
          : decodePackedGlyphRows(g.rowsHex || "", Number(g.width || 0)),
      };
    }
    const advanceValue = Number(packed.advance);
    const fallbackAdvance = Number(data.defaultAdvance || 12);
    arkPixelFont.glyphs.set(cp, {
      cp,
      advance: Number.isFinite(advanceValue)
        ? Math.max(0, advanceValue)
        : Math.max(1, fallbackAdvance),
      width: Math.max(0, Number(packed.width || 0)),
      height: Math.max(0, Number(packed.height || 0)),
      xOffset: Number(packed.xOffset || 0),
      yOffset: Number(packed.yOffset || 0),
      dstY: Number(packed.dstY || 0),
      rows: Array.isArray(packed.rows) ? packed.rows.map(String) : [],
    });
  }
  if (!arkPixelFont.glyphs.size) throw new Error("Ark Pixel bitmap table contains no glyphs");
  const requiredFusionGlyphs = [0x7136, 0x71c3, 0x6eda, 0x6efe];
  const missingFusionGlyphs = requiredFusionGlyphs.filter((cp) => !arkPixelFont.glyphs.has(cp));
  if (missingFusionGlyphs.length) {
    throw new Error(
      "Ark Pixel fusion bitmap table missing required patched glyphs: " +
        missingFusionGlyphs
          .map((cp) => "U+" + cp.toString(16).toUpperCase().padStart(4, "0"))
          .join(", "),
    );
  }
  arkPixelFont.ready = true;
  arkPixelFont.error = "";
  arkPixelFont.loading = null;
  clearTextScrollCaches();
  return arkPixelFont;
}

// General utility functions
// Connection relationship:
// - These functions do not have state and only do small transformations: DOM query, value clamping, frame encoding, logging, etc.
// - packedBytesToFrame()/packedFrameToHex() are the boundary between the browser bool[] frame and the 47-byte packed wire frame.
// - log()/renderLog() displays recent events on the debug page and is also reused by the API/upload process.
function $(id) {
  return document.getElementById(id);
}

function clamp(n, min, max) {
  return Math.max(min, Math.min(max, Number(n) || 0));
}

function clampBrightness(v) {
  return clamp(v, MIN_LED_BRIGHTNESS, MAX_LED_BRIGHTNESS);
}

function isScrollPlaybackValue(value) {
  return value === "scroll" || value === "scroll_paused" || value === "scroll_step";
}

function blankFrame() {
  return Array(TOTAL_LEDS).fill(false);
}

function cloneFrame(frame) {
  return frame.slice(0, TOTAL_LEDS).map(Boolean);
}

function onCount(frame) {
  let c = 0;
  for (const v of frame) if (v) c++;
  return c;
}

function firstLitFrameIndex(frames) {
  if (!Array.isArray(frames)) return 0;
  const index = frames.findIndex((frame) => onCount(frame) > 0);
  return index > 0 ? index : 0;
}

function rotateScrollTimelineToFirstLitFrame(frames) {
  const index = firstLitFrameIndex(frames);
  return index > 0 ? frames.slice(index).concat(frames.slice(0, index)) : frames;
}

function normalizeHexColor(v) {
  v = String(v || "").trim();
  if (!v.startsWith("#")) v = "#" + v;
  if (/^#[0-9a-fA-F]{6}$/.test(v)) return v.toLowerCase();
  return null;
}

function hexToRgb(hex) {
  hex = normalizeHexColor(hex) || "#000000";
  return {
    r: parseInt(hex.slice(1, 3), 16),
    g: parseInt(hex.slice(3, 5), 16),
    b: parseInt(hex.slice(5, 7), 16),
  };
}

// Packed "theoretical minimum frame" codec — the single frame wire format.
// 370 logical LEDs -> 47 bytes, packed LSB-first: LED i lives in byte (i>>3),
// bit mask (1 << (i & 7)). This matches the firmware "packed-lsb-first" encoding
// byte-for-byte; the last byte only uses 2 bits (LED 368/369), so it is <= 0x03.
// frameToUint8Array(frame) (defined below) is the canonical bool[] -> Uint8Array(47) encoder.
function packedBytesToFrame(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : Uint8Array.from(bytes || []);
  const frame = blankFrame();
  for (let i = 0; i < TOTAL_LEDS; i++) frame[i] = !!(b[i >> 3] & (1 << (i & 7)));
  return frame;
}

// bool[] -> 94 uppercase hex chars (47 packed bytes). Used for copy / textarea echo / debug.
function packedFrameToHex(frame) {
  const bytes = frameToUint8Array(frame);
  let out = "";
  for (let i = 0; i < PACKED_FRAME_BYTES; i++) out += bytes[i].toString(16).padStart(2, "0");
  return out.toUpperCase();
}

// Body transport encoding. The 47-byte packed frame stays the payload, but the ESP32
// synchronous WebServer exposes the POST body via arg("plain") as a String, which truncates
// at the first 0x00 byte (packed frames are mostly zeros). So frames travel base64-encoded
// in the body (base64 is ASCII, no NUL); the firmware base64-decodes back to raw 47 bytes.
function bytesToBase64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}
function packedFrameToBase64(frame) {
  return bytesToBase64(frameToUint8Array(frame));
}
// ArrayBuffer of the base64 ASCII text, ready to POST as the request body.
function frameBase64Body(frame) {
  return new TextEncoder().encode(packedFrameToBase64(frame)).buffer;
}

// 94 hex chars -> bool[] (strict). Used for embedded part frames and hex paste.
function hexToPackedFrame(hex) {
  const s = String(hex || "").replace(/\s+/g, "");
  if (!new RegExp(`^[0-9a-fA-F]{${PACKED_FRAME_HEX_CHARS}}$`).test(s))
    throw new Error(`packed frame 需要 ${PACKED_FRAME_HEX_CHARS} 个 hex 字符`);
  const bytes = new Uint8Array(PACKED_FRAME_BYTES);
  for (let i = 0; i < PACKED_FRAME_BYTES; i++) bytes[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return packedBytesToFrame(bytes);
}

// Normalize any frame-ish value (Uint8Array(47) / 47-number array / bool[]) to Uint8Array(47).
function toPackedBytes(frame) {
  if (frame instanceof Uint8Array && frame.length === PACKED_FRAME_BYTES) return frame;
  if (
    Array.isArray(frame) &&
    frame.length === PACKED_FRAME_BYTES &&
    frame.every((x) => Number.isInteger(x) && x >= 0 && x <= 255)
  ) {
    return Uint8Array.from(frame);
  }
  return frameToUint8Array(frame);
}

// Decode a saved face's packed frameBytes into a bool[] for browser-side preview / echo.
function faceFrame(face) {
  if (face && Array.isArray(face.frameBytes) && face.frameBytes.length === PACKED_FRAME_BYTES) {
    return packedBytesToFrame(face.frameBytes);
  }
  return blankFrame();
}

// Flexible paste parser (debug lab / import textareas): 94 hex chars, a 47-byte JSON
// array, or a 47-byte base64 string. Optional PACKED:/FRAME:/HEX:/BASE64: prefixes.
function parsePackedFrameText(text) {
  const s = String(text || "").trim();
  if (!s) throw new Error("packed frame 不能为空");
  if (/^\s*\[/.test(s)) {
    const arr = JSON.parse(s);
    if (
      !Array.isArray(arr) ||
      arr.length !== PACKED_FRAME_BYTES ||
      !arr.every((x) => Number.isInteger(Number(x)) && Number(x) >= 0 && Number(x) <= 255)
    ) {
      throw new Error(`packed frame JSON 数组必须是 ${PACKED_FRAME_BYTES} 个 0..255 字节`);
    }
    return packedBytesToFrame(arr.map((v) => Number(v) & 255));
  }
  let compact = s.replace(/\s+/g, "");
  const upper = compact.toUpperCase();
  if (upper.startsWith("PACKED:")) compact = compact.slice(7);
  else if (upper.startsWith("FRAME:")) compact = compact.slice(6);
  else if (upper.startsWith("HEX:")) compact = compact.slice(4);
  if (new RegExp(`^[0-9a-fA-F]{${PACKED_FRAME_HEX_CHARS}}$`).test(compact)) return hexToPackedFrame(compact);
  try {
    const bin = atob(compact.replace(/^BASE64:/i, ""));
    if (bin.length === PACKED_FRAME_BYTES) {
      const bytes = new Uint8Array(PACKED_FRAME_BYTES);
      for (let j = 0; j < PACKED_FRAME_BYTES; j++) bytes[j] = bin.charCodeAt(j) & 255;
      return packedBytesToFrame(bytes);
    }
  } catch (e) {}
  throw new Error(
    `packed frame 必须是 ${PACKED_FRAME_HEX_CHARS} 个 hex 字符、${PACKED_FRAME_BYTES}-byte JSON 数组或 ${PACKED_FRAME_BYTES}-byte base64`,
  );
}

function copyText(text) {
  if (navigator.clipboard && window.isSecureContext)
    navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
  else fallbackCopy(text);
}

function fallbackCopy(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  document.body.appendChild(ta);
  ta.select();
  document.execCommand("copy");
  ta.remove();
}

function log(msg, level = "info") {
  // Level filtering: High-frequency/redundant entries (such as dragging the slider) are recorded as "debug" and are discarded directly under the default level of info.
  // Not even warehousing and rendering will happen.
  const rank = LOG_LEVELS[level] ?? LOG_LEVELS.info;
  if (rank > logLevel) return;
  const line = `[${new Date().toLocaleTimeString()}] ${msg}`;
  logs.push(line);
  if (logs.length > LOG_BUFFER_MAX) logs.shift();
  renderLog();
}

function setLogLevel(level) {
  const next = LOG_LEVELS[level];
  if (next === undefined) return;
  logLevel = next;
  // Immediate re-rendering (actually writing the DOM only when 6.5 is visible).
  renderLog();
}

function renderLog() {
  // Only updates the DOM when the 6.5 (debug) page is visible. The #log on other pages is still in the DOM, but cannot be seen by the user.
  // So here we only mark dirty and skip expensive string reconstruction + reflow; switchPage("debug") will make up for the rendering.
  if (document.body?.dataset?.page !== "debug") {
    logDirty = true;
    return;
  }
  // Merge by animation frame: Multiple logs within one frame only trigger one DOM update.
  if (logRenderRaf) return;
  logRenderRaf = requestAnimationFrame(() => {
    logRenderRaf = 0;
    logDirty = false;
    const el = $("log");
    if (!el) return;
    // Only render the most recent LOG_VIEW_MAX lines to avoid splicing the entire text each time when the buffer approaches 500 lines.
    const view = logs.length > LOG_VIEW_MAX ? logs.slice(-LOG_VIEW_MAX) : logs;
    el.textContent = view.join("\n");
    el.scrollTop = el.scrollHeight;
  });
}

function isOfflineHtmlMode() {
  return location.protocol === "file:" || location.origin === "null";
}

function setFirmwareStatus(patch) {
  Object.assign(firmware, patch || {});
  if (typeof renderState === "function") renderState();
}

function isScrollPageActive() {
  return document.body?.dataset?.page === "scroll";
}

function apiUrl(path) {
  const p = String(path || "");
  if (/^https?:\/\//i.test(p)) return p;
  if (isOfflineHtmlMode()) {
    // file:// has no access to ESP32's relative API. Leave these calls as no-op failures,
    // In this way, after the user imports or opens saved_faces.json, the HTML can still be used offline.
    return null;
  }
  return p.startsWith("/") ? p : "/" + p;
}
// Firmware API Client
// Connection relationship:
// - apiGet()/apiPost() is the only entry point for all firmware HTTP communications.
// - The upper module only transmits endpoint and payload; here, timeout, error handling and offline mode judgment are unified.
// - apiPostWithUploadProgress() specifically serves large scroll timeline uploads in 6.4.
async function apiGet(path, options = {}) {
  const url = apiUrl(path);
  firmware.lastRequest = `GET ${path}`;
  renderState();
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = "offline html mode";
    firmware.lastError = `offline: ${path}`;
    throw new Error(`offline html mode: ${path}`);
  }
  const timeoutMs = options.timeoutMs || API_GET_TIMEOUT_MS;
  const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const res = await fetch(url, {
      method: "GET",
      cache: "no-store",
      headers: {
        Accept: "application/json",
      },
      signal: controller?.signal,
    });
    firmware.online = res.ok;
    firmware.lastStatus = `${res.status} ${res.statusText || ""}`.trim();
    if (!res.ok) {
      firmware.lastError = firmware.lastStatus;
      throw new Error(firmware.lastStatus);
    }
    const text = await res.text();
    return parseApiJson(text, path, {});
  } catch (err) {
    const message =
      err?.name === "AbortError"
        ? `GET ${path} timeout after ${timeoutMs}ms`
        : err.message || String(err);
    firmware.online = false;
    firmware.lastError = message;
    throw new Error(message);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}
async function apiPost(path, payload, options = {}) {
  const url = apiUrl(path);
  const silent = options.silent === true;
  const expectJson = options.expectJson !== false;
  const isBinary = payload instanceof ArrayBuffer;

  if (!silent) {
    firmware.lastRequest = `POST ${path}`;
    renderState();
  }
  if (!url) {
    if (!silent) {
      firmware.online = false;
      firmware.lastStatus = "offline html mode";
      firmware.lastError = `offline: ${path}`;
    }
    throw new Error(`offline html mode: ${path}`);
  }
  const timeoutMs = options.timeoutMs || API_POST_TIMEOUT_MS;
  const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const headers = {};
    if (isBinary) {
      headers["Content-Type"] = "application/octet-stream";
    } else {
      headers["Content-Type"] = "application/json";
      headers["Accept"] = "application/json";
    }

    const res = await fetch(url, {
      method: "POST",
      headers,
      body: isBinary ? payload : JSON.stringify(payload || {}),
      signal: controller?.signal,
    });
    firmware.online = res.ok;
    if (!silent) {
      firmware.lastStatus = `${res.status} ${res.statusText || ""}`.trim();
    }
    if (!res.ok) {
      if (!silent) {
        firmware.lastError = firmware.lastStatus;
      }
      throw new Error(res.statusText || String(res.status));
    }
    if (expectJson && res.status !== 204) {
      const text = await res.text();
      return parseApiJson(text, path, {
        ok: true,
      });
    }
    return null;
  } catch (err) {
    const message =
      err?.name === "AbortError"
        ? `POST ${path} timeout after ${timeoutMs}ms`
        : err.message || String(err);
    if (!silent) {
      firmware.online = false;
      firmware.lastError = message;
    }
    throw new Error(message);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

// Scroll timeline upload. Frames are sent as a single packed binary body (N * 47 bytes,
// application/octet-stream) and all metadata travels in the query string, matching the
// firmware /api/scroll handler which parses the body as raw packed frames.
function apiPostWithUploadProgress(path, payload, onProgress = () => {}) {
  payload = payload || {};
  const base = apiUrl(path);
  firmware.lastRequest = `POST ${path}`;
  setFirmwareStatus({
    lastRequest: firmware.lastRequest,
    lastStatus: "uploading",
  });
  if (!base) {
    firmware.online = false;
    firmware.lastStatus = "offline html mode";
    firmware.lastError = `offline: ${path}`;
    return Promise.reject(new Error(`offline html mode: ${path}`));
  }
  // Concatenate frames into one packed buffer (N * 47 bytes), then base64-encode it for the
  // body. The firmware base64-decodes it back to raw packed frames (arg("plain") cannot carry 0x00).
  const frames = Array.isArray(payload.frames) ? payload.frames : [];
  const raw = new Uint8Array(frames.length * PACKED_FRAME_BYTES);
  for (let i = 0; i < frames.length; i++) raw.set(toPackedBytes(frames[i]), i * PACKED_FRAME_BYTES);
  const body = new TextEncoder().encode(bytesToBase64(raw));
  // Metadata -> query string (the binary body cannot carry form/JSON fields).
  const params = new URLSearchParams();
  const addParam = (k, v) => {
    if (v !== undefined && v !== null && v !== "") params.append(k, String(v));
  };
  addParam("append", payload.append ? 1 : 0);
  addParam("start", payload.start ? 1 : 0);
  addParam("intervalMs", payload.intervalMs);
  addParam("fps", payload.fps);
  addParam("chunkIndex", payload.chunkIndex);
  addParam("totalFrames", payload.totalFrames);
  addParam("source", payload.source);
  addParam("timelineId", payload.timelineId);
  addParam("fontId", payload.fontId);
  addParam("generatorVersion", payload.generatorVersion);
  const url = base + "?" + params.toString();
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", url, true);
    xhr.timeout = API_UPLOAD_TIMEOUT_MS;
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.setRequestHeader("Accept", "application/json");
    xhr.upload.onprogress = (ev) => {
      if (ev.lengthComputable && ev.total > 0) onProgress(ev.loaded / ev.total);
    };
    xhr.onload = () => {
      firmware.online = xhr.status >= 200 && xhr.status < 300;
      firmware.lastStatus = `${xhr.status} ${xhr.statusText || ""}`.trim();
      if (!firmware.online) {
        const text = String(xhr.responseText || "").trim();
        let detail = "";
        if (text) {
          try {
            const parsed = parseApiJson(text, path, {});
            detail = parsed.error || parsed.message || text.slice(0, 180);
          } catch (_err) {
            detail = text.slice(0, 180);
          }
        }
        firmware.lastError = detail ? `${firmware.lastStatus}: ${detail}` : firmware.lastStatus;
        reject(new Error(firmware.lastError));
        return;
      }
      try {
        resolve(
          parseApiJson(xhr.responseText, path, {
            ok: true,
          }),
        );
      } catch (err) {
        firmware.lastError = err.message;
        reject(err);
      }
    };
    xhr.onerror = () => {
      firmware.online = false;
      firmware.lastStatus = "network error";
      firmware.lastError = `POST ${path} failed (readyState ${xhr.readyState}, status ${xhr.status || 0})`;
      reject(new Error(firmware.lastError));
    };
    xhr.ontimeout = () => {
      firmware.online = false;
      firmware.lastStatus = "timeout";
      firmware.lastError = `POST ${path} timeout after ${API_UPLOAD_TIMEOUT_MS}ms`;
      reject(new Error(firmware.lastError));
    };
    xhr.send(body.buffer);
  });
}

function shouldLogApiError() {
  const now = performance.now();
  if (now - lastApiErrorLogAt > 2500) {
    lastApiErrorLogAt = now;
    return true;
  }
  return false;
}

// Power and firmware status synchronization
// Connection relationship:
// - applyFirmwareRuntimeState() merges /api/status return value into state, firmware and scroll.
// - renderState()/renderMatrices() then reads these states and updates the UI.
// - The scroll stop event will trigger a more complete synchronization to ensure that firmware button operations can return to the WebUI.
function finitePowerNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function powerIconClass(value, fallback = "status-dot dim") {
  const text = String(value || "").trim();
  return /^status-dot( (dim|warn|danger))?$/.test(text) ? text : fallback;
}

function powerIconColor(value, fallback = "#9aa6b2") {
  const text = String(value || "").trim();
  return /^#[0-9a-fA-F]{6}$/.test(text) ? text : fallback;
}

function batteryIconForPercent(powered, percent) {
  if (!powered)
    return {
      cls: "status-dot dim",
      color: "#9aa6b2",
    };
  const pct = finitePowerNumber(percent);
  if (pct !== null && pct < 10)
    return {
      cls: "status-dot danger",
      color: "#ef4444",
    };
  if (pct !== null && pct < 30)
    return {
      cls: "status-dot warn",
      color: "#f59e0b",
    };
  return {
    cls: "status-dot",
    color: "#59d98e",
  };
}

function setPowerStateField(key, value) {
  if (state[key] === value) return false;
  state[key] = value;
  return true;
}

function setFinitePowerField(key, value) {
  const n = finitePowerNumber(value);
  if (n === null) return false;
  return setPowerStateField(key, n);
}

function applyPowerData(powerData) {
  if (!powerData || typeof powerData !== "object") return false;
  let stateChanged = false;
  state.lastPowerSyncAt = Date.now();
  const batteryValid = powerData.batteryValid !== false;
  const chargeValid = powerData.chargeValid !== false;
  const batteryPowered = powerData.batteryPowered !== false;
  const vbat = finitePowerNumber(powerData.vbat);
  const pct = finitePowerNumber(powerData.batteryPercent);
  const vcharge = finitePowerNumber(powerData.vcharge);
  if (typeof powerData.batteryPowered === "boolean")
    stateChanged = setPowerStateField("batteryPowered", batteryPowered) || stateChanged;
  if (typeof powerData.batteryDisconnected === "boolean")
    stateChanged =
      setPowerStateField("batteryDisconnected", powerData.batteryDisconnected) || stateChanged;
  if (typeof powerData.batteryLowVoltageUnpowered === "boolean")
    stateChanged =
      setPowerStateField("batteryLowVoltageUnpowered", powerData.batteryLowVoltageUnpowered) ||
      stateChanged;
  if (typeof powerData.batteryStateText === "string" && powerData.batteryStateText)
    stateChanged =
      setPowerStateField("batteryStateText", powerData.batteryStateText) || stateChanged;
  stateChanged = setFinitePowerField("batteryMinV", powerData.batteryRangeMin) || stateChanged;
  stateChanged = setFinitePowerField("batteryMaxV", powerData.batteryRangeMax) || stateChanged;
  stateChanged =
    setFinitePowerField("batteryNominalMin", powerData.batteryNominalMin) || stateChanged;
  stateChanged =
    setFinitePowerField("batteryNominalMax", powerData.batteryNominalMax) || stateChanged;
  stateChanged = setFinitePowerField("batteryAdcMv", powerData.batteryAdcMv) || stateChanged;
  stateChanged =
    setFinitePowerField("batteryPrevAdcMv", powerData.batteryPrevAdcMv) || stateChanged;
  stateChanged =
    setFinitePowerField("batteryDisconnectDropMv", powerData.batteryDisconnectDropMv) ||
    stateChanged;
  stateChanged =
    setFinitePowerField(
      "batteryDisconnectDropThresholdMv",
      powerData.batteryDisconnectDropThresholdMv,
    ) || stateChanged;
  stateChanged =
    setFinitePowerField("batteryDisconnectLowThresholdMv", powerData.batteryDisconnectLowThresholdMv) ||
    stateChanged;
  stateChanged =
    setFinitePowerField("batteryReconnectThresholdMv", powerData.batteryReconnectThresholdMv) ||
    stateChanged;
  stateChanged =
    setFinitePowerField("batteryUnpoweredLowThreshold", powerData.batteryUnpoweredLowThreshold) ||
    stateChanged;
  stateChanged =
    setFinitePowerField("batteryLastInstantVbat", powerData.batteryLastInstantVbat) || stateChanged;
  stateChanged = setFinitePowerField("chargeAdcMv", powerData.chargeAdcMv) || stateChanged;
  if (batteryValid) {
    if (batteryPowered) {
      if (vbat !== null) {
        state.batteryV = vbat;
        stateChanged = true;
      }
      if (pct !== null) {
        state.batteryPercent = pct;
        stateChanged = true;
      }
    } else {
      if (state.batteryV !== 0 || state.batteryPercent !== 0) {
        state.batteryV = 0;
        state.batteryPercent = 0;
        stateChanged = true;
      }
    }
  } else {
    if (state.batteryV !== null || state.batteryPercent !== null) {
      state.batteryV = null;
      state.batteryPercent = null;
      stateChanged = true;
    }
  }
  if (chargeValid) {
    if (vcharge !== null) {
      state.chargeV = vcharge;
      stateChanged = true;
    }
    if (typeof powerData.charging === "boolean") {
      state.charging = powerData.charging;
      stateChanged = true;
    }
  } else {
    if (state.chargeV !== null || state.charging !== null) {
      state.chargeV = null;
      state.charging = null;
      stateChanged = true;
    }
  }
  const nextBatteryIconClass = powerIconClass(powerData.batteryIconClass);
  if (state.batteryIconClass !== nextBatteryIconClass) {
    state.batteryIconClass = nextBatteryIconClass;
    stateChanged = true;
  }
  const nextBatteryIconColor = powerIconColor(powerData.batteryIconColor);
  if (state.batteryIconColor !== nextBatteryIconColor) {
    state.batteryIconColor = nextBatteryIconColor;
    stateChanged = true;
  }
  const nextChargeIconClass = powerIconClass(powerData.chargeIconClass);
  if (state.chargeIconClass !== nextChargeIconClass) {
    state.chargeIconClass = nextChargeIconClass;
    stateChanged = true;
  }
  const nextChargeIconColor = powerIconColor(powerData.chargeIconColor);
  if (state.chargeIconColor !== nextChargeIconColor) {
    state.chargeIconColor = nextChargeIconColor;
    stateChanged = true;
  }
  return stateChanged;
}

function shouldApplyPowerFromStatusSource(source) {
  return (
    source === "page_load" ||
    source === "firmware_ping" ||
    String(source || "").startsWith("power_") ||
    String(source || "").startsWith("basic_")
  );
}

function scrollStopEventFromStatus(data, renderer) {
  const event = renderer?.scrollStopEvent || data?.scrollStopEvent || null;
  if (!event || typeof event !== "object") return null;
  const seq = Number(event.seq || 0);
  if (!Number.isFinite(seq) || seq <= 0) return null;
  return {
    seq,
    ms: Number(event.ms || 0),
    button: String(event.button || "").toUpperCase(),
    source: String(event.source || ""),
    reason: String(event.reason || ""),
  };
}

function firmwareStatusShowsTextScroll(data, renderer = data?.renderer || data || {}) {
  // Hardware -> WebUI text-scroll recovery is allowed only while the LED panel is
  // actually showing firmware text scroll. Running and paused scroll both count;
  // stale playback strings, cached frame counts, or old sourceText metadata do not.
  const explicitDisplaying = renderer?.firmwareScrollDisplaying ?? data?.firmwareScrollDisplaying;
  if (typeof explicitDisplaying === "boolean") return explicitDisplaying;
  return Boolean(
    renderer?.firmwareScrollActive ||
      data?.firmwareScrollActive ||
      renderer?.firmwareScrollPaused ||
      data?.firmwareScrollPaused
  );
}

function clearRecoveredScrollCache(reason = "scroll_cache_cleared") {
  pendingScrollMeta = null;
  scroll.restoredSourceText = "";
  scroll.restoredFromFirmwareMeta = false;
  scroll.restoreWarning = "";
  scroll.restoredTextTruncated = false;
  lastFwScrollFrameCount = 0;
  lastFwScrollTimelineId = "";
  lastFwScrollHasSourceText = false;
  lastFwScrollDisplaying = false;
  lastScrollRestoreStatusDebugKey = "";
  logScrollRestoreDebug("cache cleared", { reason });
}

function scheduleFirmwareScrollStopFullSync(
  source = "firmware_scroll_stop_full_status",
  delayMs = SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS,
) {
  if (isOfflineHtmlMode()) return;
  if (firmwareScrollStopFullSyncTimer) clearTimeout(firmwareScrollStopFullSyncTimer);
  firmwareScrollStopFullSyncTimer = setTimeout(
    () => {
      firmwareScrollStopFullSyncTimer = null;
      syncRuntimeStateFromFirmware(source);
    },
    Math.max(0, Number(delayMs) || 0),
  );
}

function applyFirmwareRuntimeState(data, source = "firmware_status", options = {}) {
  if (!data || typeof data !== "object") return;
  // P1-5: learn the firmware's UTF-8 byte limit for scroll source text from full status.
  if (data.scrollLimits) {
    const mtb = Number(data.scrollLimits.maxTextBytes);
    if (Number.isFinite(mtb) && mtb > 0) firmwareScrollMaxTextBytes = mtb;
  }
  const skipFrame = !!options.skipFrame;
  const renderer = data.renderer || data;
  let stateChanged = false;
  let faceChanged = false;
  let frameChanged = false;
  const wasScrollBeforeFirmwareSync =
    state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback);

  if (data.ap?.ip) {
    state.apIp = data.ap.ip;
    state.apIpSource = "Firmware";
    state.lastNetworkSyncAt = Date.now();
    stateChanged = true;
  }
  if (data.ap?.domain) {
    state.apDomain = data.ap.domain;
    state.apDomainSource = "Firmware";
    state.lastNetworkSyncAt = Date.now();
    stateChanged = true;
  }
  // Any successful merge of firmware status updates the sync timestamp (page-debug override).
  firmwareLastSyncAt = Date.now();
  state.lastStatusSyncAt = firmwareLastSyncAt;

  const nestedPowerPayload = data.power && typeof data.power === "object" ? data.power : null;
  const flatPowerPayload =
    data.vbat !== undefined ||
    data.batteryPercent !== undefined ||
    data.vcharge !== undefined ||
    data.charging !== undefined
      ? data
      : null;
  const powerPayload = nestedPowerPayload || flatPowerPayload;
  if (powerPayload && (nestedPowerPayload || shouldApplyPowerFromStatusSource(source))) {
    stateChanged = applyPowerData(powerPayload) || stateChanged;
  }

  const modeValue = renderer.mode ?? data.mode;
  if (modeValue) {
    const nextMode = isAutoModeValue(modeValue) ? "auto" : "manual";
    if (state.mode !== nextMode) {
      state.mode = nextMode;
      stateChanged = true;
    }
  }

  const intervalValue = Number(renderer.autoIntervalMs ?? data.autoIntervalMs);
  if (Number.isFinite(intervalValue)) {
    const nextInterval = normalizeAutoIntervalMs(intervalValue);
    if (state.autoInterval !== nextInterval) {
      state.autoInterval = nextInterval;
      stateChanged = true;
    }
  }

  if (typeof renderer.restoreAutoAfterScroll === "boolean") {
    state.restoreAutoAfterScroll = renderer.restoreAutoAfterScroll;
  }

  const playbackValue = renderer.playback ?? data.playback;
  if (typeof playbackValue === "string" && playbackValue) {
    state.playback = playbackValue;
    const firmwareScrollActive = Boolean(
      renderer.firmwareScrollActive ?? data.firmwareScrollActive,
    );
    const firmwareScrollPaused = Boolean(
      renderer.firmwareScrollPaused ?? data.firmwareScrollPaused,
    );
    const hasSplitPauseFlags =
      typeof renderer.firmwareScrollUserPaused === "boolean" ||
      typeof data.firmwareScrollUserPaused === "boolean" ||
      typeof renderer.firmwareScrollSystemPaused === "boolean" ||
      typeof data.firmwareScrollSystemPaused === "boolean";
    const firmwareScrollUserPaused = Boolean(
      renderer.firmwareScrollUserPaused ?? data.firmwareScrollUserPaused,
    );
    const firmwareScrollSystemPaused = Boolean(
      renderer.firmwareScrollSystemPaused ?? data.firmwareScrollSystemPaused,
    );
    const firmwareDisplayingScroll = firmwareScrollActive || firmwareScrollPaused;
    scroll.firmwareBacked = firmwareDisplayingScroll;
    const playbackIsScroll = firmwareDisplayingScroll && isScrollPlaybackValue(playbackValue);
    if (hasSplitPauseFlags) {
      scroll.userPaused = firmwareScrollUserPaused;
      scroll.systemPaused = firmwareScrollSystemPaused;
    } else {
      const effectivelyPaused = playbackValue === "scroll_paused" || firmwareScrollPaused;
      if (effectivelyPaused) {
        scroll.systemPaused = !scroll.userPaused;
      } else {
        scroll.userPaused = false;
        scroll.systemPaused = false;
      }
    }
    scroll.paused =
      scroll.userPaused ||
      scroll.systemPaused ||
      playbackValue === "scroll_paused" ||
      firmwareScrollPaused;
    scroll.active = playbackValue === "scroll" && !scroll.paused;
    state.textScrollActive = firmwareDisplayingScroll;
    if (!firmwareDisplayingScroll) {
      scroll.active = false;
      scroll.paused = false;
      scroll.userPaused = false;
      scroll.systemPaused = false;
      scroll.firmwareBacked = false;
      state.textScrollActive = false;
      if (isScrollPlaybackValue(state.playback)) state.playback = "idle";
    }
    stateChanged = true;
  }

  const scrollMaxFramesValue = Number(renderer.scrollMaxFrames ?? data.scrollMaxFrames);
  if (Number.isFinite(scrollMaxFramesValue) && scrollMaxFramesValue > 0) {
    firmwareScrollMaxFrames = Math.floor(scrollMaxFramesValue);
  }

  const scrollFrameCountValue = Number(renderer.scrollFrameCount ?? data.scrollFrameCount);
  if (Number.isFinite(scrollFrameCountValue)) {
    const displayingForFrameCount =
      firmwareStatusShowsTextScroll(data, renderer);
    lastFwScrollFrameCount = displayingForFrameCount
      ? Math.max(0, Math.floor(scrollFrameCountValue))
      : 0;
  }
  if (
    Number.isFinite(scrollFrameCountValue) &&
    scrollFrameCountValue === 0 &&
    !isScrollPlaybackValue(state.playback)
  ) {
    scroll.firmwareBacked = false;
  }
  if (firmwareStatusShowsTextScroll(data, renderer)) {
    applyFirmwareScrollFps(renderer, source);
  }
  scrollMachine.dispatch("FW_SYNC", renderer);

  const brightnessValue = Number(renderer.brightness ?? data.brightness);
  if (Number.isFinite(brightnessValue)) {
    const nextBrightness = clampBrightness(brightnessValue);
    state.defaultBrightness = clampBrightness(
      Number(renderer.brightnessDefault ?? data.brightnessDefault ?? DEFAULT_LED_BRIGHTNESS),
    );
    if (state.brightness !== nextBrightness) {
      if (Date.now() - lastUserBrightnessMs < 2000) {
        // Skip stale firmware echoes during active sliding
      } else {
        state.brightness = nextBrightness;
        if ($("brightness-range")) $("brightness-range").value = state.brightness;
        if ($("brightness-input")) $("brightness-input").value = state.brightness;
        updateDps();
        stateChanged = true;
      }
    }
  }

  const firmwareColor = normalizeHexColor(renderer.color ?? data.color);
  if (firmwareColor) {
    setColor(firmwareColor, "firmware_sync");
  }

  const faceIndexValue = Number(renderer.autoFaceIndex ?? data.autoFaceIndex);
  if (Number.isFinite(faceIndexValue)) {
    const library = getAllFaces();
    const maxIndex = Math.max(0, library.length - 1);
    const nextFaceIndex = clamp(faceIndexValue, 0, maxIndex);
    if (state.faceIndex !== nextFaceIndex) {
      state.faceIndex = nextFaceIndex;
      stateChanged = true;
      faceChanged = true;
    }
  }

  const firmwareIsScrolling = firmwareStatusShowsTextScroll(data, renderer);
  // The firmware status JSON does not echo the raw frame. When it reports a new face
  // index, re-derive the WebUI preview locally by decoding that saved face's packed
  // frameBytes (browser-side decode of the theoretical-minimum frame).
  if (!skipFrame && !firmwareIsScrolling && faceChanged) {
    const face = getAllFaces()[state.faceIndex];
    if (face) {
      currentFrame = faceFrame(face);
      if (liveSendEnabled) syncLiveSendBaseline(currentFrame);
      scrollFrame = cloneFrame(currentFrame);
      state.lastRefreshReason = renderer.lastReason || data.lastReason || source;
      frameChanged = true;
      stateChanged = true;
    }
  }

  syncAutoIntervalUi();
  if (faceChanged) renderSavedFaces();
  if (frameChanged) {
    renderMatrices();
    updatePackedFrameViews();
  }

  const firmwareReason = String(renderer.lastReason || data.lastReason || "");
  const event = scrollStopEventFromStatus(data, renderer);
  const newButtonStopEvent =
    !!event &&
    event.seq > lastScrollStopEventSeq &&
    event.source === "gpio" &&
    ["B1", "B2", "B3"].includes(event.button);
  if (event && event.seq > lastScrollStopEventSeq) lastScrollStopEventSeq = event.seq;

  const fallbackButtonStop =
    wasScrollBeforeFirmwareSync &&
    firmwareReason.startsWith("gpio_") &&
    /(^|_)B[123](_|$)/.test(firmwareReason);
  const stoppedAfterScroll =
    wasScrollBeforeFirmwareSync && !state.textScrollActive && !scroll.firmwareBacked;
  const shouldStopScrollPreview =
    isScrollPageActive() &&
    !scroll.uploading &&
    !scroll.startBusy &&
    !scroll.restoring &&
    String(source).startsWith("firmware_poll") &&
    (newButtonStopEvent || stoppedAfterScroll || fallbackButtonStop);

  if (shouldStopScrollPreview) {
    const hasCurrentFacePreview = frameChanged && !state.textScrollActive && !scroll.firmwareBacked;
    resetScrollControlsAfterButton(
      newButtonStopEvent ? `firmware_gpio_${event.button}` : "firmware_gpio_button",
      {
        preserveCurrentFrame: hasCurrentFacePreview,
      },
    );
    if (!hasCurrentFacePreview) {
      const delay = renderer.deferredFaceRestoreActive ? SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS : 20;
      scheduleFirmwareScrollStopFullSync("firmware_poll_scroll_stop_full_status", delay);
    }
  }

  const fwScrollTimelineId = String(renderer.scrollTimelineId ?? data.scrollTimelineId ?? "");
  const fwScrollHasSourceText = Boolean(renderer.scrollHasSourceText ?? data.scrollHasSourceText);
  const fwScrollUploadComplete = Boolean(
    renderer.scrollUploadComplete ?? data.scrollUploadComplete,
  );
  const fwScrollDisplaying = firmwareStatusShowsTextScroll(data, renderer);
  if (renderer.scrollTimelineId !== undefined || data.scrollTimelineId !== undefined) {
    lastFwScrollDisplaying = fwScrollDisplaying;
    lastFwScrollTimelineId = fwScrollDisplaying ? fwScrollTimelineId : "";
    lastFwScrollHasSourceText = fwScrollDisplaying && fwScrollHasSourceText;
    if (!fwScrollDisplaying) {
      lastFwScrollFrameCount = 0;
    }
    const debugKey = `${fwScrollDisplaying}|${lastFwScrollTimelineId}|${lastFwScrollHasSourceText}|${fwScrollUploadComplete}`;
    if (debugKey !== lastScrollRestoreStatusDebugKey) {
      lastScrollRestoreStatusDebugKey = debugKey;
      logScrollRestoreDebug("status fields", {
        source,
        scrollDisplaying: fwScrollDisplaying,
        scrollTimelineId: lastFwScrollTimelineId,
        scrollUploadComplete: fwScrollDisplaying && fwScrollUploadComplete,
        scrollHasSourceText: lastFwScrollHasSourceText,
      });
    }
  }
  // P0-3: Previously, detecting a firmware timeline that differs from the WebUI's here
  // would AUTOMATICALLY fetch sourceText and regenerate the full preview from the poll
  // path -- exactly the heavy work that froze the WebUI / stressed the board on refresh.
  // That auto-restore is now removed; instead, when the firmware is displaying
  // recoverable scroll text the WebUI hasn't reproduced, we just keep the manual
  // "restore from firmware" button visible (see shouldShowScrollRestoreButton). The
  // user triggers the heavy restore deliberately.
  if (
    scrollMetaRestoreEnabled &&
    fwScrollDisplaying &&
    fwScrollTimelineId &&
    fwScrollHasSourceText &&
    fwScrollTimelineId !== scroll.timelineId &&
    isScrollPageActive()
  ) {
    updateScrollUi();
  }
  if (stateChanged) renderState();
}

// Firmware command queue
// Connection relationship:
// - UI high-frequency operations will not directly hit the firmware, but will enter the button/frame two queues.
// - pumpButtonCommandQueue() handles lightweight commands such as mode, button, stop/pause, etc.
// - pumpFrameSendQueue() processes 370 LED frames and limits the current according to the rhythm of WEBUI_CONFIG.
// - guardBeforeOutput()/terminateOtherActivities() ensures static/auto/scroll modes are mutually exclusive.
let auxCommandInFlightCount = 0;

function waitForAuxCommandsIdle(timeoutMs = 500) {
  const startedAt = performance.now();
  return new Promise((resolve) => {
    const check = () => {
      if (auxCommandInFlightCount <= 0) {
        resolve(true);
        return;
      }
      if (performance.now() - startedAt >= timeoutMs) {
        resolve(false);
        return;
      }
      setTimeout(check, 16);
    };
    check();
  });
}

function sendAuxCommand(cmd, payload = {}, source = "webui") {
  firmware.sentCommands++;
  const packet = {
    cmd,
    payload,
  };
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.command}`,
    lastStatus: isOfflineHtmlMode() ? "queued offline" : "queued",
  });
  auxCommandInFlightCount++;
  packet.promise = apiPost(API_ENDPOINTS.command, packet)
    .then((data) => {
      applyFirmwareRuntimeState(data, source);
      return data;
    })
    .catch((err) => {
      setFirmwareStatus({
        lastStatus: isOfflineHtmlMode() ? "offline html mode" : "command failed",
        lastError: err.message,
      });
      if (!isOfflineHtmlMode() && shouldLogApiError()) log(`辅助指令发送失败: ${err.message}`, "error");
    })
    .finally(() => {
      auxCommandInFlightCount = Math.max(0, auxCommandInFlightCount - 1);
    });
  return packet;
}

// NOTE: The dedicated low-latency "live" frame pump (liveFramePump) did not reliably
// refresh the physical LED strip on device, while the standard queued pump (the path the
// manual 发送 button uses) always works. So real-time edit frames are routed through the
// standard normalFramePump too. Kept as a function (always false) so the routing call sites
// and the live pump definition stay intact and easy to re-enable if the live path is fixed.
function isLiveFrameReason(reason) {
  return false;
}

function frameToUint8Array(frame) {
  const bytes = new Uint8Array(47);
  for (let i = 0; i < TOTAL_LEDS; i++) {
    if (frame[i]) {
      const byteIdx = i >> 3;
      const bitMask = 1 << (i & 7);
      bytes[byteIdx] |= bitMask;
    }
  }
  return bytes;
}

let lastLiveFrameErrorAt = 0;

function updateGlobalFrameQueueLength() {
  const normLen = (typeof normalFramePump !== 'undefined' && normalFramePump.getQueueLength) ? normalFramePump.getQueueLength() : 0;
  const liveLen = (typeof liveFramePump !== 'undefined' && liveFramePump.getQueueLength) ? liveFramePump.getQueueLength() : 0;
  firmware.frameQueue = normLen + liveLen;
}

function makeRateLimitedQueue({
  endpoint,
  intervalMs,
  maxDepth,
  onResult = null,
  updateQueueLength,
  incrementSent,
  incrementDropped,
  statusLabel,
  offlineStatusLabel,
  errorLabel,
  logErrorStr,
  coalesceLatest = false,
  isLive = false,
  postOptions = null,
}) {
  let queue = [];
  let inFlight = false;
  let timer = 0;
  let lastAt = 0;

  function schedule(delay = 0) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(pump, Math.max(0, delay));
  }

  function pump() {
    if (inFlight) return;
    if (!queue.length) {
      updateQueueLength(0);
      if (!isLive) renderState();
      return;
    }
    const now = performance.now();
    const waitMs = Math.max(0, intervalMs - (now - lastAt));
    if (waitMs > 0) {
      schedule(waitMs);
      return;
    }

    const q = queue.shift();
    updateQueueLength(queue.length);
    inFlight = true;
    lastAt = performance.now();
    incrementSent();

    if (!isLive) {
      setFirmwareStatus({
        lastRequest: `POST ${endpoint}`,
        lastStatus: isOfflineHtmlMode() && offlineStatusLabel
          ? offlineStatusLabel
          : `${statusLabel} (${queue.length}/${maxDepth})`,
      });
    }

    const requestOptions = postOptions || (isLive ? { silent: true, expectJson: false, timeoutMs: 1800 } : {});
    // Frame packets carry a packed 47-byte binary body plus per-packet reason/playback,
    // which travel as query params; everything else posts JSON as before.
    let sendPath = endpoint;
    let sendBody = q.request;
    if (q.request && q.request.__frameBinary) {
      sendPath =
        `${endpoint}?reason=${encodeURIComponent(q.request.reason || "webui_frame")}` +
        `&playback=${encodeURIComponent(q.request.playback || "idle")}`;
      sendBody = q.request.body;
    }
    apiPost(sendPath, sendBody, requestOptions)
      .then((data) => {
        const successValue = requestOptions.expectJson === false ? true : data;
        if (onResult && data) onResult(data, q.source);
        if (q.resolve) q.resolve(isLive ? true : successValue);
      })
      .catch((err) => {
        const now = performance.now();
        if (!isLive || now - lastLiveFrameErrorAt > 2000) {
          lastLiveFrameErrorAt = now;
          setFirmwareStatus({
            lastStatus: isOfflineHtmlMode() && offlineStatusLabel ? "offline html mode" : errorLabel,
            lastError: err.message,
          });
          if (shouldLogApiError() && (!isOfflineHtmlMode() || !offlineStatusLabel)) {
            log(`${logErrorStr}: ${err.message}`, "error");
          }
        }
        if (q.fallback) q.fallback();
        if (q.resolve) q.resolve(null);
      })
      .finally(() => {
        inFlight = false;
        updateQueueLength(queue.length);
        schedule(0);
        if (!isLive) {
          renderState();
        }
      });
  }

  return {
    clear(reason = "queue_clear") {
      if (timer) {
        clearTimeout(timer);
        timer = 0;
      }
      if (queue.length) {
        for (const dropped of queue) {
          if (dropped && dropped.resolve) dropped.resolve(null);
          incrementDropped();
        }
        queue = [];
      }
      updateQueueLength(0);
      if (!isLive) {
        setFirmwareStatus({
          lastRequest: `POST ${endpoint}`,
          lastStatus: `${statusLabel} cleared by ${reason}`,
        });
        renderState();
      }
    },
    isBusy() {
      return inFlight || queue.length > 0;
    },
    getQueueLength() {
      return queue.length;
    },
    waitForIdle(timeoutMs = 500) {
      const startedAt = performance.now();
      return new Promise((resolve) => {
        const check = () => {
          if (!inFlight && queue.length === 0) {
            resolve(true);
            return;
          }
          if (performance.now() - startedAt >= timeoutMs) {
            resolve(false);
            return;
          }
          setTimeout(check, 16);
        };
        check();
      });
    },
    enqueue(request, source = "unknown", fallback = null) {
      const queued = { request, source, fallback, promise: null, resolve: null };
      queued.promise = new Promise((res) => { queued.resolve = res; });
      if (coalesceLatest && queue.length) {
        for (const dropped of queue) {
          if (dropped && dropped.resolve) dropped.resolve(null);
          incrementDropped();
        }
        queue = [];
      }
      if (queue.length >= maxDepth) {
        const dropped = queue.shift();
        if (dropped && dropped.resolve) dropped.resolve(null);
        incrementDropped();
      }
      queue.push(queued);
      updateQueueLength(queue.length);
      if (!isLive) {
        setFirmwareStatus({
          lastRequest: `POST ${endpoint}`,
          lastStatus: isOfflineHtmlMode() && offlineStatusLabel
            ? offlineStatusLabel
            : `${statusLabel} (${queue.length}/${maxDepth})`,
        });
      }
      schedule(0);
      return queued;
    }
  };
}

const buttonCommandPump = makeRateLimitedQueue({
  endpoint: API_ENDPOINTS.command,
  intervalMs: WEBUI_BUTTON_COMMAND_INTERVAL_MS,
  maxDepth: WEBUI_BUTTON_COMMAND_QUEUE_MAX,
  onResult: applyFirmwareRuntimeState,
  updateQueueLength: (len) => { firmware.buttonQueue = len; },
  incrementSent: () => { firmware.sentCommands++; },
  incrementDropped: () => { firmware.droppedCommands++; },
  statusLabel: "queued button",
  offlineStatusLabel: null,
  errorLabel: "button command failed",
  logErrorStr: "button command failed; using local fallback"
});

const normalFramePump = makeRateLimitedQueue({
  endpoint: API_ENDPOINTS.frame,
  intervalMs: WEBUI_FRAME_SEND_INTERVAL_MS,
  maxDepth: WEBUI_FRAME_QUEUE_MAX,
  coalesceLatest: false,
  updateQueueLength: () => { updateGlobalFrameQueueLength(); },
  incrementSent: () => { firmware.sentFrames++; },
  incrementDropped: () => { firmware.droppedFrames++; },
  statusLabel: "queued frame",
  offlineStatusLabel: "queued offline",
  errorLabel: "frame failed",
  logErrorStr: "帧发送失败"
});

const liveFramePump = makeRateLimitedQueue({
  endpoint: API_ENDPOINTS.frame,
  intervalMs: 5,
  maxDepth: 1,
  coalesceLatest: true,
  updateQueueLength: () => { updateGlobalFrameQueueLength(); },
  incrementSent: () => { firmware.sentFrames++; },
  incrementDropped: () => { firmware.droppedFrames++; },
  statusLabel: "queued live frame",
  offlineStatusLabel: "queued offline",
  errorLabel: "live frame failed",
  logErrorStr: "Live 帧发送失败",
  isLive: true
});

const frameSendPump = {
  clear(reason) {
    normalFramePump.clear(reason);
    liveFramePump.clear(reason);
  },
  async waitForIdle(timeoutMs) {
    const results = await Promise.all([
      normalFramePump.waitForIdle(timeoutMs),
      liveFramePump.waitForIdle(timeoutMs)
    ]);
    return results[0] && results[1];
  },
  isBusy() {
    return normalFramePump.isBusy() || liveFramePump.isBusy();
  }
};

function sendButtonCommand(button, source = "webui_button", fallback = null) {
  if (["B1", "B2", "B3"].includes(String(button).toUpperCase())) {
    resetScrollControlsAfterButton(source);
  }
  const packet = { cmd: "button", payload: { button } };
  if (isOfflineHtmlMode()) {
    if (fallback) fallback();
    packet.source = source;
    packet.offline = true;
    return packet;
  }
  const queued = buttonCommandPump.enqueue(packet, source, fallback);
  packet.promise = queued.promise;
  return packet;
}

function queueFirmwareFrame(frame, reason = "frame_update", playback = "idle") {
  // Send the 47-byte packed "theoretical minimum frame" as a binary body to /api/frame;
  // reason/playback travel as query params (see the rate-limited queue sender).
  pendingFramePacket = {
    __frameBinary: true,
    body: frameBase64Body(frame),
    reason,
    playback,
    at: Date.now(),
  };
  const pump = isLiveFrameReason(reason) ? liveFramePump : normalFramePump;
  return pump.enqueue(pendingFramePacket, reason, null);
}

function frameDeltaChanges(fromFrame, toFrame) {
  const changes = [];
  for (let i = 0; i < TOTAL_LEDS; i++) {
    const next = !!toFrame[i];
    if (!!fromFrame[i] !== next) changes.push([i, next ? 1 : 0]);
  }
  return changes;
}

function applyDeltaChangesToFrame(frame, changes) {
  for (const change of changes) {
    const idx = Number(change?.[0]);
    if (Number.isInteger(idx) && idx >= 0 && idx < TOTAL_LEDS) frame[idx] = !!change[1];
  }
}

function queueFirmwareLedDeltas(changes, reason = "live_delta", playback = "idle") {
  if (!changes.length) return null;
  const nextFrame = cloneFrame(liveSyncedFrame || currentFrame);
  applyDeltaChangesToFrame(nextFrame, changes);
  const payload = {
    __frameBinary: true,
    body: frameBase64Body(nextFrame),
    reason,
    playback,
    at: Date.now(),
  };
  pendingFramePacket = payload;
  const pump = isLiveFrameReason(reason) ? liveFramePump : normalFramePump;
  const queued = pump.enqueue(payload, reason, null);
  queued.promise.then((data) => {
    if (data) liveSyncedFrame = cloneFrame(nextFrame);
  });
  return queued;
}

function setScrollPreviewFrame(frame, reason = "text_scroll_preview", playback = "scroll") {
  scrollFrame = cloneFrame(frame);
  currentFrame = cloneFrame(frame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  if (playback !== null) state.playback = playback;
  updateDps();
  renderMatrices();
  renderState();
  updatePackedFrameViews();
}

function orFrameIntoFrame(targetFrame, sourceFrame) {
  for (let i = 0; i < TOTAL_LEDS; i++) if (sourceFrame[i]) targetFrame[i] = true;
}

function orPartIntoFrame(frame, part) {
  // Standard path: part.frame is the packed (94-hex) logical row-major frame for this part.
  // Legacy strip_indices are physical snake locations and therefore need to be mapped back to logical units.
  if (part && typeof part.frame === "string") {
    orFrameIntoFrame(frame, hexToPackedFrame(part.frame));
    return;
  }
  // It is only used as a backup for deformed old resources.
  for (const idx of part?.strip_indices || []) {
    const logical = physicalToLogicalIndex(idx);
    if (logical >= 0 && logical < TOTAL_LEDS) frame[logical] = true;
  }
}

function composePartsFrame() {
  const frame = blankFrame();
  for (const key of ["leye", "reye", "mouth", "cheek"]) {
    const requested = String(selectedCall[key] ?? "0");
    const resolved = resolvePartId(key, requested);
    const part = EXPRESSION_PARTS.parts[resolved] || EXPRESSION_PARTS.parts["0"];
    orPartIntoFrame(frame, part);
  }
  partsFrame = frame;
  renderMatrices();
  return frame;
}

function sendPartsFrame(reason = "parts_compose_send", writeLog = true) {
  updatePackedFrameViews();
  setCurrentFrame(partsFrame, reason, "idle");
  if (writeLog) log("packed frame 已发送到固件接口");
}

function sendPartsFrameIfLive(reason = "parts_live_send") {
  if (!liveSendEnabled) return;
  // Real-time mode: every LED toggle is equivalent to pressing the parts 发送 button.
  sendPartsFrame("parts_compose_send", false);
}

function resolvePartId(callKey, id) {
  const normalized = String(id ?? "0");
  const resolved = callKey === "cheek" && normalized === "400" ? "0" : normalized;
  return EXPRESSION_PARTS.parts[resolved] ? resolved : "0";
}

function classifyOutputMode(reason = "", playback = null) {
  const p = String(playback || "");
  const r = String(reason || "");
  if (p === "scroll" || p === "scroll_step" || r.startsWith("text_scroll_")) return "scroll";
  if (r.startsWith("custom_")) return "custom";
  if (r.startsWith("parts_")) return "parts";
  if (r.startsWith("debug_")) return "debug";
  if (r.includes("saved_face") || r.includes("B1") || r.includes("B2")) return "face";
  return p || "static";
}

function terminateOtherActivities(targetMode = "static", reason = "mode_change") {
  const ended = [];
  const previousPlayback = state.playback;

  // One-way protection rules:
  // Another mode of start/send is a hard interrupt, not a temporary pause.
  // Content stopped here will not automatically resume after the new mode ends.
  if (targetMode !== "face" && isAutoModeValue(state.mode)) {
    state.restoreAutoAfterScroll = targetMode === "scroll";
    state.mode = "manual";
    ended.push("auto_saved_face");
  } else if (targetMode !== "scroll") {
    state.restoreAutoAfterScroll = false;
  }

  if (
    targetMode !== "scroll" &&
    (scroll.timer ||
      scroll.active ||
      state.textScrollActive ||
      isScrollPlaybackValue(previousPlayback))
  ) {
    if (scroll.timer) clearInterval(scroll.timer);
    scroll.timer = null;
    scroll.active = false;
    scroll.paused = false;
    scroll.userPaused = false;
    scroll.systemPaused = false;
    scroll.firmwareBacked = false;
    scroll.uploading = false;
    scroll.commandBusy = false;
    scroll.restoring = false;
    scroll.stepBusy = false;
    state.textScrollActive = false;
    if (isScrollPlaybackValue(state.playback)) state.playback = "idle";
    ended.push("text_scroll");
  }

  if (ended.length) {
    state.refreshPolicy =
      targetMode === "scroll" ? "text_scroll_fps_interval" : "dirty-frame / 按需刷新";
    updateScrollUi();
    renderState();
    log(`防冲突：${reason} 前终止 ${ended.join(" / ")}；不会自动恢复`);
    sendAuxCommand(
      "terminate_other_activities",
      {
        targetMode,
        ended,
      },
      reason,
    );
  }
  return ended;
}

function guardBeforeOutput(reason = "mode_change", playback = null) {
  return terminateOtherActivities(classifyOutputMode(reason, playback), reason);
}

async function prepareForTextScrollUpload() {
  const settleTimeoutMs = 1200;
  if (liveSendEnabled) {
    setLiveSendEnabled(false, "文字滚动准备");
  }
  pendingFramePacket = null;
  frameSendPump.clear("text_scroll_prepare");
  buttonCommandPump.clear("text_scroll_prepare");
  await Promise.all([
    frameSendPump.waitForIdle(settleTimeoutMs),
    buttonCommandPump.waitForIdle(settleTimeoutMs),
    waitForAuxCommandsIdle(settleTimeoutMs),
  ]);

  const ended = guardBeforeOutput("text_scroll_start", "scroll");
  const packet = ended.length
    ? null
    : sendAuxCommand(
        "terminate_other_activities",
        {
          targetMode: "scroll",
          ended: ["text_scroll_prepare"],
        },
        "text_scroll_prepare",
      );
  await Promise.all([
    packet ? packet.promise : Promise.resolve(null),
    frameSendPump.waitForIdle(settleTimeoutMs),
    buttonCommandPump.waitForIdle(settleTimeoutMs),
    waitForAuxCommandsIdle(settleTimeoutMs),
  ]);
  await sleepMs(120);
}

function setCurrentFrame(frame, reason = "manual_update", playback = null) {
  guardBeforeOutput(reason, playback);
  currentFrame = cloneFrame(frame);
  if (liveSendEnabled) syncLiveSendBaseline(currentFrame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  if (playback !== null) state.playback = playback;
  updateDps();
  renderMatrices();
  renderState();
  updatePackedFrameViews();
  queueFirmwareFrame(currentFrame, reason, state.playback);
}

function updateDps() {
  const estimatedW = estimateFrameWatts(currentFrame, state.color, state.brightness);
  state.dpsActive = estimatedW > LED_POWER_WARNING_WATTS;
  renderDpsWarning();
}

function setColor(hex, source = "color_change") {
  const c = normalizeHexColor(hex);
  if (!c) {
    alert("颜色必须是 #RRGGBB 或 RRGGBB");
    return;
  }
  const unchangedFirmwareSync = source === "firmware_sync" && state.color === c && colorDomSynced;
  if (unchangedFirmwareSync) return;
  state.color = c;
  document.documentElement.style.setProperty("--led-color", c);
  if ($("color-input")) $("color-input").value = c;
  if ($("color-swatch")) $("color-swatch").style.background = c;
  syncColorDropdownsToHex(c);
  colorDomSynced = true;
  updateDps();
  renderMatrices();
  renderState();
  log(`颜色更新 ${c} (${source})`, "debug");  // May trigger high frequency with color picker/slider
  if (source !== "firmware_sync")
    sendAuxCommand(
      "set_color",
      {
        hex: c,
      },
      source,
    );
}

function applyBrightnessLocal(v) {
  state.brightness = clampBrightness(v);
  if ($("brightness-range")) $("brightness-range").value = state.brightness;
  if ($("brightness-input")) $("brightness-input").value = state.brightness;
  updateDps();
  renderState();
}

function setBrightness(v, source = "brightness_change") {
  if (source !== "firmware_sync" && source !== "default_brightness_reset") {
    lastUserBrightnessMs = Date.now();
  }
  applyBrightnessLocal(v);
  log(`亮度更新 raw=${state.brightness} (${source})`, "debug");  // Dragging the slider will trigger high frequency
  sendAuxCommand(
    "set_brightness",
    {
      raw: state.brightness,
    },
    source,
  );
}

// Boot loader and initial firmware synchronization
// Connection relationship:
// - The visual state of the loading-overlay is controlled by the index.html tag and styles.css animation.
// - This block is only responsible for switching data-boot-phase/class and preloading the first firmware snapshot into state.
// - bootstrapWebUi() calls these functions to allow network reading and loading animation times to overlap.
let bootRuntimeSnapshot = {
  attempted: false,
  ok: false,
  error: "",
  data: null,
};

function unlockBootPageScroll() {
  if (document.documentElement.dataset.scrollLock === "boot") {
    document.documentElement.removeAttribute("data-scroll-lock");
  }
}
// -- Rina loading mask animation ---------------------------------
(function () {
  const ICON_BEFORE = WEBUI_CONFIG.boot.loadingIconBefore;
  const ICON_AFTER = WEBUI_CONFIG.boot.loadingIconAfter;
  const HOLD_MS = WEBUI_CONFIG.boot.holdMs,
    HALO_BREATH_MS = WEBUI_CONFIG.boot.haloBreathMs,
    HALO_PEAK_RATIO = WEBUI_CONFIG.boot.haloPeakRatio,
    HALO_TOL_MS = WEBUI_CONFIG.boot.haloToleranceMs,
    HALO_CONTRACT_MS = WEBUI_CONFIG.boot.haloContractMs;
  const IMG_RELEASE_MS = WEBUI_CONFIG.boot.imageReleaseMs,
    IMG_SHRINK_MS = Math.round(IMG_RELEASE_MS * 0.18),
    BLUR_DUR_MS = WEBUI_CONFIG.boot.blurDurationMs,
    EXTRA_MS = WEBUI_CONFIG.boot.extraMs;
  const overlay = document.getElementById("loadingOverlay");
  const blurScreen = document.getElementById("blurScreen");
  const avatarBefore = document.getElementById("avatarBefore");
  const avatarAfter = document.getElementById("avatarAfter");
  if (!overlay || !blurScreen || !avatarBefore || !avatarAfter) {
    unlockBootPageScroll();
    return;
  }
  let finished = false,
    finishPending = false,
    finishQueued = false,
    started = false,
    haloCycleStart = 0;
  let rafId = null;
  let afterImageReadyPromise = null;
  let loaderCenterRaf = 0;
  let loaderCenterFrozen = false;
  let lockedCenterX = 0,
    lockedCenterY = 0;
  let timelineSeq = 0;
  const scheduledTimers = new Map();

  function scheduleTimer(fn, ms) {
    const timer = window.setTimeout(() => {
      scheduledTimers.delete(timer);
      fn();
    }, ms);
    scheduledTimers.set(timer, null);
    return timer;
  }

  function delay(ms) {
    return new Promise((resolve) => {
      const timer = window.setTimeout(() => {
        scheduledTimers.delete(timer);
        resolve(true);
      }, ms);
      scheduledTimers.set(timer, () => resolve(false));
    });
  }

  function clearTimelineTimers() {
    scheduledTimers.forEach((cancel, timer) => {
      window.clearTimeout(timer);
      if (cancel) cancel();
    });
    scheduledTimers.clear();
  }

  function firstViewportCenter() {
    const vv = window.visualViewport;
    const left = Number(vv?.offsetLeft) || 0;
    const top = Number(vv?.offsetTop) || 0;
    const width =
      Number(vv?.width) || window.innerWidth || document.documentElement.clientWidth || 0;
    const height =
      Number(vv?.height) || window.innerHeight || document.documentElement.clientHeight || 0;
    return {
      x: left + width / 2,
      y: top + height / 2,
    };
  }

  function lockLoaderCenter() {
    const center = firstViewportCenter();
    lockedCenterX = center.x;
    lockedCenterY = center.y;
    document.documentElement.style.setProperty("--rina-loader-x", lockedCenterX.toFixed(2) + "px");
    document.documentElement.style.setProperty("--rina-loader-y", lockedCenterY.toFixed(2) + "px");
  }

  function syncLoaderCenter() {
    if (loaderCenterFrozen) return;
    const center = firstViewportCenter();
    lockedCenterX = center.x;
    lockedCenterY = center.y;
    document.documentElement.style.setProperty("--rina-loader-x", lockedCenterX.toFixed(2) + "px");
    document.documentElement.style.setProperty("--rina-loader-y", lockedCenterY.toFixed(2) + "px");
  }

  function scheduleLoaderCenterSync() {
    if (!started || overlay.hidden) return;
    if (loaderCenterRaf) return;
    loaderCenterRaf = requestAnimationFrame(() => {
      loaderCenterRaf = 0;
      syncLoaderCenter();
      if (blurScreen.classList.contains("is-revealing")) setOrigin();
    });
  }

  function loaderSurfaceRect() {
    return (blurScreen || overlay).getBoundingClientRect();
  }

  function revealCenterInSurface() {
    const o = loaderSurfaceRect();
    const avatarCircle = avatarBefore.closest(".avatar-circle") || avatarBefore;
    const a = avatarCircle.getBoundingClientRect();
    const cx = a.width > 0 ? a.left + a.width / 2 : lockedCenterX;
    const cy = a.height > 0 ? a.top + a.height / 2 : lockedCenterY;
    return {
      surface: o,
      x: cx - o.left,
      y: cy - o.top,
    };
  }

  function decodeLoadedImage(img) {
    if (typeof img.decode !== "function") return Promise.resolve();
    return img.decode().catch((err) => {
      if (img.complete && img.naturalWidth > 0) return;
      throw err;
    });
  }

  function waitForImage(img, src) {
    img.src = src;
    if (img.complete && img.naturalWidth > 0) return decodeLoadedImage(img);
    return new Promise((resolve, reject) => {
      const cleanup = () => {
        img.removeEventListener("load", onLoad);
        img.removeEventListener("error", onError);
      };
      const onLoad = () => {
        cleanup();
        resolve(decodeLoadedImage(img));
      };
      const onError = () => {
        cleanup();
        reject(new Error(`failed to load ${src}`));
      };
      img.addEventListener("load", onLoad, {
        once: true,
      });
      img.addEventListener("error", onError, {
        once: true,
      });
    });
  }

  function preloadInitialLoadingImage() {
    return waitForImage(avatarBefore, ICON_BEFORE);
  }

  function preloadAfterLoadingImage() {
    if (!afterImageReadyPromise) afterImageReadyPromise = waitForImage(avatarAfter, ICON_AFTER);
    return afterImageReadyPromise;
  }

  function eic(t) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }

  function getMaxR(center = revealCenterInSurface()) {
    const o = center.surface;
    const cx = center.x,
      cy = center.y;
    return Math.ceil(
      Math.max(
        Math.hypot(cx, cy),
        Math.hypot(o.width - cx, cy),
        Math.hypot(cx, o.height - cy),
        Math.hypot(o.width - cx, o.height - cy),
      ) + 90,
    );
  }

  function setOrigin() {
    const center = revealCenterInSurface();
    blurScreen.style.setProperty("--rina-reveal-x", center.x.toFixed(2) + "px");
    blurScreen.style.setProperty("--rina-reveal-y", center.y.toFixed(2) + "px");
    return center;
  }

  function animateReveal() {
    blurScreen.style.setProperty("--rina-reveal-radius", "0px");
    blurScreen.classList.add("is-revealing");
    overlay.classList.add("is-scroll-passthrough");
    unlockBootPageScroll();
    const origin = setOrigin();
    const start = performance.now(),
      maxR = getMaxR(origin);

    function fr(now) {
      const t = Math.min(1, (now - start) / BLUR_DUR_MS),
        r = maxR * eic(t);
      blurScreen.style.setProperty("--rina-reveal-radius", r.toFixed(2) + "px");
      if (t < 1) {
        rafId = requestAnimationFrame(fr);
      } else {
        rafId = null;
      }
    }
    rafId = requestAnimationFrame(fr);
  }

  function delayToPeak(now = performance.now()) {
    const phase = (((now - haloCycleStart) % HALO_BREATH_MS) + HALO_BREATH_MS) % HALO_BREATH_MS;
    let d = HALO_BREATH_MS * HALO_PEAK_RATIO - phase;
    if (Math.abs(d) <= HALO_TOL_MS) return 0;
    if (d < 0) d += HALO_BREATH_MS;
    return Math.max(0, Math.round(d));
  }

  function requestFinish() {
    if (!started) {
      finishQueued = true;
      return;
    }
    if (finished || finishPending) return;
    finishPending = true;
    scheduleTimer(doFinish, delayToPeak());
  }
  async function doFinish() {
    if (finished) return;
    const seq = timelineSeq;
    finished = true;
    finishPending = false;
    avatarBefore.src = ICON_BEFORE;
    try {
      await preloadAfterLoadingImage();
    } catch (err) {
      console.warn("Rina loading hover image failed", err);
    }
    if (seq !== timelineSeq) return;
    loaderCenterFrozen = true;
    overlay.classList.add("is-ring-contracting", "is-image-pop");
    overlay.setAttribute("aria-label", "页面加载完成");
    scheduleTimer(() => overlay.classList.add("is-halo-hidden"), HALO_CONTRACT_MS);

    if (!(await delay(HOLD_MS)) || seq !== timelineSeq) return;
    overlay.classList.add("is-final-release");
    scheduleTimer(animateReveal, IMG_SHRINK_MS);

    const wait = Math.max(IMG_RELEASE_MS, IMG_SHRINK_MS + BLUR_DUR_MS);
    if (!(await delay(wait + EXTRA_MS)) || seq !== timelineSeq) return;
    overlay.classList.add("is-hidden");

    if (!(await delay(EXTRA_MS)) || seq !== timelineSeq) return;
    overlay.hidden = true;
    overlay.setAttribute("aria-hidden", "true");
    overlay.classList.remove("is-animating");
    unlockBootPageScroll();
  }

  function initOverlay() {
    if (started) return;
    finished = false;
    finishPending = false;
    haloCycleStart = performance.now();
    timelineSeq += 1;
    clearTimelineTimers();
    if (rafId) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
    overlay.hidden = false;
    overlay.removeAttribute("aria-hidden");
    loaderCenterFrozen = false;
    lockLoaderCenter();
    overlay.classList.add("is-assets-ready", "is-animating");
    overlay.classList.remove(
      "is-assets-pending",
      "is-ring-contracting",
      "is-halo-hidden",
      "is-image-pop",
      "is-final-release",
      "is-hidden",
      "is-scroll-passthrough",
    );
    blurScreen.classList.remove("is-revealing");
    blurScreen.style.setProperty("--rina-reveal-radius", "0px");
    setOrigin();
    overlay.setAttribute("aria-label", "页面加载中");
    started = true;
    window.rinaLoaderStartedAt = haloCycleStart;
    // Hover loading images are intentionally not preloaded here (stage 3). it will be in
    // Lazy loading in doFinish(), just after the first stage reveal in stage 4, to keep initial preloading to a minimum.
    if (finishQueued) {
      finishQueued = false;
      requestAnimationFrame(requestFinish);
    }
  }
  window.rinaLoaderComplete = requestFinish;
  window.rinaLoadingImagesReadyPromise = preloadInitialLoadingImage();
  window.rinaStartLoaderAnimation = async function () {
    await window.rinaLoadingImagesReadyPromise;
    initOverlay();
  };
  window.addEventListener("resize", scheduleLoaderCenterSync, {
    passive: true,
  });
  window.visualViewport?.addEventListener("resize", scheduleLoaderCenterSync, {
    passive: true,
  });
  window.visualViewport?.addEventListener("scroll", scheduleLoaderCenterSync, {
    passive: true,
  });
})();

function finishBootVisibility() {
  document.documentElement.dataset.bootPhase = "ready";
  if (window.rinaLoaderComplete) window.rinaLoaderComplete();
}
async function waitForBootLoaderMinimum(bootStart) {
  if (window.rinaStartLoaderAnimation) await window.rinaStartLoaderAnimation();
  const startedAt = Number(window.rinaLoaderStartedAt) || bootStart;
  const elapsed = performance.now() - startedAt;
  if (elapsed < BOOT_MIN_DISPLAY_MS)
    await new Promise((r) => setTimeout(r, BOOT_MIN_DISPLAY_MS - elapsed));
}

function showBootUiBehindLoader() {
  if (document.documentElement.dataset.bootPhase === "preload") {
    document.documentElement.dataset.bootPhase = "ui-ready";
  }
}
async function bootFastJsonGet(path, timeoutMs = BOOT_STATUS_TIMEOUT_MS) {
  const url = apiUrl(path);
  firmware.lastRequest = `GET ${path}`;
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = "offline html mode";
    firmware.lastError = `offline: ${path}`;
    throw new Error(`offline html mode: ${path}`);
  }
  const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const res = await fetch(url, {
      method: "GET",
      cache: "no-store",
      headers: {
        Accept: "application/json",
      },
      signal: controller?.signal,
    });
    firmware.online = res.ok;
    firmware.lastStatus = `${res.status} ${res.statusText || ""}`.trim();
    if (!res.ok) {
      firmware.lastError = firmware.lastStatus;
      throw new Error(firmware.lastStatus);
    }
    const text = await res.text();
    return parseApiJson(text, path, {});
  } catch (err) {
    if (err?.name === "AbortError") throw new Error(`status timeout after ${timeoutMs}ms`);
    throw err;
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function rememberFirmwareStatusPoll(data) {
  const version = Number(data?.version ?? data?.v);
  if (Number.isFinite(version)) firmwareStatusVersion = version;
  const next = Number(data?.next_poll_ms);
  if (Number.isFinite(next) && next > 0) firmwareNextPollMs = Math.max(250, Math.min(10000, next));
}

function firmwareStatusPath(summaryOnly = false) {
  const params = [];
  if (summaryOnly) params.push("runtimeOnly=1", "noFrame=1");
  if (firmwareStatusVersion !== null)
    params.push(`since=${encodeURIComponent(firmwareStatusVersion)}`);
  return params.length ? `${API_ENDPOINTS.status}?${params.join("&")}` : API_ENDPOINTS.status;
}
async function preloadFirmwareRuntimeState() {
  bootRuntimeSnapshot = {
    attempted: true,
    ok: false,
    error: "",
    data: null,
  };
  if (isOfflineHtmlMode()) {
    setFirmwareStatus({
      online: false,
      lastStatus: "offline html mode",
      lastError: "offline: firmware runtime read skipped",
    });
    bootRuntimeSnapshot.error = "offline html mode";
    return bootRuntimeSnapshot;
  }
  try {
    lastFirmwareStatusPollAt = performance.now();
    // Post-loader boot sync uses the lightweight runtime summary. It intentionally
    // skips frame data so startup cannot compete with scroll/source sync or LED output.
    const data = await bootFastJsonGet(firmwareStatusPath(true));
    rememberFirmwareStatusPoll(data);
    bootRuntimeSnapshot = {
      attempted: true,
      ok: true,
      error: "",
      data,
    };
    applyFirmwareRuntimeState(data, "page_boot_runtime", {
      skipFrame: true,
    });
    setFirmwareStatus({
      lastStatus: "firmware runtime read ok",
    });
    return bootRuntimeSnapshot;
  } catch (err) {
    bootRuntimeSnapshot.error = err.message || String(err);
    setFirmwareStatus({
      online: false,
      lastStatus: "firmware runtime read failed",
      lastError: bootRuntimeSnapshot.error,
    });
    if (shouldLogApiError()) log(`启动读取固件状态失败: ${bootRuntimeSnapshot.error}`, "error");
    return bootRuntimeSnapshot;
  }
}
// Boot static-frame preview: the runtime-only status JSON intentionally omits the raw frame,
// and the face-index re-derivation only covers SAVED faces, not arbitrary custom/parts/debug
// frames. To show the *actual* current LED frame before the loader hides, pull the live packed
// frame from /api/frame/current (base64 text of FRAME_BYTES) and decode it browser-side.
// Caller must skip this when the firmware is scrolling (text scroll goes through the scroll
// preview restore path instead).
async function loadStaticFramePreviewFromFirmware(reason = "boot_static_frame") {
  if (isOfflineHtmlMode()) return false;
  const url = apiUrl(API_ENDPOINTS.currentFrame || "/api/frame/current");
  if (!url) return false;
  const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), BOOT_STATUS_TIMEOUT_MS) : null;
  try {
    lastFirmwareStatusPollAt = performance.now();
    const res = await fetch(url, {
      method: "GET",
      cache: "no-store",
      headers: { Accept: "text/plain" },
      signal: controller?.signal,
    });
    firmware.online = res.ok;
    firmware.lastStatus = `${res.status} ${res.statusText || ""}`.trim();
    if (!res.ok) {
      firmware.lastError = firmware.lastStatus;
      throw new Error(firmware.lastStatus);
    }
    const text = String(await res.text()).trim();
    const bin = atob(text);
    if (bin.length !== PACKED_FRAME_BYTES) {
      throw new Error(`当前帧应 base64 解码为 ${PACKED_FRAME_BYTES} 字节（实际 ${bin.length}）`);
    }
    const bytes = new Uint8Array(PACKED_FRAME_BYTES);
    for (let i = 0; i < PACKED_FRAME_BYTES; i++) bytes[i] = bin.charCodeAt(i) & 255;
    // Don't clobber a live scroll preview if the firmware started scrolling between the
    // runtime read and this fetch.
    if (state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback)) {
      return false;
    }
    currentFrame = packedBytesToFrame(bytes);
    if (liveSendEnabled) syncLiveSendBaseline(currentFrame);
    scrollFrame = cloneFrame(currentFrame);
    state.lastRefreshReason = reason;
    renderMatrices();
    updatePackedFrameViews();
    return true;
  } catch (err) {
    if (err?.name === "AbortError") {
      if (shouldLogApiError()) log(`启动读取当前静态帧超时（${BOOT_STATUS_TIMEOUT_MS}ms）`, "error");
    } else if (shouldLogApiError()) {
      log(`启动读取当前静态帧失败：${err.message || err}`, "error");
    }
    return false;
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}
async function syncRuntimeStateFromFirmware(source = "webui_load") {
  if (firmwareFullStatusInFlight || scroll.lightSyncing || scrollMetaFetchInFlight) return false;
  firmwareFullStatusInFlight = true;
  try {
    lastFirmwareStatusPollAt = performance.now();
    const data = await apiGet(firmwareStatusPath(false));
    rememberFirmwareStatusPoll(data);
    if (!data?.unchanged) {
      applyFirmwareRuntimeState(data, source);
      renderState();
    }
    return true;
  } catch (err) {
    if (!isOfflineHtmlMode() && shouldLogApiError())
      log(`读取固件运行/预览状态失败: ${err.message}`, "error");
    return false;
  } finally {
    firmwareFullStatusInFlight = false;
  }
}
async function syncRuntimeSummaryFromFirmware(source = "firmware_poll_runtime_summary") {
  if (firmwareRuntimeSummaryInFlight || scroll.lightSyncing || scrollMetaFetchInFlight) return false;
  firmwareRuntimeSummaryInFlight = true;
  try {
    lastFirmwareStatusPollAt = performance.now();
    const data = await apiGet(firmwareStatusPath(true));
    rememberFirmwareStatusPoll(data);
    if (!data?.unchanged)
      applyFirmwareRuntimeState(data, source, {
        skipFrame: true,
      });
    return true;
  } catch (err) {
    if (!isOfflineHtmlMode() && shouldLogApiError()) log(`读取固件轻量状态失败: ${err.message}`, "error");
    return false;
  } finally {
    firmwareRuntimeSummaryInFlight = false;
  }
}

function startFirmwareStatusPolling() {
  if (firmwareStatusPollTimer || isOfflineHtmlMode()) return;
  firmwareStatusPollTimer = setInterval(() => {
    // P1-6: while a scroll upload is in flight, skip status polling so the single-
    // threaded ESP32 WebServer isn't fighting concurrent reads against the upload.
    if (scroll.uploading || scroll.startBusy || scroll.restoring || scroll.lightSyncing || scrollMetaFetchInFlight) return;
    const firmwareIsScrolling =
      state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback);
    const minInterval = Math.max(1000, firmwareNextPollMs);
    if (performance.now() - lastFirmwareStatusPollAt < minInterval) return;
    if (firmwareIsScrolling) {
      syncRuntimeSummaryFromFirmware("firmware_poll_scroll_summary");
    } else {
      syncRuntimeStateFromFirmware("firmware_poll");
    }
  }, 500);
}
async function refreshPowerStatusFromFirmware(source = "power_timer", force = false) {
  if (
    isOfflineHtmlMode() ||
    powerStatusRefreshInFlight ||
    firmwareFullStatusInFlight ||
    firmwareRuntimeSummaryInFlight ||
    scroll.uploading || // P1-6: don't poll power during a scroll upload
    scroll.startBusy ||
    scroll.restoring ||
    scroll.lightSyncing ||
    scrollMetaFetchInFlight
  )
    return;
  const now = performance.now();
  if (!force && now - lastPowerStatusRefreshAt < POWER_STATUS_REFRESH_MS) return;
  powerStatusRefreshInFlight = true;
  try {
    lastPowerStatusRefreshAt = now;
    const data = await apiGet(API_ENDPOINTS.power);
    const powerPayload = data?.power && typeof data.power === "object" ? data.power : data;
    applyPowerData(powerPayload);
    renderState();
  } catch (err) {
    if (shouldLogApiError()) log(`power status refresh failed: ${err.message}`, "error");
  } finally {
    powerStatusRefreshInFlight = false;
  }
}

function startPowerStatusPolling() {
  if (powerStatusPollTimer || isOfflineHtmlMode()) return;
  refreshPowerStatusFromFirmware("basic_power_start", true);
  powerStatusPollTimer = setInterval(() => {
    if (!["basic", "debug"].includes(document.body?.dataset?.page)) return;
    refreshPowerStatusFromFirmware("power_timer");
  }, 1000);
}

function stopPollingTimers() {
  if (firmwareStatusPollTimer) {
    clearInterval(firmwareStatusPollTimer);
    firmwareStatusPollTimer = null;
  }
  if (powerStatusPollTimer) {
    clearInterval(powerStatusPollTimer);
    powerStatusPollTimer = null;
  }
}
window.addEventListener("pagehide", stopPollingTimers);

document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    stopPollingTimers();
    if (typeof scroll !== "undefined" && scroll.timer) {
      clearInterval(scroll.timer);
      scroll.timer = null;
      scroll._wasActiveBeforeHide = true;
    }
  } else {
    startFirmwareStatusPolling();
    startPowerStatusPolling();
    if (typeof scroll !== "undefined" && scroll._wasActiveBeforeHide && scroll.active && !scroll.paused) {
      if (typeof advanceScroll === "function" && typeof getScrollFrameIntervalMs === "function") {
        previewTickLoop();
      }
      scroll._wasActiveBeforeHide = false;
    }
  }
});

function setNavMenuOpen(open) {
  const nav = $("nav");
  const toggle = $("brand-nav-toggle");
  const topNav = $("top-page-nav");
  if (!nav || !toggle || !topNav) return;
  topNav.classList.toggle("open", open);
  nav.classList.toggle("open", open);
  toggle.classList.toggle("active", open);
  toggle.setAttribute("aria-expanded", open ? "true" : "false");
  topNav.setAttribute("aria-hidden", open ? "false" : "true");
  nav.setAttribute("aria-hidden", open ? "false" : "true");
  topNav.inert = !open;
  nav.querySelectorAll("button").forEach((btn) => {
    btn.tabIndex = open ? 0 : -1;
  });
  updateCurrentPageLabel(document.body.dataset.page || "basic");
}

function updateCurrentPageLabel(id) {
  const item = PAGES.find(([pid]) => pid === id);
  const pageText = item ? `${item[1]} ${item[2]}` : "";
  const toggle = $("brand-nav-toggle");
  if (pageText && toggle) {
    const open = toggle.getAttribute("aria-expanded") === "true";
    toggle.title = pageText;
    toggle.setAttribute("aria-label", `${open ? "关闭" : "打开"}页面切换器：${pageText}`);
  }
}

function modeForPage(id) {
  if (id === "scroll") return "scroll";
  if (id === "custom") return "custom";
  if (id === "parts") return "parts";
  if (id === "debug") return "debug";
  return "face";
}
let debugLayoutCards = [];
let debugLayoutColumnCount = 0;
let debugLayoutRaf = 0;

function responsiveColumnCount() {
  const width = window.innerWidth || document.documentElement.clientWidth || 0;
  if (width <= LAYOUT_ONE_COLUMN_MAX_PX) return 1;
  if (width >= LAYOUT_THREE_COLUMNS_MIN_PX) return 3;
  return 2;
}

// page-debug rewrite: The old JS masonry layout has been replaced by the .debug-layout CSS grid.
// Both functions are left no-op for compatibility with existing call sites (switchPage, etc.), and layout is left entirely to CSS.
function scheduleDebugMasonryLayout() {
  /* no-op: .debug-layout is handled by CSS */
}

function setupDebugMasonryLayout() {
  /* no-op: .debug-layout handles layout by CSS; matrix adaptation is still triggered when entering the debug page */
  scheduleMatrixFitRender(2);
}

function switchPage(id) {
  // Page switching is just WebUI navigation; buttons/frame writes that actually change LED output will each interrupt scrolling.
  document.body.dataset.page = id;
  for (const [pid] of PAGES) {
    $("page-" + pid).classList.toggle("active", pid === id);
    const b = document.querySelector(`.nav button[data-page="${pid}"]`);
    if (b) b.classList.toggle("active", pid === id);
  }
  updateCurrentPageLabel(id);
  setNavMenuOpen(false);
  scheduleMatrixFitRender(2);
  if (id === "scroll") {
    ensureScrollFontsLoaded();
    // Rebuild preview frames from recovered source text on demand when going into 6.4 (plan v6 2.5).
    restoreScrollPreviewIfNeeded("page_entry").catch((err) => {
      warnScrollRestoreDebug("preview restore page-entry failed", {
        error: err?.message || String(err),
      });
    });
    requestAnimationFrame(() => {
      autoResizeScrollTextInput();
      updateScrollUi();
    });
  }
  if (id === "custom")
    requestAnimationFrame(() => {
      const a = $("custom-frame");
      if (a) autoResizeTextarea(a);
    });
  if (id === "parts")
    requestAnimationFrame(() => {
      const a = $("parts-frame-text");
      if (a) autoResizeTextarea(a);
    });
  if (isFaceLibraryPage(id)) {
    scheduleFaceLibraryRefresh(`${id}_page_enter`, 0);
  }
  if (id === "debug") {
    // Entering 6.5: flush any log lines accumulated while the panel was hidden.
    if (logDirty) renderLog();
    requestAnimationFrame(() => {
      setupDebugMasonryLayout(true);
      const a = $("debug-frame");
      if (a) autoResizeTextarea(a);
      refreshDebugFrameValidation();
    });
    // Into 6.5: Lightweight runtime summary + power state; read-only panels are rendered by renderState->renderDebugReadouts.
    syncRuntimeSummaryFromFirmware("debug_page_enter");
    refreshPowerStatusFromFirmware("debug_page_enter", true);
    renderDebugReadouts();
  }
  if (id === "basic") {
    syncRuntimeStateFromFirmware("basic_page_enter");
    refreshPowerStatusFromFirmware("basic_page_enter", true);
  }
}

// Navigation, responsive layout and custom selectors
// Connection relationship:
// - initNav() generates the top page menu based on PAGES, and the menu button switches .page.active.
// - switchPage() is responsible for the page life cycle: start lazy loading of fonts when entering 6.4, and maintain status synchronization when leaving.
// - Responsive auxiliary only sets necessary classes/sizes; the actual layout is still determined by the grid/media rules of styles.css.
function initNav() {
  const nav = $("nav");
  nav.innerHTML = "";
  const toggle = $("brand-nav-toggle");
  if (toggle)
    toggle.onclick = (ev) => {
      ev.stopPropagation();
      setNavMenuOpen(!nav.classList.contains("open"));
    };
  nav.onclick = (ev) => ev.stopPropagation();
  for (const [id, num, name] of PAGES) {
    const b = document.createElement("button");
    b.type = "button";

    b.dataset.page = id;
    b.setAttribute("role", "menuitem");
    b.innerHTML = `<span>${name}</span><span class="num">${num}</span>`;
    if (id === "basic") b.classList.add("active");
    b.onclick = () => switchPage(id);
    nav.appendChild(b);
  }
  updateCurrentPageLabel("basic");
  document.body.dataset.page = "basic";
  setNavMenuOpen(false);
  document.addEventListener("click", (ev) => {
    if (!$("nav-shell")?.contains(ev.target)) setNavMenuOpen(false);
  });
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") setNavMenuOpen(false);
  });
}

function viewportBoundsForFixedMenu() {
  const vv = window.visualViewport;
  const left = Math.floor(vv?.offsetLeft || 0);
  const top = Math.floor(vv?.offsetTop || 0);
  const width = Math.floor(
    vv?.width || document.documentElement.clientWidth || window.innerWidth || 0,
  );
  const height = Math.floor(
    vv?.height || document.documentElement.clientHeight || window.innerHeight || 0,
  );
  return {
    left,
    top,
    width,
    height,
    right: left + width,
    bottom: top + height,
  };
}
let selectScrollLock = null;
function lockPageScrollForSelects() {
  if (selectScrollLock) return;
  // Just a flag: prevent scrolling by intercepting events, keeping
  // The scrollbars are visible and the layout is unchanged (the overflow is not modified).
  selectScrollLock = true;
}

function unlockPageScrollForSelects() {
  selectScrollLock = null;
}

function syncSelectPageScrollLock() {
  if (document.querySelector(".select-shell.open")) lockPageScrollForSelects();
  else unlockPageScrollForSelects();
}
// Prevent touchmove outside dropdown menu (touch scrolling)
function selectMenuCanScroll(menu) {
  return (
    !!menu &&
    getComputedStyle(menu).overflowY !== "hidden" &&
    menu.scrollHeight > menu.clientHeight + 1
  );
}

function blockPageTouchMoveWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.(".select-menu");
  if (selectMenuCanScroll(menu)) return;
  ev.preventDefault();
}
// Prevent wheel events outside dropdown menus (mouse/trackpad scrolling)
function blockPageWheelWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.(".select-menu");
  if (selectMenuCanScroll(menu)) return;
  ev.preventDefault();
}
// Block keyboard scroll keys outside dropdown menu
function blockPageKeyScrollWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.(".select-menu");
  if (selectMenuCanScroll(menu)) return;
  if (PAGE_SCROLL_KEYS.has(ev.key)) ev.preventDefault();
}

function positionSelectMenu(shell, options = {}) {
  const toggle = shell.querySelector(".select-toggle");
  const menu = shell._selectMenu;
  if (!toggle || !menu) return;
  const r = toggle.getBoundingClientRect();
  const viewport = viewportBoundsForFixedMenu();
  const viewportPadding = 8;
  const menuGap = 8;
  // verticalOnly: Skip width/left offset recalculation (used for window scroll events to prevent horizontal jumping)
  if (!options.verticalOnly) {
    // Mirror the exact width and left edge of the toggle button, without rounding or clipping.
    shell._selectMenuWidth = r.width; // Keep true to keep the "opened" flag active
    menu.style.width = r.width + "px";
    menu.style.left = r.left + "px";
  }
  // By default, it is placed at the bottom; when there is insufficient space, it is flipped to the top.
  const spaceBelow = Math.max(0, viewport.bottom - r.bottom - menuGap - viewportPadding);
  const spaceAbove = Math.max(0, r.top - viewport.top - menuGap - viewportPadding);
  const openBelow = spaceBelow >= 96 || spaceBelow >= spaceAbove;
  // The available height is equal to the full space in the selected direction, without any upper limit.
  // The menu will expand as much as possible to show all buttons; it will only scroll invisible if it cannot fit.
  const availableHeight = Math.max(48, openBelow ? spaceBelow : spaceAbove);
  const menuStyle = getComputedStyle(menu);
  const borderY =
    parseFloat(menuStyle.borderTopWidth || "0") + parseFloat(menuStyle.borderBottomWidth || "0");
  const naturalH = menu.scrollHeight; // Content full height, including padding but not borders
  const naturalOuterH = Math.ceil(naturalH + borderY);
  const fitsAllOptions = naturalOuterH <= availableHeight + 1;
  const menuH = fitsAllOptions ? naturalOuterH : availableHeight;
  menu.style.maxHeight = menuH + "px";
  menu.style.overflowY = fitsAllOptions ? "hidden" : "auto";
  const desiredTop = openBelow ? r.bottom + menuGap : r.top - menuGap - menuH;
  menu.style.top =
    Math.max(
      viewport.top + viewportPadding,
      Math.min(desiredTop, viewport.bottom - menuH - viewportPadding),
    ) + "px";
  menu.style.bottom = "auto";
}

function closeOneCustomSelect(shell) {
  if (!shell) return;
  shell.classList.remove("open");
  const btn = shell.querySelector(".select-toggle");
  const menu = shell._selectMenu;
  if (btn) btn.setAttribute("aria-expanded", "false");
  if (menu) {
    menu.setAttribute("aria-hidden", "true");
    menu.classList.remove("open");
    clearTimeout(menu._hideTimer);
    menu._hideTimer = setTimeout(() => {
      if (!shell.classList.contains("open")) {
        menu.style.display = "none";
        shell._selectMenuWidth = 0;
      }
    }, SELECT_MENU_HIDE_DELAY_MS);
  } else {
    shell._selectMenuWidth = 0;
  }
}

function closeCustomSelects(exceptShell = null) {
  document.querySelectorAll(".select-shell.open").forEach((shell) => {
    if (shell !== exceptShell) {
      closeOneCustomSelect(shell);
    }
  });
  syncSelectPageScrollLock();
}

function splitDropdownLabel(text) {
  const raw = String(text || "").trim();
  const match = raw.match(/^(.*?)\s{2,}(.+)$/);
  if (match) return [match[1].trim(), match[2].trim()];
  return [raw, ""];
}

function ensureCustomSelect(select) {
  if (!select) return null;
  const shell = select.closest(".select-shell");
  if (!shell) return null;
  let toggle = shell.querySelector(".select-toggle");
  let menu = shell.querySelector(".select-menu");
  if (!toggle) {
    toggle = document.createElement("button");
    toggle.type = "button";
    toggle.className = "select-toggle";
    toggle.setAttribute("aria-haspopup", "menu");
    toggle.setAttribute("aria-expanded", "false");
    toggle.innerHTML =
      '<span class="select-label"></span><span class="select-caret" aria-hidden="true">▾</span>';
    shell.insertBefore(toggle, select.nextSibling);
    const oldCaret = shell.querySelector(":scope > .select-caret");
    if (oldCaret && oldCaret !== toggle.querySelector(".select-caret")) oldCaret.remove();
    toggle.onclick = (ev) => {
      ev.stopPropagation();
      const willOpen = !shell.classList.contains("open");
      closeCustomSelects(shell);
      shell.classList.toggle("open", willOpen);
      toggle.setAttribute("aria-expanded", willOpen ? "true" : "false");
      const m = shell._selectMenu;
      if (m) {
        m.setAttribute("aria-hidden", willOpen ? "false" : "true");
        if (willOpen) {
          lockPageScrollForSelects();
          clearTimeout(m._hideTimer);
          m.style.display = "grid";
          m.classList.remove("open");
          positionSelectMenu(shell, {
            recalcWidth: true,
          });
          requestAnimationFrame(() => {
            if (shell.classList.contains("open")) m.classList.add("open");
          });
        } else {
          closeOneCustomSelect(shell);
          syncSelectPageScrollLock();
        }
      }
    };
  }
  if (!shell._selectMenu) {
    menu = document.createElement("div");
    menu.className = "select-menu";
    menu.setAttribute("role", "menu");
    menu.setAttribute("aria-hidden", "true");
    menu.style.display = "none";
    document.body.appendChild(menu);
    shell._selectMenu = menu;
    menu._shell = shell;
    menu.onclick = (ev) => ev.stopPropagation();
  } else {
    menu = shell._selectMenu;
  }
  return {
    shell,
    toggle,
    menu,
  };
}

function refreshSelectDropdown(idOrSelect) {
  const select = typeof idOrSelect === "string" ? $(idOrSelect) : idOrSelect;
  const ui = ensureCustomSelect(select);
  if (!select || !ui) return;
  const selected = select.options[select.selectedIndex] || select.options[0];
  const label = ui.toggle.querySelector(".select-label");
  if (label) label.textContent = selected ? selected.textContent.trim() : "选择";
  ui.menu.innerHTML = "";
  Array.from(select.options).forEach((opt) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "select-option";
    b.setAttribute("role", "menuitem");
    b.dataset.value = opt.value;
    const [main, detail] = splitDropdownLabel(opt.textContent);
    const detailColor = detail && detail.match(/#[0-9a-fA-F]{6}\b/);
    if (detailColor) b.style.setProperty("--option-color", detailColor[0]);
    const mainSpan = document.createElement("span");
    mainSpan.textContent = main;
    b.appendChild(mainSpan);
    if (detail) {
      const detailSpan = document.createElement("span");
      detailSpan.className = "num";
      detailSpan.textContent = detail;
      b.appendChild(detailSpan);
    }
    b.classList.toggle("active", opt.value === select.value);
    b.onclick = (ev) => {
      ev.stopPropagation();
      select.value = opt.value;
      select.dispatchEvent(
        new Event("change", {
          bubbles: true,
        }),
      );
      closeOneCustomSelect(ui.shell);
      syncSelectPageScrollLock();
      refreshAllCustomSelects();
    };
    ui.menu.appendChild(b);
  });
}

function refreshAllCustomSelects() {
  document.querySelectorAll(".select-shell select").forEach((sel) => refreshSelectDropdown(sel));
}

function initCustomSelectDropdowns() {
  document.querySelectorAll(".select-shell select").forEach((sel) => {
    ensureCustomSelect(sel);
    sel.addEventListener("change", () => requestAnimationFrame(refreshAllCustomSelects));
  });
  refreshAllCustomSelects();
  document.addEventListener("click", () => closeCustomSelects());
  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape") closeCustomSelects();
    blockPageKeyScrollWhileSelectOpen(ev);
  });
  document.addEventListener("touchmove", blockPageTouchMoveWhileSelectOpen, {
    passive: false,
  });
  window.addEventListener("wheel", blockPageWheelWhileSelectOpen, {
    passive: false,
  });
  // Reposition an open menu when scrolling or resizing
  const reposition = () => {
    document.querySelectorAll(".select-shell.open").forEach((shell) => positionSelectMenu(shell));
  };
  const resizeReposition = () => {
    document.querySelectorAll(".select-shell.open").forEach((shell) =>
      positionSelectMenu(shell, {
        recalcWidth: true,
      }),
    );
  };
  window.addEventListener("resize", resizeReposition, {
    passive: true,
  });
  window.visualViewport?.addEventListener("resize", reposition, {
    passive: true,
  });
  // visualViewport scrolling (pan after pinch zoom): complete repositioning required
  window.visualViewport?.addEventListener("scroll", reposition, {
    passive: true,
  });
  // Window scrolling: Only update vertical position, avoid horizontal width/left offset jumping.
  // Completely skipped when scroll is locked (the page is not actually scrolling, these events are redundant).
  window.addEventListener(
    "scroll",
    () => {
      if (selectScrollLock) return;
      document.querySelectorAll(".select-shell.open").forEach((shell) =>
        positionSelectMenu(shell, {
          verticalOnly: true,
        }),
      );
    },
    {
      passive: true,
      capture: true,
    },
  );
}

// LED matrix rendering and editing
// Connection relationship:
// - initMatrix() turns the matrix container in index.html into 370 renderable cells.
// - MATRIX_VIEW_CONFIGS specifies which frame provider to read for each matrix.
// - Click Edit to only modify the corresponding buffer; use setCurrentFrame()/queueFirmwareFrame() to push the result to the firmware.
// - renderMatrices() is the final visual refresh point shared by all pages.
// Superimpose the rinaboard.png background image behind the matrix: wrap the matrix into .rinaboard-stage,
// And inject a decorative basemap. All LED previews share the same structure and alignment style.
// Idempotent: If it has been wrapped, it will not be processed again.
// LED 预览背景图（rinaboard.png）较大，单独纳入加载序列：加载动画开始后才请求它，
// 加载完成（或失败/超时）后再开始卡片瀑布揭示。这样首屏关键资源（HTML/CSS/JS/字体）
// 先就位，避免这张大图与其它请求在单连接的固件 Web 服务器上互相抢占、拖到首次加载超时。
const RINABOARD_IMAGE_SRC = "resources/pictures/rinaboard.png";
const RINABOARD_PRELOAD_TIMEOUT_MS = 8000;
let rinaboardImagePromise = null;
function preloadRinaboardImage() {
  if (rinaboardImagePromise) return rinaboardImagePromise;
  rinaboardImagePromise = new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      resolve();
    };
    const img = new Image();
    img.onload = finish;
    img.onerror = finish; // 缺图/失败也不能卡住启动
    img.src = RINABOARD_IMAGE_SRC;
    if (img.complete) finish(); // 已在缓存中
    // 安全阀：图片很慢或超时也不能让卡片瀑布永远等待。
    setTimeout(finish, RINABOARD_PRELOAD_TIMEOUT_MS);
  });
  return rinaboardImagePromise;
}

function ensureRinaboardStage(el) {
  if (!el || el.closest(".rinaboard-stage")) return;
  const parent = el.parentNode;
  if (!parent) return;
  const stage = document.createElement("div");
  stage.className = "rinaboard-stage";
  const img = document.createElement("img");
  img.className = "rinaboard-bg-img";
  // 同一 URL，命中 preloadRinaboardImage() 预加载的浏览器缓存，立即显示。
  img.src = RINABOARD_IMAGE_SRC;
  img.alt = "";
  img.setAttribute("aria-hidden", "true");
  img.draggable = false;
  img.onload = () => {
    scheduleMatrixFitRender(2);
  };
  parent.insertBefore(stage, el);
  stage.appendChild(img);
  stage.appendChild(el);
}

function initMatrix(id, frameProvider, editable = false, editHandler = null, compact = false) {
  const el = $(id);
  if (!el) return;
  ensureRinaboardStage(el);
  el.innerHTML = "";
  if (compact) el.classList.add("compact");
  
  const frag = document.createDocumentFragment();
  for (let y = 0; y < ROWS; y++) {
    for (let x = 0; x < COLS; x++) {
      const idx = XY_TO_INDEX[y][x];
      const cell = document.createElement("div");
      cell.className =
        "led" + (idx < 0 ? " invalid" : "") + (editable && idx >= 0 ? " editable" : "");
      if (idx >= 0) {
        cell.dataset.idx = idx;
        cell.dataset.x = x;
        cell.dataset.y = y;
      }
      frag.appendChild(cell);
    }
  }
  el.appendChild(frag);

  const view = {
    el,
    frameProvider,
    compact: !!compact,
    dirty: true,
    lastState: new Uint8Array(370)
  };
  matrixViews.push(view);
  if (editable) {
    el.classList.add("editable-matrix");
    attachDrawing(el, editHandler);
  }
  fitMatrix(view);
}

function matrixSizeNumber(style, name, fallback) {
  const v = parseFloat(style.getPropertyValue(name));
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

function elementOuterBlockSize(el) {
  if (!el || el.hidden) return 0;
  const st = getComputedStyle(el);
  if (st.display === "none") return 0;
  const r = el.getBoundingClientRect();
  return r.height + (parseFloat(st.marginTop) || 0) + (parseFloat(st.marginBottom) || 0);
}

function matrixMaxContentHeight(wrap, configuredMaxHeight) {
  if (!(configuredMaxHeight > 0)) return Infinity;
  const card = wrap.closest(".led-preview-card");
  if (!card) return configuredMaxHeight;
  const cardStyle = getComputedStyle(card);
  const cardChrome =
    (parseFloat(cardStyle.paddingTop) || 0) +
    (parseFloat(cardStyle.paddingBottom) || 0) +
    (parseFloat(cardStyle.borderTopWidth) || 0) +
    (parseFloat(cardStyle.borderBottomWidth) || 0);
  let reserved = cardChrome;
  if (wrap.parentElement === card) {
    for (const child of card.children) {
      if (child === wrap) continue;
      reserved += elementOuterBlockSize(child);
    }
    const rowGap = parseFloat(cardStyle.rowGap || cardStyle.gap) || 0;
    if (card.children.length > 1) reserved += rowGap * (card.children.length - 1);
  }
  return Math.max(1, configuredMaxHeight - reserved);
}

function fitMatrix(view) {
  const wrap = view.el.closest(".matrix-wrap");
  if (!wrap) return;

  const stage = view.el.closest(".rinaboard-stage");
  if (stage) {
    const img = stage.querySelector(".rinaboard-bg-img");
    if (img) {
      const rect = img.getBoundingClientRect();
      if (rect.width > 0) {
        const scale = rect.width / 4000;
        stage.style.setProperty("--alignment-scale", String(scale));
      }
    }
  }

  const wrapStyle = getComputedStyle(wrap);
  const cs = getComputedStyle(view.el);
  const gap = parseFloat(cs.getPropertyValue("--gap")) || (view.compact ? 2 : 3);
  const defaultCell = view.compact
    ? 8
    : matrixSizeNumber(wrapStyle, "--matrix-default-cell", LED_PREVIEW_SIZE.defaultCell);
  const minCell = view.compact
    ? 4
    : matrixSizeNumber(wrapStyle, "--matrix-min-cell", LED_PREVIEW_SIZE.minCell);
  const cssMaxCell = matrixSizeNumber(wrapStyle, "--matrix-max-cell", LED_PREVIEW_SIZE.maxCell);
  const configuredMaxHeight = matrixSizeNumber(
    wrapStyle,
    "--matrix-max-height",
    LED_PREVIEW_SIZE.maxHeight,
  );
  const maxCell = view.compact ? 12 : cssMaxCell;
  const edgeRatioRaw = parseFloat(wrapStyle.getPropertyValue("--led-preview-edge-ratio"));
  const edgeRatio = Number.isFinite(edgeRatioRaw) && edgeRatioRaw >= 0 ? edgeRatioRaw : 0.1;

  // Smooth real-time scaling: Keep transparent padding proportional to --cell.
  // The adaptation formula will reserve 2 * edgeRatio * cells in the packaging layer,
  // So the LED matrix margins scale with the LED grid,
  // Does not remain fixed when card size changes.
  const wrapRect = wrap.getBoundingClientRect();
  if (wrapRect.width <= 0 || wrap.offsetParent === null) {
    // Floor to whole pixels so every cell lands on an exact device-pixel
    // boundary and the gap renders uniformly between all LEDs.
    const cell = Math.max(1, Math.floor(clamp(defaultCell, minCell, maxCell)));
    const edgeGap = cell * edgeRatio;
    view.el.style.setProperty("--cell", cell + "px");
    view.el.dataset.cellPx = String(cell);
    wrap.style.setProperty("--matrix-edge-gap", edgeGap.toFixed(4) + "px");
    return;
  }

  const borderX =
    (parseFloat(wrapStyle.borderLeftWidth) || 0) + (parseFloat(wrapStyle.borderRightWidth) || 0);
  const borderY =
    (parseFloat(wrapStyle.borderTopWidth) || 0) + (parseFloat(wrapStyle.borderBottomWidth) || 0);
  const widthBudget = Math.max(1, wrapRect.width - borderX);
  const maxContentHeight = matrixMaxContentHeight(wrap, configuredMaxHeight);
  const heightBudget = Number.isFinite(maxContentHeight)
    ? Math.max(1, maxContentHeight - borderY)
    : Infinity;
  const widthDenom = COLS + 2 * edgeRatio;
  const heightDenom = ROWS + 2 * edgeRatio;
  const cellByWidth = (widthBudget - gap * (COLS - 1)) / widthDenom;
  const cellByHeight = Number.isFinite(heightBudget)
    ? (heightBudget - gap * (ROWS - 1)) / heightDenom
    : Infinity;
  const fitCell = Math.min(cellByWidth, cellByHeight, maxCell);
  // Floor to whole pixels so every cell lands on an exact device-pixel boundary
  // and the gap renders uniformly between all LEDs (no alternating 1px/2px lines).
  const cell = Math.max(1, Math.floor(clamp(fitCell, minCell, maxCell)));
  const edgeGap = cell * edgeRatio;
  view.el.style.setProperty("--cell", cell + "px");
  view.el.dataset.cellPx = String(cell);
  wrap.style.setProperty("--matrix-edge-gap", edgeGap.toFixed(4) + "px");
}

function fitAllMatrices() {
  matrixViews.forEach(fitMatrix);
}
let matrixResizeObserver = null;
let matrixFitRaf = 0;
let matrixFitSettleFrames = 0;

function runMatrixFitRender() {
  matrixFitRaf = 0;
  fitAllMatrices();
  renderMatrices();
  if (matrixFitSettleFrames > 0) {
    matrixFitSettleFrames--;
    matrixFitRaf = requestAnimationFrame(runMatrixFitRender);
  }
}

function scheduleMatrixFitRender(settleFrames = 1) {
  matrixFitSettleFrames = Math.max(matrixFitSettleFrames, settleFrames);
  if (matrixFitRaf) return;
  matrixFitRaf = requestAnimationFrame(runMatrixFitRender);
}

function observeMatrixWraps() {
  if (matrixResizeObserver) return;
  const onResize = () => scheduleMatrixFitRender(2);
  if (typeof ResizeObserver !== "undefined") {
    matrixResizeObserver = new ResizeObserver(onResize);
    document
      .querySelectorAll(".matrix-wrap,.led-preview-card,.rinaboard-stage")
      .forEach((el) => matrixResizeObserver.observe(el));
  } else {
    matrixResizeObserver = {
      disconnect() {},
    };
  }
  window.addEventListener("resize", onResize, {
    passive: true,
  });
  window.addEventListener("resize", () => scheduleDebugMasonryLayout(true), {
    passive: true,
  });
  window.addEventListener("orientationchange", onResize, {
    passive: true,
  });
  window.addEventListener("orientationchange", () => scheduleDebugMasonryLayout(true), {
    passive: true,
  });
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", onResize, {
      passive: true,
    });
    window.visualViewport.addEventListener("resize", () => scheduleDebugMasonryLayout(), {
      passive: true,
    });
    window.visualViewport.addEventListener("scroll", onResize, {
      passive: true,
    });
  }
}

function renderMatrices() {
  for (const view of matrixViews) {
    // The hidden matrix does not perform rendering and is marked as dirty. It will be fully updated the next time it is visible.
    if (view.el.offsetParent === null) {
      view.dirty = true;
      continue;
    }
    const frame = view.frameProvider();
    const cells = view.el.children;
    const lastState = view.lastState;
    
    for (let y = 0, n = 0; y < ROWS; y++) {
      for (let x = 0; x < COLS; x++, n++) {
        const idx = XY_TO_INDEX[y][x];
        if (idx >= 0) {
          const isOn = !!frame[idx];
          // Only update DOM when state changes or dirty mark
          if (view.dirty || isOn !== !!lastState[idx]) {
            cells[n].classList.toggle("on", isOn);
            lastState[idx] = isOn ? 1 : 0;
          }
        }
      }
    }
    view.dirty = false;
  }
}

function attachDrawing(el, editHandler) {
  const getCell = (target) => target && target.closest && target.closest(".led.editable");
  el.addEventListener("click", (ev) => {
    const cell = getCell(ev.target);
    if (!cell || !cell.dataset.idx) return;
    ev.stopPropagation();
    const idx = Number(cell.dataset.idx);
    editHandler(idx, !editFrame[idx], "toggle");
  });
}

function formatVolts(value) {
  const n = Number(value);
  return Number.isFinite(n) ? `${n.toFixed(2)} V` : "n/a";
}

function formatBatteryPercent(value) {
  const n = Number(value);
  return Number.isFinite(n) ? `${Math.round(n)}%` : "n/a";
}

function formatChargingState(value) {
  return typeof value === "boolean" ? (value ? "充电中" : "未充电") : "n/a";
}

function formatChargingBadge(value) {
  return typeof value === "boolean" ? (value ? "充电中" : "未充电") : "充电 --";
}

function formatMilliVolts(value) {
  const n = Number(value);
  return Number.isFinite(n) ? `${Math.round(n)} mV` : "n/a";
}

function batteryPowerText() {
  return state.batteryPowered === false ? "未上电" : state.batteryStateText || "电池";
}

function firmwareConnectionUiState() {
  const online = !!firmware.online;
  if (online) return { label: "在线", dotClass: "status-dot" };
  const hasError = !!(firmware.lastError && firmware.lastError !== "—");
  return { label: hasError ? "错误" : "离线", dotClass: "status-dot danger" };
}

// UI renderer
// Connection relationship:
// - renderState() is a centralized outlet for state -> DOM, preventing business functions from changing UI copy everywhere.
// - renderFaceLibrary()/renderPartButtons()/updateScrollUi() handle their respective complex subviews.
// - All rendering functions should be idempotent: repeated calls can only refresh, and should not repeatedly bind events or change business status.
function renderState() {
  // Shared UI (header battery/charging badge, mode switching) must be updated on any page and is not affected by page-debug.
  updateModeToggleUi();
  const runtimeDot = $("badge-runtime-dot"),
    runtimeLabel = $("badge-runtime-label"),
    runtimeBadge = $("badge-runtime");
  if (runtimeDot && runtimeLabel) {
    const connection = firmwareConnectionUiState();
    runtimeDot.className = connection.dotClass;
    runtimeLabel.textContent = connection.label;
    if (runtimeBadge) {
      runtimeBadge.title = firmware.online
        ? "固件连接在线"
        : firmware.lastError
          ? `固件连接${connection.label}: ${firmware.lastError}`
          : `固件连接${connection.label}`;
    }
  }
  const battDot = $("badge-battery-dot"),
    battLabel = $("badge-battery-label");
  if (battDot && battLabel) {
    const pct = state.batteryPercent,
      vbat = state.batteryV;
    battLabel.textContent =
      state.batteryPowered === false
        ? `未上电 ${formatVolts(vbat)}`
        : `电池 ${formatVolts(vbat)}  ${formatBatteryPercent(pct)}`;
    battDot.className = state.batteryIconClass || "status-dot dim";
    battDot.style.backgroundColor = state.batteryIconColor || "";
  }
  const chgDot = $("badge-charging-dot"),
    chgLabel = $("badge-charging-label");
  if (chgDot && chgLabel) {
    chgDot.className = state.chargeIconClass || "status-dot dim";
    chgDot.style.backgroundColor = state.chargeIconColor || "";
    chgLabel.textContent =
      state.charging === true
        ? `充电中 ${formatVolts(state.chargeV)}`
        : formatChargingBadge(state.charging);
  }
  // Debug page read-only panel: only renders when 6.5 is active, and only rewrites read-only kv/badge/preview meta information,
  // Never rebuild interactive controls (packed frame/raw JSON/checkboxes). renderState has 44 call points,
  // Therefore the page must be gated to avoid clearing user input on every poll/request (v2 rule 4).
  renderDebugReadouts();
}

function kvRows(rows) {
  return rows
    .map(([k, v]) => `<span class="k">${escapeHtml(k)}</span><span>${escapeHtml(String(v))}</span>`)
    .join("");
}

function escapeHtml(s) {
  return String(s).replace(
    /[&<>"']/g,
    (c) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[c],
  );
}

function autoResizeTextarea(el) {
  if (!el) return;
  // If the element (or any ancestor) is display:none, offsetParent will be null,
  // and scrollHeight will also return 0. Exit early to avoid collapsing the height to 0px.
  // switchPage() will call this again once the page becomes visible.
  if (el.offsetParent === null && el !== document.body) {
    el.dataset.pendingAutoresize = "1";
    return;
  }
  el.style.overflow = "visible";
  el.style.height = "auto";
  const h = el.scrollHeight;
  el.style.overflow = "hidden";
  el.style.height = Math.max(h, 1) + "px";
  delete el.dataset.pendingAutoresize;
}

function autoResizePackedTextareas() {
  const a = $("custom-frame");
  if (a) autoResizeTextarea(a);
  const b = $("parts-frame-text");
  if (b) autoResizeTextarea(b);
  const c = $("debug-frame");
  if (c) autoResizeTextarea(c);
}

function updatePackedFrameViews() {
  if ($("custom-frame")) {
    $("custom-frame").value = packedFrameToHex(editFrame);
    requestAnimationFrame(() => autoResizeTextarea($("custom-frame")));
  }
  if ($("parts-frame-text")) {
    $("parts-frame-text").value = packedFrameToHex(partsFrame);
    requestAnimationFrame(() => autoResizeTextarea($("parts-frame-text")));
  }
}

// Color, brightness, and mode controls
// Relationship:
// - Initialization functions bind controls in index.html to state setters.
// - setColor()/setBrightness() update the local state, preview frames, and firmware output queue.
// - Auto/Manual mode buttons invoke sendButtonCommand()/queueFirmwareFrame() to sync WebUI and firmware states.
function initColorInput() {
  const input = $("color-input");
  if (!input) return;
  input.addEventListener("input", () => {
    const raw = input.value.trim();
    if (/^#?[0-9a-fA-F]{6}$/.test(raw)) setColor(raw, "color_text_input");
  });
  input.addEventListener("change", () => {
    const normalized = normalizeHexColor(input.value);
    input.value = normalized || state.color;
  });
}

function initColors() {
  initColorInput();
  const parentSelect = $("parent-color-select");
  if (!parentSelect) return;
  parentSelect.innerHTML = "";
  for (const g of parent_color_groups) {
    const opt = document.createElement("option");
    opt.value = String(g.id);
    opt.textContent = `${g.id}. ${g.name}  #${g.color.toUpperCase()}`;
    parentSelect.appendChild(opt);
  }
  parentSelect.value = String(state.parentColorId ?? 0);
  parentSelect.onchange = () => {
    state.parentColorId = Number(parentSelect.value);
    setColorSelection("parent");
    const parentColor =
      parent_color_groups.find((g) => g.id === state.parentColorId)?.color ||
      parent_color_groups[0].color;
    setColor("#" + parentColor, "parent_color_dropdown");
    renderChildColors();
  };
  renderChildColors();
  refreshSelectDropdown("parent-color-select");
}

function renderParentColorButtons() {
  const parentSelect = $("parent-color-select");
  if (parentSelect) parentSelect.value = String(state.parentColorId ?? 0);
  refreshSelectDropdown("parent-color-select");
}

function setColorSelection(selection, childColor = null) {
  state.colorSelection = selection;
  state.selectedChildColor = childColor;
}

function syncColorDropdownsToHex(hex) {
  const normalized = normalizeHexColor(hex);
  if (!normalized) return;
  for (const group of parent_color_groups) {
    if (normalizeHexColor(group.color) === normalized) {
      state.parentColorId = group.id;
      setColorSelection("parent");
      renderParentColorButtons();
      renderChildColors();
      return;
    }
  }
  for (const group of parent_color_groups) {
    for (const [, color] of child_color_groups[group.id] || []) {
      const childHex = normalizeHexColor(color);
      if (childHex === normalized) {
        state.parentColorId = group.id;
        setColorSelection("child", childHex);
        renderParentColorButtons();
        renderChildColors();
        return;
      }
    }
  }
  setColorSelection("custom");
  renderParentColorButtons();
  renderChildColors();
}

function renderChildColors() {
  const childSelect = $("child-color-select");
  if (!childSelect) return;
  childSelect.innerHTML = "";
  const parent =
    parent_color_groups.find((g) => g.id === state.parentColorId) || parent_color_groups[0];
  const useParent = document.createElement("option");
  useParent.value = "__parent__";
  useParent.textContent = `使用父颜色：${parent.name}  #${parent.color.toUpperCase()}`;
  childSelect.appendChild(useParent);
  const rows = child_color_groups[state.parentColorId] || [];
  for (const [name, color] of rows) {
    const opt = document.createElement("option");
    opt.value = ("#" + color).toLowerCase();
    opt.textContent = `${name}  #${color.toUpperCase()}`;
    childSelect.appendChild(opt);
  }
  childSelect.value =
    state.colorSelection === "child" && state.selectedChildColor
      ? state.selectedChildColor
      : "__parent__";
  childSelect.onchange = () => {
    const v = childSelect.value;
    if (v === "__parent__") {
      setColorSelection("parent");
      setColor("#" + parent.color, "child_dropdown_use_parent");
    } else {
      setColorSelection("child", v);
      setColor(v, "child_color_dropdown");
    }
    renderParentColorButtons();
    refreshAllCustomSelects();
  };
  refreshSelectDropdown("child-color-select");
}

function renderPresetButtons(containerId, values, labelForValue, onSelect) {
  const box = $(containerId);
  if (!box) return;
  box.innerHTML = "";
  for (const value of values) {
    const button = document.createElement("button");
    button.type = "button";
    button.dataset.fps = String(value);
    button.textContent = labelForValue(value);
    button.onclick = () => onSelect(value);
    box.appendChild(button);
  }
}

function initBrightness() {
  setClickHandlers([
    ["brightness-minus", () => setBrightness(state.brightness - 8, "B4/WebUI -")],
    ["brightness-plus", () => setBrightness(state.brightness + 8, "B5/WebUI +")],
    ["brightness-reset-default", resetBrightnessDefault],
  ]);
  $("brightness-range").oninput = (e) => setBrightness(e.target.value, "slider");
  $("brightness-input").onchange = (e) => setBrightness(e.target.value, "raw_input");
  renderPresetButtons(
    "brightness-presets",
    [10, 25, 50, 80, 128, 160, 200],
    (value) => String(value),
    (value) => setBrightness(value, "preset"),
  );
}

function resetBrightnessDefault() {
  const value = Number.isFinite(Number(state.defaultBrightness))
    ? state.defaultBrightness
    : DEFAULT_LED_BRIGHTNESS;
  setBrightness(value, "default_brightness_reset");
}

function initBasicControls() {
  setClickHandlers([
    ["face-prev", prevFace],
    ["face-next", nextFace],
    ["mode-toggle", () => toggleMode("WebUI B3")],
    ["interval-down", () => adjustInterval(-AUTO_INTERVAL_BUTTON_STEP_MS)],
    ["interval-up", () => adjustInterval(AUTO_INTERVAL_BUTTON_STEP_MS)],
  ]);
  $("auto-interval-range").oninput = (e) =>
    setAutoIntervalSeconds(e.target.value, "auto_interval_slider");
  $("auto-interval").onchange = (e) =>
    setAutoIntervalSeconds(e.target.value, "auto_interval_input");
  renderPresetButtons(
    "auto-interval-presets",
    AUTO_INTERVAL_PRESETS_MS,
    (ms) => `${formatIntervalSeconds(ms)} s`,
    (ms) => setAutoIntervalMs(ms, "auto_interval_preset"),
  );
  syncAutoIntervalUi();
}

function isAutoModeValue(v) {
  return v === "自动" || v === "auto" || v === "A";
}

function modePayloadValue() {
  return isAutoModeValue(state.mode) ? "auto" : "manual";
}

function updateModeToggleUi() {
  const btn = $("mode-toggle");
  if (!btn) return;
  const isAuto = isAutoModeValue(state.mode);
  btn.classList.toggle("active", isAuto);
  btn.setAttribute("aria-pressed", isAuto ? "true" : "false");
  btn.textContent = isAuto ? "A 自动" : "M 手动";
}

function toggleModeLocal(source) {
  guardBeforeOutput("am_mode_toggle", "face");
  state.mode = isAutoModeValue(state.mode) ? "manual" : "auto";
  renderState();
  log(`A/M 模式切换为 ${state.mode} (${source})`);
  sendAuxCommand(
    "set_mode",
    {
      mode: modePayloadValue(),
      label: state.mode,
    },
    source,
  );
}

function toggleMode(source) {
  sendButtonCommand("B3", source, () => toggleModeLocal(source));
}

function formatIntervalSeconds(ms) {
  return (ms / 1000).toFixed(ms % 1000 ? 1 : 0);
}

function normalizeAutoIntervalMs(ms) {
  return Math.round(clamp(ms, AUTO_INTERVAL_MIN_MS, AUTO_INTERVAL_MAX_MS) / 100) * 100;
}

function syncAutoIntervalUi() {
  const ms = normalizeAutoIntervalMs(state.autoInterval);
  const seconds = formatIntervalSeconds(ms);
  if ($("auto-interval-range")) $("auto-interval-range").value = seconds;
  if ($("auto-interval")) $("auto-interval").value = seconds;
}

function setAutoIntervalMs(ms, source = "auto_interval_change") {
  state.autoInterval = normalizeAutoIntervalMs(ms);
  syncAutoIntervalUi();
  renderState();
  log(
    `自动切换间隔设置为 ${formatIntervalSeconds(state.autoInterval)} 秒 (${state.autoInterval} ms)`,
  );
  sendAuxCommand(
    "set_auto_interval",
    {
      ms: state.autoInterval,
    },
    source,
  );
}

function setAutoIntervalSeconds(seconds, source = "auto_interval_input") {
  setAutoIntervalMs(Number(seconds) * 1000, source);
}

function adjustInterval(delta) {
  setAutoIntervalMs(state.autoInterval + delta, "auto_interval_change");
}

function nextFaceLocal() {
  const library = getAllFaces();
  if (!library.length) return;
  state.faceIndex = (state.faceIndex + 1) % library.length;
  applySavedFace(state.faceIndex, "B1/WebUI next");
}

function prevFaceLocal() {
  const library = getAllFaces();
  if (!library.length) return;
  state.faceIndex = (state.faceIndex - 1 + library.length) % library.length;
  applySavedFace(state.faceIndex, "B2/WebUI prev");
}

function nextFace() {
  sendButtonCommand("B1", "B1/WebUI next", nextFaceLocal);
}

function prevFace() {
  sendButtonCommand("B2", "B2/WebUI prev", prevFaceLocal);
}

function applySavedFace(i, reason = "saved_face_apply") {
  const library = getAllFaces();
  const face = library[i];
  if (!face) return;
  state.faceIndex = i;
  setCurrentFrame(faceFrame(face), reason, "idle");
  renderSavedFaces();
  log(`应用表情 #${i + 1}: ${face.name} / ${faceTypeLabel(face.type)}`);
}

function initCustom() {
  $("custom-clear").onclick = () => {
    editFrame = blankFrame();
    renderMatrices();
    updatePackedFrameViews();
    sendCustomFrameIfLive("custom_live_clear");
    log("自定义画板清空");
  };
  $("custom-fill").onclick = () => {
    editFrame = blankFrame().map(() => true);
    renderMatrices();
    updatePackedFrameViews();
    sendCustomFrameIfLive("custom_live_fill");
    log("自定义画板全亮");
  };
  $("custom-invert").onclick = () => {
    editFrame = editFrame.map((v) => !v);
    renderMatrices();
    updatePackedFrameViews();
    sendCustomFrameIfLive("custom_live_invert");
    log("自定义画板反转");
  };
  $("custom-send").onclick = () => sendCustomFrame("custom_face_send", true);
  $("custom-live-toggle").onclick = () => toggleLiveSend("实时发送");
  $("custom-copy").onclick = () => {
    copyText(packedFrameToHex(editFrame));
    log("复制自定义 packed frame");
  };
  $("custom-import").onclick = () => {
    try {
      editFrame = parsePackedFrameText($("custom-frame").value);
      renderMatrices();
      updatePackedFrameViews();
      log("导入自定义 packed frame 成功");
    } catch (e) {
      alert(e.message);
    }
  };
  $("custom-save").onclick = () =>
    saveFace($("custom-name").value || "custom_face", editFrame, "custom");
  updateLiveToggles();
  initFaceManagerControls();
}

function syncLiveSendBaseline(frame = currentFrame) {
  liveSyncedFrame = cloneFrame(frame || blankFrame());
}

function setLiveSendEnabled(enabled, label = "实时发送") {
  const next = !!enabled;
  if (liveSendEnabled === next) {
    updateLiveToggles();
    if (liveSendEnabled) syncLiveSendBaseline(currentFrame);
    return;
  }
  liveSendEnabled = next;
  if (liveSendEnabled) syncLiveSendBaseline(currentFrame);
  updateLiveToggles();
  log(`${label} ${liveSendEnabled ? "开启" : "关闭"}`);
}

function toggleLiveSend(label = "实时发送") {
  setLiveSendEnabled(!liveSendEnabled, label);
}

function updateLiveToggles() {
  ["custom-live-toggle", "parts-live-toggle"].forEach((id) => {
    const btn = $(id);
    if (!btn) return;
    btn.classList.toggle("active", liveSendEnabled);
    btn.setAttribute("aria-pressed", liveSendEnabled ? "true" : "false");
    btn.textContent = "实时";
    btn.title = liveSendEnabled ? "实时发送已开启" : "实时发送已关闭";
  });
}

function sendCustomFrame(reason = "custom_face_send", writeLog = true) {
  updatePackedFrameViews();
  setCurrentFrame(editFrame, reason, "idle");
  if (writeLog) log("自定义 packed frame 已发送到固件接口");
}

function sendCustomFrameIfLive(reason = "custom_live_send") {
  if (!liveSendEnabled) {
    log("[DIAG-B] liveSendEnabled=false → 跳过发送（实时模式实际未开启）", "warn");
    return;
  }
  // Real-time mode: every LED toggle is equivalent to pressing the custom 发送 button.
  log("[DIAG-B] liveSendEnabled=true → 调用与发送按钮相同的 sendCustomFrame()", "info");
  sendCustomFrame("custom_face_send", false);
}

// During rapid sequential editing (holding/clicking cells), matrix preview and packed-frame textarea refreshes
// are coalesced into the next animation frame to avoid heavy full-page re-renders. Incremental delta commands
// are still dispatched immediately to minimize latency.
let customEditRenderRaf = 0;
function scheduleCustomEditRender() {
  if (customEditRenderRaf) return;
  customEditRenderRaf = requestAnimationFrame(() => {
    customEditRenderRaf = 0;
    renderMatrices();
    updatePackedFrameViews();
  });
}

function editCell(idx, value, tool) {
  editFrame[idx] = !!value;
  // [实时诊断DIAG-A] 一行诊断：确认新代码是否已加载 + 实时开关 + 固件在线状态。
  // 看到带 DIAG-A 的日志即说明新 app.js 已生效。
  log(`[DIAG-A] 点击LED idx=${idx} 目标=${value ? "亮" : "灭"} 实时开关liveSendEnabled=${liveSendEnabled} 固件在线=${firmware.online}`, "info");
  // Dispatch incremental delta changes immediately to keep synchronization latency minimal.
  sendCustomFrameIfLive("custom_live_send");
  // Coalesce local UI rendering into the next animation frame.
  scheduleCustomEditRender();
}

function preferredStartupDefaultId(faces) {
  const list = Array.isArray(faces) ? faces : [];
  return (
    list.find((f) => f.id === DEFAULT_STARTUP_FACE_ID)?.id ||
    list.find((f) => f.is_startup_default)?.id ||
    list.find((f) => f.type === "default")?.id ||
    list[0]?.id ||
    null
  );
}

function startupDefaultFaceIndex() {
  const library = getAllFaces();
  if (!library.length) return -1;
  const startupId = faceLibraryDocument?.startupDefaultId || DEFAULT_STARTUP_FACE_ID;
  let idx = startupId ? library.findIndex((f) => f.id === startupId) : -1;
  if (idx < 0) idx = library.findIndex((f) => f.is_startup_default);
  if (idx < 0) idx = library.findIndex((f) => f.type === "default");
  return idx >= 0 ? idx : 0;
}

function applyStartupDefaultFaceLocal(reason = "text_scroll_stop_default_saved_face") {
  const index = startupDefaultFaceIndex();
  if (index < 0) return false;
  const face = getAllFaces()[index];
  if (!face) return false;
  state.faceIndex = index;
  currentFrame = faceFrame(face);
  if (liveSendEnabled) syncLiveSendBaseline(currentFrame);
  scrollFrame = cloneFrame(currentFrame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  renderMatrices();
  updatePackedFrameViews();
  renderSavedFaces();
  return true;
}

function applyKnownFaceIndexLocal(reason = "firmware_face_index_preview") {
  const library = getAllFaces();
  if (!library.length) return false;
  const index = clamp(Number(state.faceIndex) || 0, 0, library.length - 1);
  const face = library[index];
  if (!face || !Array.isArray(face.frameBytes)) return false;
  state.faceIndex = index;
  currentFrame = faceFrame(face);
  if (liveSendEnabled) syncLiveSendBaseline(currentFrame);
  scrollFrame = cloneFrame(currentFrame);
  state.lastRefreshReason = reason;
  renderMatrices();
  updatePackedFrameViews();
  renderSavedFaces();
  return true;
}
// Saved face library persistence
// Relationship:
// - loadFaceLibrary() reads the default library from LittleFS and merges local/user-saved faces.
// - save/export/import manage JSON payloads; physical matrix updates invoke setCurrentFrame().
// - createFaceRow()/reorderFace()/deleteFace() share the table UI for sections 6.2 and 6.3.
async function loadFaceLibrary() {
  const doc = await loadUnifiedFacesDocument();
  faceLibraryDocument = normalizeFaceDocument(doc, "custom");
  splitFaceLibraryDocument(faceLibraryDocument);
  const library = getAllFaces();
  if (library.length) {
    const startupId = faceLibraryDocument?.startupDefaultId;
    const startupIndex = startupId ? library.findIndex((f) => f.id === startupId) : -1;
    state.faceIndex =
      startupIndex >= 0 ? startupIndex : clamp(state.faceIndex, 0, library.length - 1);
  } else {
    state.faceIndex = 0;
  }
  renderSavedFaces();
  renderState();
  return library;
}

function isFaceLibraryPage(id = document.body?.dataset?.page) {
  return id === "custom" || id === "parts";
}

function refreshFaceLibraryFromFirmware(reason = "face_library_refresh") {
  if (!isFaceLibraryPage()) return Promise.resolve(null);
  if (faceLibraryRefreshInFlight) {
    faceLibraryRefreshQueued = true;
    return faceLibraryRefreshInFlight;
  }
  setFirmwareStatus({
    savedFacesSync: "refreshing saved_faces.json",
  });
  faceLibraryRefreshInFlight = loadFaceLibrary()
    .catch((err) => {
      setFirmwareStatus({
        savedFacesSync: "refresh saved_faces.json failed",
      });
      if (shouldLogApiError()) log(`saved_faces.json auto refresh failed: ${err.message}`, "error");
      return null;
    })
    .finally(() => {
      faceLibraryRefreshInFlight = null;
      if (faceLibraryRefreshQueued) {
        faceLibraryRefreshQueued = false;
        scheduleFaceLibraryRefresh(`${reason}_queued`, 0);
      }
    });
  return faceLibraryRefreshInFlight;
}

function scheduleFaceLibraryRefresh(reason = "face_library_auto_refresh", delay = 240) {
  if (!isFaceLibraryPage()) return;
  window.clearTimeout(faceLibraryRefreshTimer);
  faceLibraryRefreshTimer = window.setTimeout(() => {
    faceLibraryRefreshTimer = 0;
    refreshFaceLibraryFromFirmware(reason);
  }, Math.max(0, delay));
}

function persistFaceDocumentsAndRefresh(reason = "save_faces", delay = 120) {
  return persistFaceDocuments(reason).then((savedToFirmware) => {
    if (savedToFirmware) scheduleFaceLibraryRefresh(reason, delay);
    return savedToFirmware;
  });
}

function initFaceLibraryAutoRefresh() {
  if (faceLibraryAutoRefreshBound) return;
  faceLibraryAutoRefreshBound = true;
  const skipButtonIds = new Set([
    "custom-save",
    "parts-save-bottom",
  ]);
  ["page-custom", "page-parts"].forEach((pageId) => {
    const page = $(pageId);
    if (!page) return;
    page.addEventListener("click", (ev) => {
      const button = ev.target?.closest?.("button");
      if (!button || button.closest(".face-library-list")) return;
      if (skipButtonIds.has(button.id)) return;
      if (button.classList.contains("faces-json-load")) return;
      if (button.classList.contains("faces-json-open-local")) return;
      if (button.classList.contains("faces-json-save-local")) return;
      if (button.classList.contains("faces-json-import-btn")) return;
      scheduleFaceLibraryRefresh("face_page_button_action");
    });
    page.addEventListener("change", (ev) => {
      const target = ev.target;
      if (!target || target.closest?.(".face-library-list")) return;
      if (target.classList?.contains("faces-json-import-file")) return;
      if (
        target instanceof HTMLInputElement ||
        target instanceof HTMLTextAreaElement ||
        target instanceof HTMLSelectElement
      ) {
        scheduleFaceLibraryRefresh("face_page_field_change");
      }
    });
    page.addEventListener(
      "pointerup",
      (ev) => {
        const target = ev.target;
        if (!target || target.closest?.("button,input,textarea,select,.face-library-list")) return;
        if (target.closest?.("#matrix-custom-edit,#part-groups")) {
          scheduleFaceLibraryRefresh("face_page_pointer_action", 480);
        }
      },
      {
        passive: true,
      },
    );
  });
}

async function fetchJsonDocument(path) {
  const res = await fetch(path, {
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText || ""}`.trim());
  return res.json();
}
async function loadUnifiedFacesDocument() {
  const empty = {
    format: FACE_SCHEMA_FORMAT,
    version: 4,
    category: "unified_saved_faces",
    matrix: {
      leds: TOTAL_LEDS,
      frameBytes: PACKED_FRAME_BYTES,
      frameEncoding: "packed-lsb-first",
    },
    startupDefaultId: DEFAULT_STARTUP_FACE_ID,
    updatedAt: null,
    faces: [],
  };
  try {
    const apiDoc = await apiGet(API_ENDPOINTS.savedFaces);
    faceLibraryLoadError = "";
    setFirmwareStatus({
      savedFacesSync: "loaded from /api/saved_faces",
    });
    return apiDoc;
  } catch (apiErr) {
    const candidates =
      location.protocol === "file:"
        ? [FACE_LIBRARY_FILENAME]
        : [FACE_LIBRARY_RESOURCE, FACE_LIBRARY_FILENAME];
    for (const path of candidates) {
      try {
        const doc = await fetchJsonDocument(path);
        faceLibraryLoadError = "";
        setFirmwareStatus({
          savedFacesSync: `loaded from ${path}`,
        });
        return doc;
      } catch (fileErr) {}
    }
    setFirmwareStatus({
      savedFacesSync:
        location.protocol === "file:"
          ? "file:// cannot auto-read JSON; import saved_faces.json"
          : "saved_faces.json not found",
    });
    faceLibraryLoadError =
      location.protocol === "file:"
        ? ""
        : "无法加载 saved_faces.json：/api/saved_faces 与本地资源均不可用。";
    log(
      location.protocol === "file:"
        ? "浏览器 file:// 通常不能自动读取旁边的 saved_faces.json；请点击“导入 saved_faces.json”。"
        : "saved_faces.json 未读取到，使用空表情库。",
    );
    return empty;
  }
}

function splitFaceLibraryDocument(doc) {
  const faces = Array.isArray(doc?.faces) ? doc.faces : [];
  defaultFaces = faces
    .filter((f) => f.type === "default")
    .map((f, i) => ({
      ...f,
      type: "default",
      editable: true,
      deletable: false,
      locked: true,
      is_startup_default: !!f.is_startup_default || f.id === DEFAULT_STARTUP_FACE_ID,
      sourceFile: FACE_LIBRARY_FILENAME,
      order: Number.isFinite(Number(f.order)) ? Number(f.order) : i + 1,
    }));
  userFaces = faces
    .filter((f) => f.type !== "default")
    .map((f, i) => ({
      ...f,
      type: normalizeFaceType(f.type),
      editable: true,
      deletable: true,
      locked: false,
      is_startup_default: false,
      sourceFile: FACE_LIBRARY_FILENAME,
      order: Number.isFinite(Number(f.order)) ? Number(f.order) : 10001 + i,
    }));
}

function faceOrderFromIndex(index) {
  return Math.max(1, Number(index) + 1);
}

function normalizeFaceDocument(doc, fallbackType = "custom") {
  const out =
    doc && typeof doc === "object" && !Array.isArray(doc)
      ? {
          ...doc,
        }
      : {
          format: FACE_SCHEMA_FORMAT,
          version: 4,
          faces: Array.isArray(doc) ? doc : [],
        };
  out.format = FACE_SCHEMA_FORMAT;
  out.version = Number(out.version || 4);
  out.category = "unified_saved_faces";
  out.matrix = {
    leds: TOTAL_LEDS,
    frameBytes: PACKED_FRAME_BYTES,
    frameEncoding: "packed-lsb-first",
  };
  out.faces = Array.isArray(out.faces) ? out.faces : [];
  out.faces = out.faces.map((f, i) => normalizeFace(f, i, fallbackType)).filter(Boolean);
  out.startupDefaultId = preferredStartupDefaultId(out.faces);
  out.updatedAt = out.updatedAt || null;
  return out;
}

function displayNameFromId(id) {
  return String(id || "face")
    .replace(/^face_?/, "")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function normalizeFace(f, i = 0, fallbackType = "custom") {
  if (!f || typeof f !== "object") return null;
  // Faces are stored as packed frameBytes (47 bytes). Reject anything that is not a
  // valid 47-byte packed frame — legacy text/hex face formats are no longer accepted.
  if (!Array.isArray(f.frameBytes) || f.frameBytes.length !== PACKED_FRAME_BYTES) return null;
  const frameBytes = f.frameBytes.map((v) => Number(v) & 255);
  const type = normalizeFaceType(f.type || f.source || fallbackType);
  const id = String(f.id || `${type}_${i + 1}`);
  return {
    id,
    name: String(f.name || displayNameFromId(id)).slice(0, 64),
    type,
    frameBytes,
    order: Number.isFinite(Number(f.order)) ? Number(f.order) : faceOrderFromIndex(i),
    editable: true,
    deletable: type !== "default",
    locked: type === "default" ? true : !!f.locked,
    is_startup_default: !!f.is_startup_default || id === DEFAULT_STARTUP_FACE_ID,
    sourceFile: FACE_LIBRARY_FILENAME,
    savedAt: f.savedAt || f.createdAt || null,
    updatedAt: f.updatedAt || null,
    call: f.call || null,
  };
}

function normalizeFaceType(v) {
  const s = String(v || "custom").toLowerCase();
  if (s.includes("default")) return "default";
  if (s.includes("part")) return "parts";
  if (s.includes("custom")) return "custom";
  return "custom";
}

function faceTypeLabel(type) {
  return type === "default"
    ? "默认表情"
    : type === "parts"
      ? "部件表情"
      : type === "custom"
        ? "自定义表情"
        : "保存表情";
}

function getAllFaces() {
  return [...defaultFaces, ...userFaces]
    .map((f, idx) => ({
      ...f,
      _stableIndex: idx,
    }))
    .sort(
      (a, b) =>
        (Number(a.order) || 0) - (Number(b.order) || 0) || String(a.id).localeCompare(String(b.id)),
    );
}

function reassignOrderFromLibrary(library) {
  const defaultById = new Map(defaultFaces.map((f) => [f.id, f]));
  const userById = new Map(userFaces.map((f) => [f.id, f]));
  library.forEach((f, i) => {
    const target = f.type === "default" ? defaultById.get(f.id) : userById.get(f.id);
    if (target) target.order = faceOrderFromIndex(i);
  });
  defaultFaces = [...defaultFaces].sort((a, b) => a.order - b.order);
  userFaces = [...userFaces].sort((a, b) => a.order - b.order);
}

function buildUnifiedFaceDocument() {
  const faces = getAllFaces()
    .map((f, i) => {
      const normalized = normalizeFace(
        {
          ...f,
          order: faceOrderFromIndex(i),
        },
        i,
        f.type || "custom",
      );
      if (!normalized) return null;
      normalized.editable = true;
      normalized.deletable = normalized.type !== "default";
      normalized.sourceFile = FACE_LIBRARY_FILENAME;
      return normalized;
    })
    .filter(Boolean);
  return {
    format: FACE_SCHEMA_FORMAT,
    version: 4,
    category: "unified_saved_faces",
    matrix: {
      leds: TOTAL_LEDS,
      frameBytes: PACKED_FRAME_BYTES,
      frameEncoding: "packed-lsb-first",
    },
    startupDefaultId: preferredStartupDefaultId(faces),
    updatedAt: new Date().toISOString(),
    faces,
  };
}
async function saveFaceLibraryToLocalFile() {
  if (!faceLibraryFileHandle)
    throw new Error(
      "尚未打开本地文件。请先点击“打开本地文件”，或使用下载/导入流程。",
    );
  if (!window.showOpenFilePicker && !faceLibraryFileHandle.createWritable)
    throw new Error("当前浏览器不支持 File System Access API。请使用“下载表情列表”。");
  const writable = await faceLibraryFileHandle.createWritable();
  await writable.write(JSON.stringify(faceLibraryDocument || buildUnifiedFaceDocument(), null, 2));
  await writable.close();
  setFirmwareStatus({
    savedFacesSync: "saved to opened local saved_faces.json",
  });
  log("已保存到已打开的本地表情列表文件");
}
async function openLocalFaceLibraryFile() {
  if (!window.showOpenFilePicker) {
    alert(
      "当前浏览器不支持直接打开并写回本地文件。请使用“导入表情”与“下载表情列表”。",
    );
    return;
  }
  const [handle] = await window.showOpenFilePicker({
    multiple: false,
    types: [
      {
        description: "Rina saved_faces.json",
        accept: {
          "application/json": [".json"],
        },
      },
    ],
  });
  faceLibraryFileHandle = handle;
  const file = await handle.getFile();
  await importFacesJsonText(await file.text(), "open_local_saved_faces_json");
  setFirmwareStatus({
    savedFacesSync: `opened local ${file.name}`,
  });
  log(`已打开本地 ${file.name}；之后排序/重命名会优先写回这个文件。`);
}
async function persistFaceDocuments(reason = "save_faces") {
  faceLibraryDocument = buildUnifiedFaceDocument();
  splitFaceLibraryDocument(faceLibraryDocument);
  if (faceLibraryFileHandle) {
    try {
      await saveFaceLibraryToLocalFile();
    } catch (localErr) {
      setFirmwareStatus({
        savedFacesSync: "local save failed; trying firmware API",
      });
      log(`本地 saved_faces.json 写入失败：${localErr.message}`);
    }
  }
  setFirmwareStatus({
    savedFacesSync: "saving unified saved_faces.json",
  });
  return apiPost(API_ENDPOINTS.savedFaces, {
    path: FACE_LIBRARY_RESOURCE,
    document: faceLibraryDocument,
    reason,
  })
    .then(() => {
      setFirmwareStatus({
        savedFacesSync: "saved to firmware saved_faces.json",
      });
      // Only when the POST of /api/saved_faces returns successfully can it be truly synchronized to the firmware.
      log(`saved_faces.json 已同步到固件：默认 ${defaultFaces.length} 项，用户 ${userFaces.length} 项`);
      return true;
    })
    .catch((err) => {
      setFirmwareStatus({
        savedFacesSync: faceLibraryFileHandle
          ? "saved locally; firmware offline"
          : "save failed/offline; use JSON download/import",
      });
      // POST failed: MUST NOT remember "synchronized". Record the real results truthfully (including whether they have been written to local files).
      const detail = err?.message ? `：${err.message}` : "";
      if (faceLibraryFileHandle) {
        log(`saved_faces.json 已写入本地文件，但同步到固件失败${detail}`, "warn");
      } else {
        log(`saved_faces.json 同步到固件失败${detail}；改动未写回固件，请使用下载/导入 JSON 流程`, "error");
      }
      return false;
    })
    .finally(() => {
      // Only perform UI refreshes that have nothing to do with success or failure; do not record conclusive logs such as "synchronized" here.
      renderState();
    });
}

function downloadJsonFile(filename, doc) {
  const blob = new Blob([JSON.stringify(doc, null, 2)], {
    type: "application/json",
  });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  URL.revokeObjectURL(a.href);
}

function downloadFacesJson() {
  downloadJsonFile("saved_faces.json", buildUnifiedFaceDocument());
  log("已导出表情列表");
}
async function importFacesJsonText(text, reason = "import_saved_faces_json") {
  faceLibraryLoadError = "";
  faceLibraryDocument = normalizeFaceDocument(JSON.parse(text), "custom");
  splitFaceLibraryDocument(faceLibraryDocument);
  state.faceIndex = 0;
  renderSavedFaces();
  renderState();
  await persistFaceDocumentsAndRefresh(reason);
  log(`已导入表情列表：默认 ${defaultFaces.length} 项，用户 ${userFaces.length} 项`);
}
async function importFacesJsonFile(file) {
  await importFacesJsonText(await file.text(), "import_saved_faces_json");
}

function initFaceManagerControls() {
  bindControls(".faces-json-load", "click", () => loadFaceLibrary());
  bindControls(".faces-json-open-local", "click", () =>
    openLocalFaceLibraryFile().catch((err) => alert(err.message)),
  );
  bindControls(".faces-json-save-local", "click", () => {
    faceLibraryDocument = buildUnifiedFaceDocument();
    saveFaceLibraryToLocalFile().catch((err) => alert(err.message));
  });
  bindControls(".faces-json-download-all", "click", downloadFacesJson);
  bindControls(".faces-json-import-btn", "click", (e) =>
    e.currentTarget.parentElement.querySelector(".faces-json-import-file")?.click(),
  );
  bindControls(".faces-json-import-file", "change", (e) => {
    const file = e.currentTarget.files?.[0];
    if (file) importFacesJsonFile(file).catch((err) => alert(err.message));
    e.currentTarget.value = "";
  });
}

function saveFace(name, frame, type) {
  const faceType = normalizeFaceType(type);
  if (faceType === "default")
    throw new Error(
      '不能通过保存按钮新建默认表情；默认表情只能来自 saved_faces.json 的 type:"default" 项。',
    );
  const clean =
    String(name || "face")
      .trim()
      .slice(0, 64) || "face";
  const nextOrder = Math.max(0, ...getAllFaces().map((f) => Number(f.order) || 0)) + 1;
  userFaces.push({
    id: `${faceType}_${Date.now()}`,
    name: clean,
    type: faceType,
    frameBytes: Array.from(frameToUint8Array(frame)),
    order: nextOrder,
    editable: true,
    deletable: true,
    sourceFile: FACE_LIBRARY_FILENAME,
    savedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    call:
      faceType === "parts"
        ? {
            ...selectedCall,
          }
        : null,
  });
  state.faceIndex = getAllFaces().findIndex((f) => f.id === userFaces[userFaces.length - 1].id);
  renderSavedFaces();
  renderState();
  log(`保存${faceTypeLabel(faceType)}: ${clean}`);
  persistFaceDocumentsAndRefresh("save_user_face");
}

function renderSavedFaces() {
  const lists = document.querySelectorAll(".face-library-list");
  if (!lists.length) return;
  const library = getAllFaces();
  lists.forEach((box) => {
    box.innerHTML = "";
    const frag = document.createDocumentFragment();
    if (!library.length) {
      if (faceLibraryLoadError) frag.appendChild(createFaceLibraryErrorRow(faceLibraryLoadError));
      box.appendChild(frag);
      return;
    }
    library.forEach((f, i) => {
      const row = createFaceRow(f, i, library.length);
      row.classList.toggle("active", i === state.faceIndex);
      frag.appendChild(row);
    });
    box.appendChild(frag);
  });
  renderState();
}

function createFaceLibraryErrorRow(message) {
  const row = document.createElement("div");
  row.className = "saved-row saved-row-error";
  row.dataset.index = "-1";
  row.dataset.faceId = "load_error";

  const index = document.createElement("div");
  index.className = "saved-index";
  index.textContent = "!";

  const item = document.createElement("div");
  item.className = "list-item saved-face-card";

  const handle = document.createElement("button");
  handle.className = "drag-handle";
  handle.type = "button";
  handle.title = "无法排序";
  handle.setAttribute("aria-label", "无法排序");
  handle.disabled = true;

  const body = document.createElement("div");
  body.className = "saved-face-body";
  const nameInput = document.createElement("input");
  nameInput.className = "saved-name-input";
  nameInput.value = "无法加载 saved_faces.json";
  nameInput.readOnly = true;
  const meta = document.createElement("div");
  meta.className = "small saved-meta";
  meta.textContent = message || "无法加载表情列表。";
  body.appendChild(nameInput);
  body.appendChild(meta);

  const actions = document.createElement("div");
  actions.className = "face-action-bar";
  const mkDisabled = (label, title, cls = "") => {
    const b = document.createElement("button");
    b.type = "button";
    b.title = title;
    b.setAttribute("aria-label", title);
    b.className = "icon-btn" + (cls ? " " + cls : "");
    b.textContent = label;
    b.disabled = true;
    return b;
  };
  actions.appendChild(mkDisabled("↑", "无法上移"));
  actions.appendChild(mkDisabled("↓", "无法下移"));
  actions.appendChild(mkDisabled("✏️", "无法重命名"));
  actions.appendChild(mkDisabled("🗑️", "无法删除", "btn-delete"));
  actions.appendChild(mkDisabled("💡", "无法上传到固件", "btn-apply"));

  item.appendChild(handle);
  item.appendChild(body);
  item.appendChild(actions);
  row.appendChild(index);
  row.appendChild(item);
  return row;
}

function clearFaceDragOver(scope = document) {
  scope
    .querySelectorAll(".saved-row.drag-over,.saved-row.insert-before,.saved-row.insert-after")
    .forEach((x) => x.classList.remove("drag-over", "insert-before", "insert-after"));
}

function faceInsertSlotFromPoint(clientX, clientY, list) {
  const rows = Array.from(list.querySelectorAll(".saved-row"))
    .map((row) => ({ row, index: Number(row.dataset.index) }))
    .filter((entry) => Number.isInteger(entry.index) && entry.index >= 0)
    .sort((a, b) => a.index - b.index);
  if (!rows.length) return null;

  const target = document.elementFromPoint(clientX, clientY);
  const row = target && target.closest && target.closest(".saved-row");
  if (row && row.closest(".face-library-list") === list) {
    const index = Number(row.dataset.index);
    if (!Number.isInteger(index) || index < 0) return null;
    const rect = row.getBoundingClientRect();
    return clientY < rect.top + rect.height / 2 ? index : index + 1;
  }

  const first = rows[0].row.getBoundingClientRect();
  if (clientY < first.top) return 0;
  const lastEntry = rows[rows.length - 1];
  const last = lastEntry.row.getBoundingClientRect();
  if (clientY > last.bottom) return lastEntry.index + 1;
  return null;
}

function showFaceInsertIndicator(list, slot, from) {
  clearFaceDragOver(list);
  if (!Number.isInteger(slot) || slot === from || slot === from + 1) return;
  const targetSlot = Math.max(0, slot);
  const beforeRow = list.querySelector(`.saved-row[data-index="${targetSlot}"]`);
  if (beforeRow) {
    beforeRow.classList.add("insert-before");
    return;
  }
  const afterRow = list.querySelector(`.saved-row[data-index="${targetSlot - 1}"]`);
  if (afterRow) afterRow.classList.add("insert-after");
}

function autoScrollFaceList(clientY) {
  const margin = 76;
  const step = 18;
  if (clientY < margin)
    window.scrollBy({
      top: -step,
      behavior: "auto",
    });
  else if (clientY > window.innerHeight - margin)
    window.scrollBy({
      top: step,
      behavior: "auto",
    });
}

function attachFaceReorderHandle(handle, row, index) {
  handle.draggable = false;
  handle.addEventListener("pointerdown", (ev) => {
    if (ev.button !== undefined && ev.button !== 0) return;
    const list = row.closest(".face-library-list");
    if (!list) return;
    ev.preventDefault();
    pointerFaceDrag = {
      from: index,
      slot: index,
      list,
      row,
      pointerId: ev.pointerId,
    };
    row.classList.add("dragging");
    handle.setPointerCapture?.(ev.pointerId);
  });
  handle.addEventListener("pointermove", (ev) => {
    if (!pointerFaceDrag || pointerFaceDrag.pointerId !== ev.pointerId) return;
    ev.preventDefault();
    autoScrollFaceList(ev.clientY);
    const slot = faceInsertSlotFromPoint(ev.clientX, ev.clientY, pointerFaceDrag.list);
    if (slot === null) return;
    pointerFaceDrag.slot = slot;
    showFaceInsertIndicator(pointerFaceDrag.list, slot, pointerFaceDrag.from);
  });
  const finish = (ev) => {
    if (!pointerFaceDrag || pointerFaceDrag.pointerId !== ev.pointerId) return;
    ev.preventDefault();
    const { from, slot, list, row: dragRow } = pointerFaceDrag;
    handle.releasePointerCapture?.(ev.pointerId);
    clearFaceDragOver(list);
    dragRow.classList.remove("dragging");
    pointerFaceDrag = null;
    if (Number.isInteger(slot) && slot !== from && slot !== from + 1) {
      reorderFace(from, from < slot ? slot - 1 : slot);
    }
  };
  handle.addEventListener("pointerup", finish);
  handle.addEventListener("pointercancel", finish);
}

function createFaceRow(f, i, total) {
  const row = document.createElement("div");
  row.className = "saved-row";
  row.dataset.index = i;
  row.dataset.faceId = f.id;
  const index = document.createElement("div");
  index.className = "saved-index";
  index.textContent = String(i + 1);
  const item = document.createElement("div");
  item.className = "list-item saved-face-card";

  // Drag handle
  const handle = document.createElement("button");
  handle.className = "drag-handle";
  handle.type = "button";
  handle.draggable = false;
  handle.title = "拖拽排序";
  handle.setAttribute("aria-label", "拖拽排序");
  attachFaceReorderHandle(handle, row, i);

  // Middle: naming box + metadata badge
  const body = document.createElement("div");
  body.className = "saved-face-body";
  const nameInput = document.createElement("input");
  nameInput.className = "saved-name-input";
  nameInput.value = f.name || `face_${i + 1}`;
  nameInput.maxLength = 64;
  nameInput.title =
    f.type === "default"
      ? "默认表情可重命名、可排序，但不可删除；回车或失焦保存"
      : "直接编辑名称后回车或失焦保存";
  const commitName = () => {
    const next = nameInput.value.trim().slice(0, 64) || f.name || `face_${i + 1}`;
    const list = f.type === "default" ? defaultFaces : userFaces;
    const target = list.find((x) => x.id === f.id);
    if (target && target.name !== next) {
      target.name = next;
      target.updatedAt = new Date().toISOString();
      persistFaceDocumentsAndRefresh(
        f.type === "default" ? "rename_default_face" : "rename_user_face",
      );
      renderState();
      log(`重命名${faceTypeLabel(target.type)} #${i + 1}: ${next}`);
    }
    nameInput.value = next;
  };
  nameInput.addEventListener("change", commitName);
  nameInput.addEventListener("blur", commitName);
  nameInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") nameInput.blur();
  });
  const meta = document.createElement("div");
  meta.className = "small saved-meta";
  const badgeClass = f.type === "default" ? "default" : f.type === "parts" ? "parts" : "custom";
  meta.innerHTML = `<span class="face-source-badge ${badgeClass}">${faceTypeLabel(f.type)}</span> · ${onCount(faceFrame(f))} LED`;
  body.appendChild(nameInput);
  body.appendChild(meta);

  // Right operation bar: Apply/Move up/Move down/Rename/Delete
  const actions = document.createElement("div");
  actions.className = "face-action-bar";

  const mkBtn = (label, title, cls, fn, disabled) => {
    const b = document.createElement("button");
    b.type = "button";
    b.title = title;
    b.setAttribute("aria-label", title);
    b.className = "icon-btn" + (cls ? " " + cls : "");
    b.textContent = label;
    b.disabled = !!disabled;
    b.onclick = fn;
    return b;
  };

  actions.appendChild(mkBtn("↑", "上移", "", () => moveFace(i, -1), i <= 0));
  actions.appendChild(mkBtn("↓", "下移", "", () => moveFace(i, 1), i >= total - 1));
  actions.appendChild(
    mkBtn("✏️", "重命名", "", () => {
      nameInput.focus();
      nameInput.select();
    }),
  );
  if (f.type !== "default") {
    actions.appendChild(mkBtn("🗑️", "删除", "btn-delete", () => deleteFace(i)));
  } else {
    const nd = mkBtn("🗑️", "默认表情不可删除", "btn-delete", () => {}, true);
    nd.style.opacity = ".35";
    actions.appendChild(nd);
  }
  actions.appendChild(
    mkBtn("💡", "上传到固件（应用表情）", "btn-apply", () =>
      applySavedFace(i, "face_library_list"),
    ),
  );

  item.appendChild(handle);
  item.appendChild(body);
  item.appendChild(actions);
  row.appendChild(index);
  row.appendChild(item);
  return row;
}

function moveFace(i, d) {
  reorderFace(i, i + d);
}

function reorderFace(from, to) {
  const library = getAllFaces();
  from = Number(from);
  to = Number(to);
  if (
    !Number.isInteger(from) ||
    !Number.isInteger(to) ||
    from < 0 ||
    to < 0 ||
    from >= library.length ||
    to >= library.length ||
    from === to
  )
    return;
  const [moved] = library.splice(from, 1);
  library.splice(to, 0, moved);
  reassignOrderFromLibrary(library);
  state.faceIndex = to;
  persistFaceDocumentsAndRefresh("reorder_faces");
  renderSavedFaces();
  log(`表情排序 ${from + 1} -> ${to + 1}`);
}

function deleteFace(i) {
  const library = getAllFaces();
  const face = library[i];
  if (!face) return;
  if (face.type === "default") {
    alert("默认表情不可删除，但可以排序和重命名。");
    return;
  }
  if (!confirm(`删除该${faceTypeLabel(face.type)}？`)) return;
  userFaces = userFaces.filter((f) => f.id !== face.id);
  state.faceIndex = getAllFaces().length ? clamp(state.faceIndex, 0, getAllFaces().length - 1) : 0;
  persistFaceDocumentsAndRefresh("delete_user_face");
  renderSavedFaces();
  log(`删除${faceTypeLabel(face.type)} #${i + 1}`);
}

// Expression widget combiner
// Connection relationship:
// - initParts() generates 6.3 part buttons with EXPRESSION_PARTS.
// - selectPart()/randomParts() changes selectedCall.
// - composePartsFrame() converts selectedCall into partsFrame, and then passes it to the matrix preview and firmware queue.
// - The symmetrical eye logic only changes the selection state and does not directly change the DOM; renderPartButtons() is responsible for display synchronization.
function initParts() {
  const groups = $("part-groups");
  groups.innerHTML = "";
  const labels = {
    leye: "leye 左眼",
    reye: "reye 右眼",
    mouth: "mouth 嘴巴",
    cheek: "cheek 脸颊",
  };
  for (const key of ["leye", "reye", "mouth", "cheek"]) {
    const card = document.createElement("div");
    card.className = "card stack";
    card.innerHTML = `<h3>${labels[key]}</h3><div class="part-list" id="parts-list-${key}"></div>`;
    groups.appendChild(card);
    const list = card.querySelector(".part-list");
    EXPRESSION_PARTS.call.ids[key].forEach((id, displayIndex) => {
      const resolved = resolvePartId(key, id);
      const part = EXPRESSION_PARTS.parts[resolved] || EXPRESSION_PARTS.parts["0"];
      const assetName = part.name || `asset_${resolved}`;
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "part-card" + (key === "cheek" ? " cheek-card" : "");
      btn.dataset.key = key;
      btn.dataset.id = id;
      btn.title = `显示编号 ${displayIndex} / 调用 ID ${id} / asset ${assetName}`;
      const metaHtml = `<div class="part-meta"><b class="part-display-id">${displayIndex}</b></div>`;
      btn.innerHTML = `${miniPreviewHtml(part)}${metaHtml}`;
      btn.onclick = () => selectPart(key, String(id));
      list.appendChild(btn);
    });
  }
  $("parts-apply").onclick = () => sendPartsFrame();
  $("parts-live-toggle").onclick = () => toggleLiveSend("实时发送");
  $("parts-random").onclick = () => {
    randomParts();
    sendPartsFrame("parts_random_send");
  };
  $("parts-symmetry-toggle").onclick = () => {
    partsSymmetry = !partsSymmetry;
    if (partsSymmetry) syncSymmetricEyesFrom("leye");
    composePartsFrame();
    renderPartButtons();
    sendPartsFrameIfLive("parts_live_symmetry");
    log(`左右眼对称 ${partsSymmetry ? "开启" : "关闭"}`);
  };
  $("parts-reset").onclick = () => {
    selectedCall = {
      leye: "101",
      reye: "201",
      mouth: "301",
      cheek: "400",
    };
    if (partsSymmetry) syncSymmetricEyesFrom("leye");
    composePartsFrame();
    renderPartButtons();
    sendPartsFrameIfLive("parts_live_reset");
    log("表情部件恢复默认");
  };
  const _copyPartsFrame = () => {
    copyText(packedFrameToHex(partsFrame));
    log("复制 packed frame");
  };
  $("parts-copy-frame").onclick = _copyPartsFrame;
  $("parts-save-bottom").onclick = () =>
    saveFace(
      $("parts-name").value ||
        `parts_${selectedCall.leye}_${selectedCall.reye}_${selectedCall.mouth}_${selectedCall.cheek}`,
      partsFrame,
      "parts",
    );
  $("parts-import-frame").onclick = () => {
    try {
      setCurrentFrame(parsePackedFrameText($("parts-frame-text").value), "parts_frame_import", "idle");
      log("部件页 packed frame 文本已应用到当前输出");
    } catch (e) {
      alert(e.message);
    }
  };
  initFaceManagerControls();
  composePartsFrame();
  renderPartButtons();
  updateLiveToggles();
}

function getPartDisplayIndex(key, id) {
  return EXPRESSION_PARTS.call.ids[key].findIndex((x) => String(x) === String(id));
}

function callIdAtDisplayIndex(key, index) {
  const ids = EXPRESSION_PARTS.call.ids[key] || [];
  return String(ids[clamp(index, 0, ids.length - 1)] ?? ids[0] ?? "0");
}

function syncSymmetricEyesFrom(sourceKey) {
  const src = sourceKey === "reye" ? "reye" : "leye";
  const idx = getPartDisplayIndex(src, selectedCall[src]);
  const safeIdx = idx >= 0 ? idx : 0;
  selectedCall.leye = callIdAtDisplayIndex("leye", safeIdx);
  selectedCall.reye = callIdAtDisplayIndex("reye", safeIdx);
}

function selectPart(key, id) {
  selectedCall[key] = String(id);
  if (partsSymmetry && (key === "leye" || key === "reye")) syncSymmetricEyesFrom(key);
  composePartsFrame();
  renderPartButtons();
  sendPartsFrameIfLive("parts_live_select");
}

function miniPreviewHtml(part) {
  const rows = previewRows(part);
  let s = '<div class="part-mini">';
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      s += `<span class="pix${rows[y] && rows[y][x] === "#" ? " on" : ""}"></span>`;
    }
  }
  return s + "</div>";
}

function previewRows(part) {
  const size = part.size || [8, 8];
  const w = clamp(size[0] || 8, 1, 8),
    h = clamp(size[1] || 8, 1, 8);
  const out = Array.from(
    {
      length: 8,
    },
    () => ".".repeat(8).split(""),
  );
  const ox = Math.floor((8 - w) / 2),
    oy = Math.floor((8 - h) / 2);
  if (
    part.preview &&
    part.preview.length >= h &&
    part.preview.every((r) => String(r).length >= w)
  ) {
    for (let y = 0; y < h; y++) {
      const row = String(part.preview[y] || "")
        .padEnd(w, ".")
        .slice(0, w);
      for (let x = 0; x < w; x++) if (row[x] === "#") out[oy + y][ox + x] = "#";
    }
    return out.map((r) => r.join(""));
  }
  for (let y = 0; y < h; y++) {
    const raw = (part.row_hex || [])[y] || "00";
    const bits = parseInt(raw, 16);
    for (let x = 0; x < w; x++) if (bits & (1 << (7 - x))) out[oy + y][ox + x] = "#";
  }
  return out.map((r) => r.join(""));
}

function renderPartButtons() {
  for (const key of ["leye", "reye", "mouth", "cheek"]) {
    document
      .querySelectorAll(`[data-key="${key}"]`)
      .forEach((b) => b.classList.toggle("active", b.dataset.id === String(selectedCall[key])));
  }
  const sym = $("parts-symmetry-toggle");
  if (sym) {
    sym.classList.toggle("active", !!partsSymmetry);
    sym.setAttribute("aria-pressed", partsSymmetry ? "true" : "false");
  }
}

function randomParts() {
  if (partsSymmetry) {
    const maxEyeIndex =
      Math.min(EXPRESSION_PARTS.call.ids.leye.length, EXPRESSION_PARTS.call.ids.reye.length) - 1;
    const eyeIndex = 1 + Math.floor(Math.random() * Math.max(1, maxEyeIndex));
    selectedCall.leye = callIdAtDisplayIndex("leye", eyeIndex);
    selectedCall.reye = callIdAtDisplayIndex("reye", eyeIndex);
  } else {
    for (const key of ["leye", "reye"]) {
      let arr = EXPRESSION_PARTS.call.ids[key].filter((id) => String(id) !== "0");
      selectedCall[key] = String(arr[Math.floor(Math.random() * arr.length)]);
    }
  }
  for (const key of ["mouth", "cheek"]) {
    let arr = EXPRESSION_PARTS.call.ids[key].slice();
    if (key !== "cheek") arr = arr.filter((id) => String(id) !== "0");
    // cheek=400 indicates an explicit empty cheek call, which still works in random mode.
    selectedCall[key] = String(arr[Math.floor(Math.random() * arr.length)]);
  }
  composePartsFrame();
  renderPartButtons();
  log(
    partsSymmetry
      ? "随机选择表情部件（左右眼同编号，嘴巴不选 0，脸颊允许 400）"
      : "随机选择表情部件（眼睛/嘴巴不选 0，脸颊允许 400）",
  );
}

// Text scrolling timeline
// Connection relationship:
// - The input box and FPS control are first cleaned to scroll.text/currentFps.
// - prepareTextScrollTimeline() generates browser preview frames using Ark bitmaps.
// - uploadFirmwareScrollTimeline() sends the same batch of frames to /api/scroll in chunks.
// - start/pause/resume/stop maintains local preview status and firmware playback status at the same time.
function truncateScrollText(text) {
  const out = [];
  let visibleCount = 0;
  for (const ch of Array.from(String(text ?? ""))) {
    if (!isEmojiFormatControl(codePointOfChar(ch))) visibleCount++;
    if (visibleCount > MAX_SCROLL_TEXT_CHARS) break;
    out.push(ch);
  }
  return out.join("");
}

function scrollTextVisibleCharCount(text) {
  let visibleCount = 0;
  for (const ch of Array.from(normalizeTextScrollEmojiPresentation(String(text ?? "")))) {
    if (!isEmojiFormatControl(codePointOfChar(ch))) visibleCount++;
  }
  return visibleCount;
}

function scrollTextExceedsUiCharLimit(text) {
  return scrollTextVisibleCharCount(text) > MAX_SCROLL_TEXT_CHARS;
}

function normalizeScrollTextForCompare(text) {
  return truncateScrollText(normalizeTextScrollEmojiPresentation(String(text ?? "")));
}

function sanitizeScrollTextInput(commit = false) {
  const el = $("scroll-text");
  const raw = el ? String(el.value ?? "") : "";
  const normalized = normalizeTextScrollEmojiPresentation(raw);
  const clean = truncateScrollText(normalized);
  if (commit && el && raw !== clean) {
    const selectionStart = el.selectionStart ?? clean.length;
    const selectionEnd = el.selectionEnd ?? selectionStart;
    const nextStart = truncateScrollText(
      normalizeTextScrollEmojiPresentation(raw.slice(0, selectionStart)),
    ).length;
    const nextEnd = truncateScrollText(
      normalizeTextScrollEmojiPresentation(raw.slice(0, selectionEnd)),
    ).length;
    el.value = clean;
    if (typeof el.setSelectionRange === "function") {
      el.setSelectionRange(Math.min(nextStart, clean.length), Math.min(nextEnd, clean.length));
    }
    if (Array.from(normalized).filter((ch) => !isEmojiFormatControl(codePointOfChar(ch))).length > MAX_SCROLL_TEXT_CHARS) {
      log(`滚动文字超过 ${MAX_SCROLL_TEXT_CHARS} 字，已自动截断。`);
    }
  }
  return clean;
}

let scrollTextInputResizeQueued = false;
function autoResizeScrollTextInput() {
  if (scrollTextInputResizeQueued) return;
  scrollTextInputResizeQueued = true;
  requestAnimationFrame(() => {
    scrollTextInputResizeQueued = false;
    const el = $("scroll-text");
    if (!el) return;
    el.style.height = "auto";
    const minHeight =
      parseFloat(getComputedStyle(el).getPropertyValue("--scroll-text-min-height")) || 42;
    el.style.height = Math.max(minHeight, el.scrollHeight + 2) + "px";
  });
}

// Delayed fetching of larger Ark Pixel text scrolling resources only when text scrolling functionality is actually used
// (~830KB single merged woff2 (including emoji and fallback glyphs) + ~2.5MB bitmap glyph table),
// Keep ~2.4MB of resources out of the boot/post-launch waterfall. Both underlying loaders will cache
// Respective promise objects, so repeated calls (e.g. every time you enter a scrolling page) are cheap.
function ensureScrollFontsLoaded() {
  // P0-3: Page entry / refresh only warms the lightweight textarea (browser) font.
  // The ~2.5MB Ark bitmap table (ensureArkPixelFontReady) is intentionally NOT loaded
  // here -- it is loaded lazily by the paths that actually rasterize frames (Send via
  // prepareTextScrollTimelineAsync, Restore via prepareTextScrollTimelineForRestoreAsync,
  // and Step), each of which awaits ensureArkPixelFontReady() itself. This keeps merely
  // opening or refreshing into 6.4 from triggering a 2.5MB LittleFS transfer that froze
  // the WebUI ("preparing scroll font" hang / disconnect).
  ensureTextScrollBrowserFontReady().then((loaded) => {
    if (loaded) autoResizeScrollTextInput();
  });
}

function initScroll() {
  applyTextScrollInputFont();
  autoResizeScrollTextInput();
  // The larger Ark Pixel assets are not available on launch here. they will be in
  // Lazy loading when entering the text scrolling page for the first time (see switchPage -> ensureScrollFontsLoaded),
  // The scroll launch path will also wait for ensureArkPixelFontReady(), so it is safe even if the user plays directly.
  $("scroll-play").onclick = startScroll;
  $("scroll-pause").onclick = togglePauseScroll;
  $("scroll-stop").onclick = stopScroll;

  // IMPORTANT: these directions are VISUAL TEXT MOTION, not numeric frame-index motion.
  // Increasing scrollFrameIndex increases the source bitmap offset, so the text appears
  // to move LEFT. Decreasing scrollFrameIndex makes the whole text appear to move RIGHT.
  // Therefore:
  //   left arrow  ("prev", "<-") sends +1: text moves left by one visual frame.
  //   right arrow ("next", "->") sends -1: text moves right by one visual frame.
  // Do not "fix" this to match increasing/decreasing frame numbers; the user-facing
  // contract is visual movement direction.
  setScrollStepHandler("scroll-step-prev", 1);
  setScrollStepHandler("scroll-step-next", -1);
  const restoreBtn = $("scroll-restore-btn");
  if (restoreBtn) restoreBtn.hidden = true;
  setClickHandlers([
    [
      "scroll-speed-reset-default",
      () => setScrollFps(DEFAULT_SCROLL_FPS, "text_scroll_fps_reset_default"),
    ],
    ["scroll-speed-minus", () => setScrollFps(getScrollFps() - 5, "text_scroll_fps_minus")],
    ["scroll-speed-plus", () => setScrollFps(getScrollFps() + 5, "text_scroll_fps_plus")],
  ]);
  const fpsRangeEl = $("scroll-speed-range");
  if (fpsRangeEl) {
    fpsRangeEl.min = String(SCROLL_FPS_MIN);
    fpsRangeEl.max = String(SCROLL_FPS_MAX);
    fpsRangeEl.step = "1";
    fpsRangeEl.addEventListener("input", (ev) =>
      setScrollFps(ev.target.value, "text_scroll_fps_slider"),
    );
  }
  renderPresetButtons(
    "scroll-speed-presets",
    SCROLL_FPS_PRESETS,
    (value) => `${value}`,
    (value) => setScrollFps(value, "text_scroll_fps_preset"),
  );
  const textEl = $("scroll-text");
  if (textEl) {
    // Log factory default text: The recovery path treats this as overwriteable non-user content.
    scrollDefaultText = String(textEl.value ?? "");
    textEl.maxLength = MAX_SCROLL_TEXT_CHARS;
    textEl.addEventListener("input", () => {
      sanitizeScrollTextInput(true);
      applyTextScrollInputFont();
      autoResizeScrollTextInput();
      markScrollTextDirty();
    });
    textEl.addEventListener("change", () => {
      sanitizeScrollTextInput(true);
      autoResizeScrollTextInput();
      markScrollTextDirty();
    });
    textEl.addEventListener("paste", () =>
      requestAnimationFrame(() => {
        sanitizeScrollTextInput(true);
        autoResizeScrollTextInput();
        markScrollTextDirty();
      }),
    );
  }
  const fpsEl = $("scroll-speed");
  if (fpsEl) {
    fpsEl.addEventListener("keydown", (ev) => {
      if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
      const allowed = [
        "Backspace",
        "Delete",
        "ArrowLeft",
        "ArrowRight",
        "ArrowUp",
        "ArrowDown",
        "Home",
        "End",
        "Tab",
        "Enter",
      ];
      if (allowed.includes(ev.key)) return;
      if (!/^\d$/.test(ev.key)) ev.preventDefault();
    });
    fpsEl.addEventListener("beforeinput", (ev) => {
      if (ev.data && /\D/.test(ev.data)) ev.preventDefault();
    });
    fpsEl.addEventListener("input", () => {
      const fps = sanitizeScrollFpsInput(false);
      if (fpsEl.value !== "") setScrollFps(fps, "text_scroll_fps_input");
      else updateScrollUi();
    });
    fpsEl.addEventListener("paste", () =>
      requestAnimationFrame(() => {
        const fps = sanitizeScrollFpsInput(false);
        if (fpsEl.value !== "") setScrollFps(fps, "text_scroll_fps_paste");
        else updateScrollUi();
      }),
    );
    fpsEl.addEventListener("change", () =>
      setScrollFps(sanitizeScrollFpsInput(true), "text_scroll_fps_change"),
    );
    fpsEl.addEventListener("blur", () =>
      setScrollFps(sanitizeScrollFpsInput(true), "text_scroll_fps_blur"),
    );
  }
  window.addEventListener("resize", () => requestAnimationFrame(autoResizeScrollTextInput));
  if (document.fonts && document.fonts.ready)
    document.fonts.ready.then(autoResizeScrollTextInput).catch(() => {});
}

function parseScrollFpsValue(raw, fallback = DEFAULT_SCROLL_FPS) {
  const digits = String(raw ?? "").replace(/\D/g, "");
  if (!digits) return clamp(fallback, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  return clamp(parseInt(digits, 10), SCROLL_FPS_MIN, SCROLL_FPS_MAX);
}

function sanitizeScrollFpsInput(commit = false) {
  const el = $("scroll-speed");
  if (!el) return clamp(DEFAULT_SCROLL_FPS, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  const raw = String(el.value ?? "");
  const digits = raw.replace(/\D/g, "");
  if (!digits) {
    const fallback = clamp(DEFAULT_SCROLL_FPS, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
    if (commit) el.value = String(fallback);
    return fallback;
  }
  const clean = clamp(parseInt(digits, 10), SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  const next = String(clean);
  if (raw !== next) el.value = next;
  return clean;
}

function getScrollFps() {
  return parseScrollFpsValue($("scroll-speed")?.value, DEFAULT_SCROLL_FPS);
}

function getScrollFrameIntervalMs() {
  return Math.max(1, Math.round(1000 / getScrollFps()));
}

function syncScrollFpsUi(fps) {
  const clean = clamp(fps, SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  if ($("scroll-speed")) $("scroll-speed").value = clean;
  if ($("scroll-speed-range")) $("scroll-speed-range").value = clean;
  return clean;
}

function firmwareScrollFpsFromPayload(payload = {}) {
  const rawFps = Number(payload.uiFps ?? payload.scrollFps ?? payload.fps);
  if (Number.isFinite(rawFps) && rawFps > 0) {
    return clamp(Math.round(rawFps), SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  }
  const intervalMs = Number(payload.scrollIntervalMs ?? payload.intervalMs);
  if (Number.isFinite(intervalMs) && intervalMs > 0) {
    return clamp(Math.round(1000 / intervalMs), SCROLL_FPS_MIN, SCROLL_FPS_MAX);
  }
  return null;
}

function applyFirmwareScrollFps(payload = {}, source = "firmware_scroll_fps") {
  if (scroll.fpsBusy || scroll.startBusy || scroll.uploading) return false;
  const fps = firmwareScrollFpsFromPayload(payload);
  if (!Number.isFinite(fps)) return false;
  const before = getScrollFps();
  syncScrollFpsUi(fps);
  state.refreshPolicy = `firmware_scroll_${fps}fps_interval_${Math.max(1, Math.round(1000 / fps))}ms`;
  if (before !== fps) {
    logScrollRestoreDebug("fps synced", { source, fps });
    updateScrollUi();
  }
  return true;
}

// --- Firmware scroll-rate sync --------------------------------------------------------------
// The firmware reports its current scroll frame index on each status poll (FW_SYNC). By
// sampling (time, index) over a few seconds and least-squares fitting the cumulative advance,
// we estimate the device's ACTUAL frames-per-second and retune ONLY the preview timer to match
// it. No full frames are synced and the fps slider/buttons stay authoritative/untouched.
function resetFirmwareScrollRate() {
  scroll.hwSamples = [];
  scroll.hwLastIndex = null;
  scroll.hwLastT = 0;
  scroll.hwCum = 0;
  scroll.hwMeasuredFps = 0;
  scroll.previewIntervalMs = 0;
  scroll.phaseError = 0;
  scroll.phaseAccum = 0;
}

// Preview timer interval: measured device interval while firmware owns the session and an
// estimate exists; otherwise the user-selected fps (slider/buttons remain authoritative).
function effectivePreviewIntervalMs() {
  if (scroll.firmwareBacked && scroll.previewIntervalMs > 0) return scroll.previewIntervalMs;
  return getScrollFrameIntervalMs();
}

function retunePreviewTimer() {
  // No-op: the self-scheduling preview loop reads the effective interval and the phase speed
  // factor fresh on every tick, so a measured-rate change is picked up automatically.
}

// Hard frame-index sync (used on pause/resume): align the WebUI preview to the firmware's
// actual frame index — the LED's real displayed frame is ground truth — then clear the gradual
// phase aligner so it re-references from this synced point. Never touches the fps slider/buttons.
function snapPreviewToFirmwareFrame(fwIndex, reason = "text_scroll_index_sync") {
  if (!scroll.frames.length || !Number.isFinite(fwIndex)) return;
  const idx = clamp(Math.round(fwIndex), 0, scroll.frames.length - 1);
  scroll.frameIndex = idx;
  scroll.offset = idx;
  scroll.displayIndex = idx;
  scroll.phaseError = 0;
  scroll.phaseAccum = 0;
  scrollFrame = cloneFrame(scroll.frames[idx]);
  setScrollPreviewFrame(scrollFrame, reason, null);
}

// Record one firmware frame-index sample and, once enough have accumulated, derive the device
// fps and (only) retune the preview timer. `live` must be true only while the panel is actively
// scrolling (not paused); otherwise the estimator resets.
function recordFirmwareScrollSample(frameIndex, frameCount, live) {
  const loop = frameCount > 0 ? frameCount : scroll.frames.length;
  if (!live || loop <= 0 || !Number.isFinite(frameIndex)) { resetFirmwareScrollRate(); return; }
  // Phase reference (firmware index is ground truth): signed shortest offset by which the device
  // index leads the WebUI display. Only when the local timeline matches the device frame count.
  if (frameCount > 0 && frameCount === scroll.frames.length) {
    const dispBase = Number.isFinite(scroll.displayIndex) ? scroll.displayIndex : scroll.frameIndex;
    let perr = (((frameIndex - dispBase) % loop) + loop) % loop;
    if (perr > loop / 2) perr -= loop;
    scroll.phaseError = perr;
  }
  const now = performance.now();
  if (scroll.hwLastIndex === null) {
    scroll.hwLastIndex = frameIndex;
    scroll.hwLastT = now;
    scroll.hwCum = 0;
    scroll.hwSamples = [{ t: now, cum: 0 }];
    return;
  }
  const dtMs = now - scroll.hwLastT;
  if (dtMs < 1) return;
  // Resolve forward advance across possibly multiple wraps using the user's nominal fps as a prior.
  let delta = (((frameIndex - scroll.hwLastIndex) % loop) + loop) % loop; // [0, loop)
  const expected = (getScrollFps() * dtMs) / 1000;
  const loops = Math.max(0, Math.round((expected - delta) / loop));
  delta += loops * loop;
  scroll.hwCum += delta;
  scroll.hwLastIndex = frameIndex;
  scroll.hwLastT = now;
  scroll.hwSamples.push({ t: now, cum: scroll.hwCum });
  const cutoff = now - HW_RATE_WINDOW_MS;
  while (scroll.hwSamples.length > 2 && scroll.hwSamples[0].t < cutoff) scroll.hwSamples.shift();
  const s = scroll.hwSamples;
  const spanMs = s[s.length - 1].t - s[0].t;
  const spanFrames = s[s.length - 1].cum - s[0].cum;
  if (s.length < HW_RATE_MIN_SAMPLES || spanMs < HW_RATE_MIN_SPAN_MS || spanFrames < HW_RATE_MIN_FRAMES) return;
  // Least-squares slope of cumulative frames vs time (frames per ms).
  const t0 = s[0].t;
  let n = s.length, sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (const pt of s) { const x = pt.t - t0; sx += x; sy += pt.cum; sxx += x * x; sxy += x * pt.cum; }
  const denom = n * sxx - sx * sx;
  if (denom <= 0) return;
  const fps = ((n * sxy - sx * sy) / denom) * 1000;
  if (!Number.isFinite(fps) || fps < HW_RATE_FPS_MIN || fps > HW_RATE_FPS_MAX) return;
  scroll.hwMeasuredFps = scroll.hwMeasuredFps > 0
    ? scroll.hwMeasuredFps * (1 - HW_RATE_EMA_ALPHA) + fps * HW_RATE_EMA_ALPHA
    : fps;
  state.firmwareScrollFps = scroll.hwMeasuredFps;
  const newInterval = Math.max(1, Math.round(1000 / scroll.hwMeasuredFps));
  const prev = scroll.previewIntervalMs;
  if (prev === 0 || Math.abs(newInterval - prev) / prev > HW_RATE_RETUNE_RATIO) {
    scroll.previewIntervalMs = newInterval;
    retunePreviewTimer();
    log(`预览滚动速度按固件实测校准：${scroll.hwMeasuredFps.toFixed(2)} fps（用户设定 ${getScrollFps()} fps 不变）`, "debug");
  }
}

// Phase alignment by speed modulation: each preview tick advances exactly one frame, but the
// delay until the next tick is shortened (run faster) when the display is behind the firmware
// and lengthened (run slower) when ahead, so the phase converges smoothly over a few seconds
// without ever skipping, holding, or jumping a frame. The fps slider/buttons are never touched.
function nextPreviewDelayMs() {
  const base = effectivePreviewIntervalMs();
  let factor = 1;
  if (scroll.phaseError) {
    factor = 1 + clamp(scroll.phaseError * HW_PHASE_GAIN, -HW_PHASE_MAX_ADJ, HW_PHASE_MAX_ADJ);
    // Drain the error estimate by the frames we expect to gain on the device this tick;
    // the next firmware sample re-anchors phaseError to the true offset (ground truth).
    scroll.phaseError -= 1 - 1 / factor;
    if (Math.abs(scroll.phaseError) < 0.05) scroll.phaseError = 0;
  }
  return Math.max(1, Math.round(base / factor));
}

function previewTickLoop() {
  scroll.timer = setTimeout(() => {
    scroll.timer = null;
    if (!scroll.active || scroll.paused) return;
    advanceScroll(false);
    if (scroll.active && !scroll.paused) previewTickLoop();
  }, nextPreviewDelayMs());
}

function restartScrollPreviewTimer() {
  if (scroll.timer) { clearTimeout(scroll.timer); clearInterval(scroll.timer); }
  scroll.timer = null;
  if (scroll.active && !scroll.paused) previewTickLoop();
}

function setScrollFps(fps, source = "text_scroll_fps_change") {
  if (scroll.commandBusy || scroll.fpsBusy) return;
  const clean = syncScrollFpsUi(fps);
  state.refreshPolicy = `text_scroll_${clean}fps_interval_${getScrollFrameIntervalMs()}ms`;
  resetFirmwareScrollRate();
  restartScrollPreviewTimer();
  if (!scroll.textEdited && (scroll.active || scroll.firmwareBacked || scroll.paused)) {
    scroll.fpsBusy = true;
    scroll.commandBusy = true;
    updateScrollUi();
    sendAuxCommand(
      "set_scroll_interval",
      {
        fps: clean,
        intervalMs: getScrollFrameIntervalMs(),
      },
      source,
    ).promise.finally(() => {
      scroll.fpsBusy = false;
      scroll.commandBusy = false;
      updateScrollUi();
    });
  } else {
    updateScrollUi();
    renderState();
  }
}

function markScrollTextDirty() {
  scroll.dirty = true;
  scroll.signature = "";
  scrollMachine.dispatch("TEXT_EDITED");
  scroll.framesTimelineId = ""; // C2: Local frames no longer represent any uploaded timeline
  scroll.restoredTextTruncated = false; // E4
  scroll.textEdited = true;
  pendingScrollMeta = null;
  scroll.restoredSourceText = "";
  scroll.restoredFromFirmwareMeta = false;
  scroll.restoreWarning = "";
  if (
    (scroll.active || scroll.firmwareBacked || state.textScrollActive) &&
    !scroll.dirtyNoticeLogged
  ) {
    scroll.dirtyNoticeLogged = true;
    log("文字已修改；当前滚动继续使用已上传缓存，下一次点击发送才重新生成并上传。");
  }
  updateScrollUi();
}

function setScrollUploadProgress(progress, label) {
  if (clamp(progress, 0, 1) < 1) scroll.uploadProgressToken++;
  scroll.uploadProgress = clamp(progress, 0, 1);
  scroll.uploadLabel = label || "";
  updateScrollUi();
}

function completeScrollUploadProgress(label = "发送完成，滚动帧仅在固件 RAM 中运行") {
  const token = ++scroll.uploadProgressToken;
  scroll.uploading = true;
  scroll.uploadProgress = 1;
  scroll.uploadLabel = label;
  updateScrollUi();
  setTimeout(() => {
    if (token === scroll.uploadProgressToken && scroll.uploadProgress >= 1) {
      scroll.uploading = false;
      scroll.uploadProgress = 0;
      scroll.uploadLabel = "";
      updateScrollUi();
    }
  }, 1400);
}

function resetScrollUploadProgress() {
  scroll.uploadProgressToken++;
  scroll.uploading = false;
  scroll.uploadProgress = 0;
  scroll.uploadLabel = "";
  updateScrollUi();
}

function hasScrollInputContent() {
  return !!String($("scroll-text")?.value ?? "").trim();
}

function hasScrollFrameCache() {
  return scroll.frames.length > 0 || lastFwScrollFrameCount > 0;
}

function hasRestorableFirmwareScrollSource() {
  return !!(lastFwScrollDisplaying && lastFwScrollTimelineId && lastFwScrollHasSourceText);
}

function hasUsableOrRestorableScrollFrames() {
  return scroll.frames.length > 0 || hasRestorableFirmwareScrollSource();
}

function isScrollCommandBusy() {
  return !!(scroll.commandBusy || scroll.restoring || scroll.stepBusy);
}

function isUserControllablePaused() {
  const effectivePaused = scroll.paused || state.playback === "scroll_paused";
  const systemOnlyPause = scroll.systemPaused && !scroll.userPaused;
  return effectivePaused && !systemOnlyPause;
}

function isScrollProgressVisible() {
  return (
    !!scroll.uploading ||
    (scroll.uploadProgress > 0 && scroll.uploadProgress < 1.001) ||
    !!scroll.uploadLabel
  );
}

function nextUiFrame() {
  return new Promise((resolve) => requestAnimationFrame(resolve));
}

function sleepMs(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function resetScrollPreviewToFirstFrame(
  reason = "text_scroll_start_reset_preview",
  playback = "scroll",
) {
  scroll.frameIndex = 0;
  scroll.offset = 0;
  scroll.displayIndex = 0; // keep the display-only tween anchored at start (fix #1)
  scrollFrame = cloneFrame(scroll.frames[0] || blankFrame());
  setScrollPreviewFrame(scrollFrame, reason, playback);
  updateScrollUi();
}

function resetScrollControlsAfterButton(reason = "gpio_button", options = {}) {
  const preserveCurrentFrame = !!options.preserveCurrentFrame;
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.active = false;
  scroll.paused = false;
  scroll.userPaused = false;
  scroll.systemPaused = false;
  scroll.firmwareBacked = false;
  scroll.uploading = false;
  scroll.commandBusy = false;
  scroll.restoring = false;
  scroll.stepBusy = false;
  scroll.offset = 0;
  scroll.frameIndex = 0;
  state.textScrollActive = false;
  if (isScrollPlaybackValue(state.playback)) state.playback = "idle";
  state.lastRefreshReason = `${reason}_reset_scroll_ui`;
  // Exiting text-scroll through GPIO/WebUI button is equivalent to Stop/Clear:
  // local preview frames and firmware recovery identity are terminally cleared so
  // a later refresh cannot pull the old uploaded source string back into WebUI.
  scroll.frames = [];
  scroll.signature = "";
  scroll.timelineId = "";
  scroll.framesTimelineId = "";
  scroll.dirty = true;
  clearRecoveredScrollCache(reason);
  resetScrollUploadProgress();
  if (preserveCurrentFrame) {
    scrollFrame = cloneFrame(currentFrame);
  } else {
    scrollFrame = blankFrame();
  }
  renderMatrices();
  updateScrollUi();
  renderState();
}
async function buildFirmwareScrollFrames(onProgress = () => {}) {
  const source = scroll.frames;
  if (!source.length) return [];
  if (source.length > firmwareScrollMaxFrames) {
    throw new Error(
      `文字滚动帧数 ${source.length} 超过固件缓存上限 ${firmwareScrollMaxFrames}；请缩短文本或提高固件上限。`,
    );
  }
  // Emit each frame as a packed 47-byte Uint8Array; the upload concatenates them into a
  // single binary body (N * 47 bytes) for /api/scroll.
  const frames = [];
  for (let i = 0; i < source.length; i++) {
    frames.push(frameToUint8Array(source[i]));
    if (i === 0 || i === source.length - 1 || i % 32 === 0) {
      onProgress((i + 1) / source.length);
      await nextUiFrame();
    }
  }
  return frames;
}
// Always append rather than overwrite; updateScrollUi renders multiple lines.
function setScrollRestoreWarning(message) {
  if (!message) return;
  if (scroll.restoreWarning && scroll.restoreWarning.split("\n").includes(message)) return;
  scroll.restoreWarning = scroll.restoreWarning
    ? `${scroll.restoreWarning}\n${message}`
    : message;
}

function makeScrollTimelineId() {
  const rand = Math.random().toString(36).slice(2, 6);
  return `scroll-${Date.now().toString(36)}-${rand}`;
}

// Binary upload sizing: the HTTP body is exactly frameCount * 47 bytes (all metadata,
// including sourceText, now travels in the query string rather than the body). Fit as many
// frames as the first-chunk body budget allows, capped by the normal per-chunk frame count.
function chooseFirstChunkFrames() {
  const count = Math.floor(SCROLL_FIRST_CHUNK_BODY_LIMIT_BYTES / PACKED_FRAME_BYTES);
  return clamp(count, 1, SCROLL_UPLOAD_CHUNK_FRAMES);
}

// generatorVersion + fps, each chunk has timelineId and chunkIndex.
// SF1: The number of frames in the first block is variable, and the blocks are sliced according to the running offset (fixed step cycles cannot be reused);
// The chunkIndex is still +1 for each block, and the firmware checks the sequence according to chunkIndex and the total amount according to the number of frames.
async function uploadScrollTimelineAttempt(frames, timelineId) {
  const uploadToken = scrollMachine.token("upload");
  scrollMachine.dispatch("UPLOAD_BEGIN", {}, uploadToken);

  scroll.timelineId = timelineId;
  scroll.framesTimelineId = timelineId; // The local frame is the timeline of this transmission
  const sourceText = sanitizeScrollTextInput(true);
  const fps = getScrollFps();
  const intervalMs = Math.max(1, Math.round(1000 / fps));
  const buildFirstChunkPayload = (count) => ({
    frames: frames.slice(0, count),
    stepLedPerFrame: 1,
    start: false,
    append: false,
    chunkIndex: 0,
    chunkFrames: count,
    totalFrames: frames.length,
    timelineId,
    sourceText,
    fontId: TEXT_SCROLL_FONT_MODEL,
    generatorVersion: SCROLL_GENERATOR_VERSION,
    fps,
    intervalMs,
    source: "webui_text_scroll_frames_with_source_text",
    storage: "ram",
    persist: false,
    saveToFlash: false,
  });
  const firstChunkFrames = chooseFirstChunkFrames();
  const totalChunks =
    1 + Math.max(0, Math.ceil((frames.length - firstChunkFrames) / SCROLL_UPLOAD_CHUNK_FRAMES));
  let data = null;
  let offset = 0;
  let chunkIndex = 0;
  setScrollUploadProgress(0.36, `分批上传到固件 RAM 0/${totalChunks}`);
  while (offset < frames.length) {
    if (!scrollMachine.isCurrent(uploadToken)) throw new Error("上传已被新的发送取代");
    const size = chunkIndex === 0 ? firstChunkFrames : SCROLL_UPLOAD_CHUNK_FRAMES;
    const chunk = frames.slice(offset, offset + size);
    const payload =
      chunkIndex === 0
        ? buildFirstChunkPayload(chunk.length)
        : {
            frames: chunk,
            stepLedPerFrame: 1,
            start: false,
            append: true,
            timelineId,
            chunkIndex,
            chunkFrames: chunk.length,
            totalFrames: frames.length,
            source: "webui_text_scroll_frames_with_source_text",
            storage: "ram",
            persist: false,
            saveToFlash: false,
          };
    const chunkNumber = chunkIndex;
    data = await apiPostWithUploadProgress(API_ENDPOINTS.scroll, payload, (progress) => {
      if (!scrollMachine.isCurrent(uploadToken)) return;
      const chunkProgress = (chunkNumber + progress) / totalChunks;
      setScrollUploadProgress(
        0.36 + chunkProgress * 0.5,
        `分批上传到固件 RAM ${chunkNumber + 1}/${totalChunks}`,
      );
    });
    offset += chunk.length;
    chunkIndex++;
    await sleepMs(20);
  }

  if (!scrollMachine.isCurrent(uploadToken)) throw new Error("上传已被新的发送取代");
  setScrollUploadProgress(0.9, `帧数据已完成，设置 ${fps} fps`);
  scrollMachine.dispatch("UPLOAD_COMMIT_DONE", {}, uploadToken);

  if (data && data.started) {
    log("固件已在上传结束时自动启动滚动播放，无需重复发送 start_scroll 命令。");
  } else {
    try {
      data = await apiPost(API_ENDPOINTS.command, {
        cmd: "start_scroll",
        payload: {
          timelineId,
          fps,
          intervalMs,
          sourceText, // raw UTF-8 in the POST body (kept out of the URL); firmware stores it in scroll meta
          source: "webui_text_scroll_after_frames",
        },
      });
    } catch (err) {
      scrollMachine.dispatch("START_FAIL", {}, uploadToken);
      throw err;
    }
  }

  if (!scrollMachine.isCurrent(uploadToken)) {
    scrollMachine.dispatch("START_FAIL", {}, uploadToken);
    throw new Error("启动已被新的操作取消");
  }

  scrollMachine.dispatch("START_CONFIRMED", {}, uploadToken);
  applyFirmwareRuntimeState(data, "text_scroll_upload_start_after_frames");
  setScrollUploadProgress(0.98, "启动滚动播放");
  return Object.assign(
    {
      frames: frames.length,
      fps,
      scrollIntervalMs: intervalMs,
    },
    data || {},
  );
}

// On any chunking or when start_scroll returns 409, retry completely from chunk 0 with a new timelineId (C10).
async function uploadFirmwareScrollTimeline() {
  setScrollUploadProgress(0.04, "准备滚动帧");
  const frames = await buildFirmwareScrollFrames((progress) => {
    setScrollUploadProgress(0.04 + progress * 0.3, `编码 ${Math.round(progress * 100)}%`);
  });
  if (!frames.length) throw new Error("no scroll frames");
  try {
    return await uploadScrollTimelineAttempt(frames, makeScrollTimelineId());
  } catch (err) {
    if (!/^409\b/.test(String(err?.message || ""))) throw err;
    log("固件返回 409（缓存/分块冲突），使用全新 timelineId 完整重试一次。");
    return await uploadScrollTimelineAttempt(frames, makeScrollTimelineId());
  }
}
// P1-5: reject source text whose UTF-8 byte length exceeds the firmware limit BEFORE
// generating frames / uploading, so the user gets a clear message instead of a 413
// (or a partial upload) mid-transfer. Returns true if the text is too large.
// P1-6: turn raw HTTP error strings (which begin with the status code) into actionable
// guidance for the common scroll-upload failure modes.
function describeScrollUploadError(err) {
  const msg = String(err?.message || err || "");
  const code = (msg.match(/^(\d{3})\b/) || [])[1];
  switch (code) {
    case "413":
      return `文字或单次帧数据过大，超过固件上限，请缩短文本。(${msg})`;
    case "507":
      return `固件内存/PSRAM 不足，无法缓存滚动帧；请稍后重试或缩短文本。(${msg})`;
    case "503":
      return `固件正忙或可用内存偏低，暂时拒绝了上传；请稍后重试。(${msg})`;
    case "409":
      return `固件缓存/分块冲突，自动重试后仍失败；请重新发送。(${msg})`;
    default:
      return msg;
  }
}

function scrollTextExceedsByteLimit(text) {
  const bytes = new TextEncoder().encode(text).length;
  if (bytes > firmwareScrollMaxTextBytes) {
    alert(
      `文字 UTF-8 长度 ${bytes} 字节，超过固件上限 ${firmwareScrollMaxTextBytes} 字节，请缩短文本。`,
    );
    return true;
  }
  return false;
}

async function startScroll() {
  if (scroll.commandBusy || scroll.startBusy) return;
  const text = sanitizeScrollTextInput(true);
  if (!text.trim()) {
    alert("空文本不进入文字滚动播放");
    return;
  }
  if (scrollTextExceedsByteLimit(text)) return;
  resetScrollUploadProgress();
  scrollMachine.dispatch("GENERATE");
  scroll.commandBusy = true;
  scroll.startBusy = true;
  scroll.uploading = true;
  setScrollUploadProgress(0.02, "准备发送");
  scroll.returnMode = isAutoModeValue(state.mode) ? "auto" : "manual";
  await prepareForTextScrollUpload();
  // D7: The new sending clears all recovery status first to avoid interference from the old pendingScrollMeta.
  pendingScrollMeta = null;
  scroll.restoredSourceText = "";
  scroll.restoredFromFirmwareMeta = false;
  scroll.restoreWarning = "";
  scroll.restoredTextTruncated = false;
  try {
    await prepareTextScrollTimelineAsync(false);
  } catch (err) {
    scrollMachine.dispatch("START_FAIL");
    scrollMachine.dispatch("UPLOAD_FAIL");
    scroll.commandBusy = false;
    scroll.startBusy = false;
    resetScrollUploadProgress();
    return;
  }
  if (!scroll.frames.length) {
    scrollMachine.dispatch("UPLOAD_FAIL");
    scroll.commandBusy = false;
    scroll.startBusy = false;
    resetScrollUploadProgress();
    alert("没有可播放的文字帧");
    return;
  }
  // The input is about to be sent, so it is no longer an unsent local edit.
  scroll.textEdited = false;
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.active = false;
  scroll.paused = false;
  scroll.userPaused = false;
  scroll.systemPaused = false;
  scroll.firmwareBacked = false;
  scroll.dirtyNoticeLogged = false;
  state.textScrollActive = false;
  state.refreshPolicy = `text_scroll_${getScrollFps()}fps_interval_${getScrollFrameIntervalMs()}ms`;
  scroll.fpsStarted = performance.now();
  scroll.frameCounter = 0;
  resetFirmwareScrollRate();
  try {
    const data = await uploadFirmwareScrollTimeline();
    resetScrollPreviewToFirstFrame("text_scroll_start_reset_preview", "scroll");
    applyFirmwareRuntimeState(data, "text_scroll_upload_complete");
    scroll.firmwareBacked = true;
    scroll.commandBusy = false;
    scroll.startBusy = false;
    completeScrollUploadProgress("发送完成，滚动帧仅在固件 RAM 中运行");
    log(
      `文字滚动已上传到固件 RAM 并独立运行：${data?.frames || scroll.frames.length} 帧，${getScrollFps()} fps，每帧推进 1 LED；不会写入 saved_faces.json 或闪存。`,
    );
  } catch (err) {
    scrollMachine.dispatch("UPLOAD_FAIL");
    scroll.commandBusy = false;
    scroll.startBusy = false;
    scroll.firmwareBacked = false;
    scroll.uploading = false;
    scroll.active = false;
    state.textScrollActive = false;
    state.playback = "idle";
    resetScrollUploadProgress();
    log(`文字滚动固件上传失败；已停止，未启用 WebUI 逐帧发送：${describeScrollUploadError(err)}`);
    alert(`文字滚动上传失败：${describeScrollUploadError(err)}`);
    updateScrollUi();
    renderState();
    return;
  }
  restartScrollPreviewTimer();
  log(
    `文字滚动开始：${getScrollFps()} fps / ${getScrollFrameIntervalMs()} ms，预生成 ${scroll.frames.length} 帧，逐帧 1 LED`,
  );
  updateScrollUi();
  renderState();
}

async function togglePauseScroll() {
  if (scroll.commandBusy || scroll.pauseBusy) return;
  if (scroll.pauseToggleLocked) return;
  if (scroll.systemPaused && !scroll.userPaused) {
    updateScrollUi();
    renderState();
    return;
  }
  scroll.pauseToggleLocked = true;
  setTimeout(() => {
    scroll.pauseToggleLocked = false;
  }, 250);
  if (isUserControllablePaused()) await resumeScroll();
  else await pauseScroll();
}

async function pauseScroll() {
  if (!scroll.active && !state.textScrollActive && !scroll.firmwareBacked) {
    log("文字滚动未播放，无需暂停");
    updateScrollUi();
    renderState();
    return;
  }
  if (scroll.commandBusy || scroll.pauseBusy) return;
  scroll.commandBusy = true;
  scroll.pauseBusy = true;
  updateScrollUi();
  try {
    const packet = sendAuxCommand("pause_scroll", {}, "text_scroll_paused");
    const data = await packet.promise;
    if (data) {
      scrollMachine.dispatch("PAUSE_USER");
      if (scroll.timer) clearInterval(scroll.timer);
      scroll.timer = null;
      applyFirmwareRuntimeState(data, "text_scroll_paused_result");
      snapPreviewToFirmwareFrame(Number(data.scrollFrameIndex), "text_scroll_pause_sync");
      log("文字滚动已暂停，已按固件(LED)实际帧编号对齐预览");
    } else {
      log("暂停命令未确认，保持现有滚动状态并等待下一次固件同步");
    }
  } finally {
    scroll.pauseBusy = false;
    scroll.commandBusy = false;
    updateScrollUi();
    renderState();
  }
}

async function resumeScroll() {
  if (!scroll.frames.length) {
    const restored = await ensureLocalScrollFramesRestored("resume_scroll_restore");
    if (!restored) {
      log("没有可恢复的文字滚动帧，不能继续；请重新发送。");
      updateScrollUi();
      renderState();
      return;
    }
  }
  if (scroll.commandBusy || scroll.pauseBusy) return;
  scroll.commandBusy = true;
  scroll.pauseBusy = true;
  updateScrollUi();
  try {
    const packet = sendAuxCommand("resume_scroll", {}, "text_scroll_resumed");
    const data = await packet.promise;
    if (data) {
      scrollMachine.dispatch("RESUME_USER");
      applyFirmwareRuntimeState(data, "text_scroll_resumed_result");
      snapPreviewToFirmwareFrame(Number(data.scrollFrameIndex), "text_scroll_resume_sync");
      scroll.fpsStarted = performance.now();
      scroll.frameCounter = 0;
      if (scroll.systemPaused) {
        if (scroll.timer) clearInterval(scroll.timer);
        scroll.timer = null;
      } else {
        restartScrollPreviewTimer();
      }
      log("文字滚动继续播放，固件从当前缓存继续运行");
    } else {
      log("继续命令未确认，保持现有滚动状态并等待下一次固件同步");
    }
  } finally {
    scroll.pauseBusy = false;
    scroll.commandBusy = false;
    updateScrollUi();
    renderState();
  }
}

async function stopScroll() {
  if (scroll.commandBusy || scroll.stopBusy || !hasScrollFrameCache()) return;
  const restoreAuto = scroll.returnMode === "auto" || state.restoreAutoAfterScroll;
  const restartPreviewOnFailure = scroll.active && !scroll.paused;
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.commandBusy = true;
  scroll.stopBusy = true;
  scrollMachine.dispatch("STOP");
  updateScrollUi();
  try {
    const packet = sendAuxCommand(
      "stop_scroll",
      {
        clear: true,
        restoreAuto,
      },
      "text_scroll_stopped_clear",
    );
    const data = await packet.promise;
    if (!data) {
      if (restartPreviewOnFailure) restartScrollPreviewTimer();
      log("停止/清屏命令未确认，保留本地滚动缓存并等待下一次固件同步");
      return;
    }
    scrollMachine.dispatch("STOP_DONE");
    applyFirmwareRuntimeState(data, "text_scroll_stopped_clear_result");
    scroll.active = false;
    scroll.paused = false;
    scroll.userPaused = false;
    scroll.systemPaused = false;
    scroll.firmwareBacked = false;
    scroll.uploading = false;
    scroll.dirtyNoticeLogged = false;
    scroll.offset = 0;
    scroll.frameIndex = 0;
    resetScrollUploadProgress();
    scroll.frames = [];
    scroll.signature = "";
    scroll.timelineId = "";
    scroll.framesTimelineId = "";
    scroll.dirty = true;
    // Local stop: completely clear recovery identity so refresh cannot resurrect the old source text.
    clearRecoveredScrollCache("text_scroll_stopped_clear");
    state.textScrollActive = false;
    state.refreshPolicy = "dirty-frame / 按需刷新";
    scrollFrame = blankFrame();
    currentFrame = blankFrame();
    state.lastRefreshReason = "text_scroll_stopped_clear";
    state.playback = "idle";
    renderMatrices();
    updatePackedFrameViews();

    state.playback = restoreAuto ? "auto_saved_face" : "idle";
    state.mode = restoreAuto ? "auto" : "manual";
    state.restoreAutoAfterScroll = false;
    if (restoreAuto) {
      const delay = data.deferredFaceRestoreActive ? SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS : 20;
      scheduleFirmwareScrollStopFullSync("text_scroll_stop_restore_auto_status", delay);
    }
    renderSavedFaces();
    log(
      restoreAuto
        ? "文字滚动停止/清屏，已清空滚动缓存，并回到 A 自动保存表情切换模式"
        : "文字滚动停止/清屏，已清空滚动缓存，并保持 M 手动模式",
    );
  } catch (err) {
    if (restartPreviewOnFailure) restartScrollPreviewTimer();
    log("停止/清屏命令执行异常：" + err.message);
  } finally {
    scroll.stopBusy = false;
    scroll.commandBusy = false;
    updateScrollUi();
    renderState();
  }
}

// direction < 0 means the text moves one space to the right.
function setScrollStepHandler(buttonId, direction) {
  const button = $(buttonId);
  if (!button) return;
  button.onclick = async () => {
    if (scroll.commandBusy || scroll.stepBusy) return;
    if (!scroll.frames.length) {
      const restored = await ensureLocalScrollFramesRestored("manual_step_restore");
      if (!restored) return;
    }
    const stepToken = scrollMachine.token("step");
    scrollMachine.dispatch("STEP", {}, stepToken);
    scroll.stepBusy = true;
    scroll.commandBusy = true;
    updateScrollUi();
    try {
      guardBeforeOutput("text_scroll_manual_step", "scroll");
      const source = direction < 0 ? "text_scroll_manual_step_right" : "text_scroll_manual_step_left";
      const packet = sendAuxCommand(
        "scroll_step",
        {
          direction,
        },
        source,
      );
      const data = await packet.promise;
      if (!scrollMachine.isCurrent(stepToken)) return;
      if (data) {
        applyFirmwareScrollFrameIndex(data, "text_scroll_manual_step_preview");
        // The firmware latches an effective pause on every step (audit fix #2). Reflect
        // that in the machine and stop the local preview timer so the held frame is not
        // tweened past while playback is paused on the stepped frame.
        scrollMachine.dispatch("PAUSE_USER");
        if (scroll.timer) {
          clearInterval(scroll.timer);
          scroll.timer = null;
        }
      } else {
        log("逐格移动命令未确认，保持当前预览并等待下一次固件同步");
      }
    } finally {
      scrollMachine.dispatch("STEP_DONE", {}, stepToken);
      scroll.stepBusy = false;
      scroll.commandBusy = false;
      updateScrollUi();
      renderState();
    }
  };
}

function advanceScroll(manual = false, direction = 1) {
  prepareTextScrollTimeline(false);
  if (!scroll.frames.length) return;
  const delta = direction < 0 ? -1 : 1;
  const len = scroll.frames.length;

  // When firmware owns the scroll session, keep the page preview/display counter local.
  // FW_SYNC may still update scroll.frameIndex for device state, but it must not anchor
  // scroll.displayIndex or the "current frame" label.
  if (!manual && scrollMachine.snapshot().device.hasSession) {
    const base = Number.isFinite(scroll.displayIndex) ? scroll.displayIndex : scroll.frameIndex;
    // Always advance exactly one frame; phase alignment is done purely by modulating the preview
    // timer speed (see nextPreviewDelayMs) — never by skipping, holding, or jumping frames.
    scroll.displayIndex = (((base + delta) % len) + len) % len;
    scrollFrame = cloneFrame(scroll.frames[scroll.displayIndex]);
    setScrollPreviewFrame(scrollFrame, "text_scroll_fw_tween_display_only", "scroll");
  } else {
    scroll.frameIndex = (scroll.frameIndex + delta + len) % len;
    scroll.offset = scroll.frameIndex;
    scroll.displayIndex = scroll.frameIndex;
    scrollFrame = cloneFrame(scroll.frames[scroll.frameIndex]);
    setScrollPreviewFrame(
      scrollFrame,
      manual ? "text_scroll_manual_step_preview" : "text_scroll_firmware_preview",
      manual ? "scroll_step" : "scroll",
    );
  }
  scroll.frameCounter++;
  const now = performance.now();
  if (now - scroll.fpsStarted >= 1000) {
    scroll.measuredFps = (scroll.frameCounter * 1000) / (now - scroll.fpsStarted);
    state.actualFps = scroll.measuredFps;
    scroll.frameCounter = 0;
    scroll.fpsStarted = now;
  }
  updateScrollUi();
}

function scrollSignature() {
  return JSON.stringify({
    text: sanitizeScrollTextInput(true),
    model: TEXT_SCROLL_FONT_MODEL,
    source: arkPixelFont.source,
    verticalOffset: textScrollVerticalOffset(),
  });
}
async function prepareTextScrollTimelineAsync(force) {
  try {
    await ensureArkPixelFontReady();
    prepareTextScrollTimeline(force);
  } catch (err) {
    scroll.frames = [];
    scroll.frameIndex = 0;
    scroll.offset = 0;
    scroll.dirty = true;
    updateScrollUi();
    alert(`Ark Pixel Font 12px bitmap table 未加载，无法准备文字滚动帧序列：${err.message}`);
    throw err;
  }
}

async function prepareTextScrollTimelineForRestoreAsync(
  force,
  onProgress = () => {},
  shouldCancel = null,
) {
  const cancelled = () => typeof shouldCancel === "function" && shouldCancel();
  try {
    onProgress(0.04, "准备文字滚动字体");
    await ensureArkPixelFontReady();
    if (cancelled()) return false;
    const text = sanitizeScrollTextInput(true);
    if (!text.trim()) {
      scroll.frames = [];
      scroll.frameIndex = 0;
      scroll.offset = 0;
      scroll.dirty = false;
      updateScrollUi();
      onProgress(1, "没有可同步的滚动文字");
      return false;
    }
    const sig = scrollSignature();
    if (!force && !scroll.dirty && scroll.signature === sig && scroll.frames.length) {
      onProgress(1, `复用已生成预览：${scroll.frames.length} 帧`);
      return true;
    }

    onProgress(0.1, "构建文字位图");
    await nextUiFrame();
    const source = buildTextScrollBitmap(text);
    const maxOffset = Math.max(1, source.width - COLS);
    const total = maxOffset + 1;
    const frames = [];
    for (let offset = 0; offset <= maxOffset; offset++) {
      frames.push(extractFrameFromTextImage(source, offset));
      // P2-7: yield more often (every 6 frames vs 12) so long text keeps the WebUI
      // responsive, and bail out promptly if the restore was superseded/cancelled
      // (Stop / Back / page switch) instead of grinding through every frame.
      if (offset === 0 || offset === maxOffset || offset % 6 === 0) {
        const ratio = (offset + 1) / total;
        onProgress(0.12 + ratio * 0.76, `生成同步预览 ${offset + 1}/${total}`);
        await nextUiFrame();
        if (cancelled()) {
          scroll.frames = [];
          scroll.frameIndex = 0;
          scroll.offset = 0;
          scroll.dirty = true;
          return false;
        }
      }
    }

    scroll.frames = rotateScrollTimelineToFirstLitFrame(frames);
    scroll.signature = sig;
    scroll.dirty = false;
    scroll.frameIndex = Math.min(scroll.frameIndex, Math.max(0, scroll.frames.length - 1));
    scroll.offset = scroll.frameIndex;
    log(
      `文字滚动同步预览已生成：${frames.length} 帧，逐帧推进 1 LED，垂直居中偏移 ${textScrollVerticalOffset()} 行，约 ${((frames.length * 47) / 1024).toFixed(1)} KB packed`,
    );
    updateScrollUi();
    onProgress(0.9, "同步当前帧编号");
    return true;
  } catch (err) {
    scroll.frames = [];
    scroll.frameIndex = 0;
    scroll.offset = 0;
    scroll.dirty = true;
    updateScrollUi();
    alert(`Ark Pixel Font 12px bitmap table 未加载，无法准备文字滚动帧序列：${err.message}`);
    throw err;
  }
}

function prepareTextScrollTimeline(force) {
  const text = sanitizeScrollTextInput(true);
  if (!text.trim()) {
    scroll.frames = [];
    scroll.frameIndex = 0;
    scroll.offset = 0;
    scroll.dirty = false;
    updateScrollUi();
    return;
  }
  const sig = scrollSignature();
  if (!force && !scroll.dirty && scroll.signature === sig && scroll.frames.length) return;

  // M4: keep the main thread responsive on very long text. Abort generation as early as
  // possible when the projected frame count would exceed the firmware cache cap, so we
  // never materialize thousands of 370-cell frame arrays (plus a duplicate bitmap and the
  // later packed-frame copies) on low-end phones. The upload path enforces the same cap, so
  // this only surfaces the limit earlier and more cheaply.
  const abortScrollTooLong = (projectedFrames) => {
    scroll.frames = [];
    scroll.frameIndex = 0;
    scroll.offset = 0;
    scroll.dirty = false;
    scroll.signature = sig;
    setScrollRestoreWarning(
      `文字过长：约需 ${projectedFrames} 帧，超过固件缓存上限 ${firmwareScrollMaxFrames} 帧；请缩短文本。`,
    );
    log(
      `文字滚动未生成：预计 ${projectedFrames} 帧超过固件上限 ${firmwareScrollMaxFrames}，已提前中止以保持界面流畅。`,
    );
    updateScrollUi();
  };

  // Cheap pre-rasterization guard: even at an unrealistic 1px-per-glyph lower bound this
  // many code points cannot fit, so reject before building the bitmap at all.
  const codepointCount = Array.from(text).length;
  if (codepointCount - COLS + 1 > firmwareScrollMaxFrames) {
    abortScrollTooLong(codepointCount - COLS + 1);
    return;
  }

  const source = buildTextScrollBitmap(text);
  const maxOffset = Math.max(1, source.width - COLS);
  // Precise cap on the actual rasterized width, before the per-frame extraction loop.
  const projectedFrames = maxOffset + 1;
  if (projectedFrames > firmwareScrollMaxFrames) {
    abortScrollTooLong(projectedFrames);
    return;
  }
  const frames = [];
  for (let offset = 0; offset <= maxOffset; offset++) {
    const frame = extractFrameFromTextImage(source, offset);
    frames.push(frame);
  }
  scroll.frames = rotateScrollTimelineToFirstLitFrame(frames);
  scroll.signature = sig;
  scroll.dirty = false;
  scroll.frameIndex = Math.min(scroll.frameIndex, Math.max(0, scroll.frames.length - 1));
  scroll.offset = scroll.frameIndex;
  scrollFrame = cloneFrame(scroll.frames[scroll.frameIndex] || blankFrame());
  setScrollPreviewFrame(
    scrollFrame,
    "text_scroll_generated_frame_timeline",
    isScrollPlaybackValue(state.playback) ? "scroll" : "idle",
  );
  log(
    `文字滚动已生成：${frames.length} 帧，逐帧推进 1 LED，垂直居中偏移 ${textScrollVerticalOffset()} 行，约 ${((frames.length * 47) / 1024).toFixed(1)} KB packed`,
  );
  updateScrollUi();
}

// Firmware scroll source-text restore helpers. The meta fetch restores the saved source
// text without overwriting local edits, and preview restore only rebinds a local timeline
// when the generator identity and frame count still match the firmware cache.
function logScrollRestoreDebug(event, payload = {}) {
  if (typeof console !== "undefined" && typeof console.log === "function") {
    console.log(`[scroll-restore] ${event}`, payload);
  }
}

function warnScrollRestoreDebug(event, payload = {}) {
  if (typeof console !== "undefined" && typeof console.warn === "function") {
    console.warn(`[scroll-restore] ${event}`, payload);
  } else {
    logScrollRestoreDebug(event, payload);
  }
}

function exactGeneratorMatch(meta) {
  return (
    meta.fontId === TEXT_SCROLL_FONT_MODEL && meta.generatorVersion === SCROLL_GENERATOR_VERSION
  );
}

function localTimelineMatchesMeta(meta) {
  return (
    meta.uploadComplete === true &&
    !scroll.restoredTextTruncated &&
    exactGeneratorMatch(meta) &&
    Number(meta.frameCount || 0) > 0 &&
    scroll.framesTimelineId === String(meta.scrollTimelineId || "") &&
    scroll.frames.length === Number(meta.frameCount || 0)
  );
}

// Fill from firmware only when there are no unsent local edits; never marks dirty.
function setScrollTextFromFirmware(text, options = {}) {
  const el = $("scroll-text");
  const restoredText = String(text ?? "");
  const force = !!options.force;
  let ok = false;
  let reason = "applied";
  const before = el ? String(el.value ?? "") : "";
  if (!el) {
    reason = "missing_element";
  } else if (!restoredText) {
    reason = "empty_text";
  } else if (scroll.textEdited) {
    reason = "local_text_edited";
  } else if (!force && before && before !== restoredText && before !== scrollDefaultText) {
    reason = "local_value_present";
  } else {
    el.value = restoredText;
    sanitizeScrollTextInput(true);
    applyTextScrollInputFont();
    autoResizeScrollTextInput();
    ok = true;
  }
  logScrollRestoreDebug("set text result", {
    ok,
    reason,
    hasElement: !!el,
    before,
    textLength: restoredText.length,
    afterLength: el ? String(el.value ?? "").length : 0,
    dirty: scroll.dirty,
    textEdited: scroll.textEdited,
  });
  return ok;
}

function applyRestoredScrollPreviewFrame(meta, reason = "text_scroll_restore_preview") {
  scroll.frameIndex = clamp(Number(meta.frameIndex) || 0, 0, Math.max(0, scroll.frames.length - 1));
  scroll.offset = scroll.frameIndex;
  // Index-first sync: snap the preview display to the firmware's current frame (LED is ground
  // truth), then clear the rate sync so the preview starts at the firmware's set speed and the
  // PLL re-measures and converges to the actual speed over the next few seconds.
  scroll.displayIndex = scroll.frameIndex;
  resetFirmwareScrollRate();
  if (scroll.active && !scroll.paused) restartScrollPreviewTimer();
  setScrollPreviewFrame(
    scroll.frames[scroll.frameIndex] || blankFrame(),
    reason,
    scroll.paused ? "scroll_paused" : scroll.active ? "scroll" : "idle",
  );
  updateScrollUi();
}

function applyFirmwareScrollFrameIndex(data, reason = "text_scroll_firmware_frame_index") {
  if (!scroll.frames.length) return false;
  const renderer = data?.renderer || data || {};
  const raw = renderer.scrollFrameIndex ?? renderer.frameIndex;
  const index = Number(raw);
  if (!Number.isFinite(index)) return false;
  scroll.frameIndex = clamp(index, 0, Math.max(0, scroll.frames.length - 1));
  scroll.offset = scroll.frameIndex;
  if (reason === "text_scroll_manual_step_preview") {
    scroll.displayIndex = scroll.frameIndex;
    setScrollPreviewFrame(
      scroll.frames[scroll.displayIndex] || blankFrame(),
      reason,
      scroll.paused || state.playback === "scroll_paused" ? "scroll_paused" : state.playback,
    );
  }
  updateScrollUi();
  return true;
}

function applyScrollRuntimeMeta(meta, source = "scroll_meta") {
  if (!meta || typeof meta !== "object") return;
  const hasActive = typeof meta.firmwareScrollActive === "boolean";
  const hasPaused = typeof meta.firmwareScrollPaused === "boolean";
  if (!hasActive && !hasPaused) return;
  const firmwareActive = !!meta.firmwareScrollActive;
  const firmwarePaused = !!meta.firmwareScrollPaused;
  const hasSplitPauseFlags =
    typeof meta.firmwareScrollUserPaused === "boolean" ||
    typeof meta.firmwareScrollSystemPaused === "boolean";
  const firmwareRunning = firmwareActive || firmwarePaused;
  scroll.firmwareBacked = firmwareRunning;
  if (hasSplitPauseFlags) {
    scroll.userPaused = !!meta.firmwareScrollUserPaused;
    scroll.systemPaused = !!meta.firmwareScrollSystemPaused;
  } else {
    if (firmwarePaused) {
      scroll.systemPaused = !scroll.userPaused;
    } else {
      scroll.userPaused = false;
      scroll.systemPaused = false;
    }
  }
  scroll.paused = firmwarePaused || scroll.userPaused || scroll.systemPaused;
  scroll.active = firmwareRunning && !firmwarePaused;
  state.textScrollActive = firmwareRunning;
  if (firmwarePaused) state.playback = "scroll_paused";
  else if (firmwareActive) state.playback = "scroll";
  else if (isScrollPlaybackValue(state.playback)) state.playback = "idle";
  state.lastRefreshReason = source;
  if (!scroll.active && scroll.timer) {
    clearInterval(scroll.timer);
    scroll.timer = null;
  }
  updateScrollUi();
  renderState();
}

function setScrollRestorePreviewProgress(progress, label) {
  scroll.restoring = true;
  if (!scroll.uploading) scroll.uploading = true;
  setScrollUploadProgress(progress, label);
}

function completeScrollRestorePreviewProgress(label = "同步预览完成") {
  scroll.restoring = false;
  completeScrollUploadProgress(label);
}

function cancelScrollRestorePreviewProgress() {
  scroll.restoring = false;
  scroll.uploading = false;
  resetScrollUploadProgress();
}

async function fetchLatestScrollFrameMetaAfterPreview(baseMeta, source = "restore_preview") {
  const baseTimelineId = String(baseMeta?.scrollTimelineId || "");
  try {
    const latest = await apiGet(API_ENDPOINTS.scrollMeta);
    lastScrollMetaFetchAt = performance.now();
    const latestTimelineId = String(latest?.scrollTimelineId || "");
    if (latest?.ok && (!baseTimelineId || latestTimelineId === baseTimelineId)) {
      logScrollRestoreDebug("frame meta refreshed", {
        source,
        timelineId: latestTimelineId,
        frameIndex: latest.frameIndex,
        frameCount: latest.frameCount,
      });
      return Object.assign({}, baseMeta || {}, latest);
    }
    logScrollRestoreDebug("frame meta refresh skipped", {
      source,
      baseTimelineId,
      latestTimelineId,
      ok: !!latest?.ok,
    });
  } catch (err) {
    warnScrollRestoreDebug("frame meta refresh failed", {
      source,
      error: err?.message || String(err),
    });
  }
  return baseMeta;
}

async function restoreScrollTextFromFirmware(source = "post_boot", options = {}) {
  const autoPreview = options.autoPreview !== false;
  logScrollRestoreDebug("start", {
    source,
    inFlight: scrollMetaFetchInFlight,
    currentTimelineId: scroll.timelineId,
    dirty: scroll.dirty,
    textEdited: scroll.textEdited,
    inputValue: $("scroll-text")?.value,
  });
  if (scrollMetaFetchInFlight) return false;

  scrollMachine.dispatch("RESTORE_BEGIN");
  const restoreToken = scrollMachine.token("restore");

  scrollMetaFetchInFlight = true;
  try {
    const meta = await apiGet(API_ENDPOINTS.scrollMeta);
    if (!scrollMachine.isCurrent(restoreToken)) return false;
    lastScrollMetaFetchAt = performance.now();
    logScrollRestoreDebug("meta response", meta);
    const metaDisplayingScroll = !!(meta?.firmwareScrollActive || meta?.firmwareScrollPaused);
    if (!meta?.ok || !metaDisplayingScroll || !meta.hasSourceText) {
      logScrollRestoreDebug("meta skipped", {
        source,
        ok: !!meta?.ok,
        displayingScroll: metaDisplayingScroll,
        hasSourceText: !!meta?.hasSourceText,
        scrollTimelineId: meta?.scrollTimelineId || "",
      });
      if (!metaDisplayingScroll) {
        clearRecoveredScrollCache(`${source}_not_displaying_scroll`);
      }
      scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
      return false;
    }

    // This firmware head returns sourceText directly from /api/scroll/meta.
    // This build has no dedicated scroll-source route, so keep recovery bound
    // to the same metadata object that provided the timeline and cursor.
    meta.sourceText = meta.hasSourceText ? String(meta.sourceText ?? "") : "";
    if (!scrollMachine.isCurrent(restoreToken)) return false;
    if (!meta.sourceText) {
      logScrollRestoreDebug("source unavailable", {
        source,
        timelineId: meta?.scrollTimelineId || "",
      });
      scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
      return false;
    }

    // C5: Local modification protection not sent, must precede any metadata binding.
    const currentValue = $("scroll-text")?.value || "";
    const restoredText = String(meta.sourceText ?? "");
    const hasLocalUnsentText =
      scroll.textEdited ||
      (currentValue && currentValue !== restoredText && currentValue !== scrollDefaultText);
    if (hasLocalUnsentText) {
      setScrollRestoreWarning("硬件有滚动文字可恢复，但输入框已有未发送内容，未自动覆盖。");
      logScrollRestoreDebug("guard blocked", {
        source,
        currentValue,
        restoredTextLength: restoredText.length,
        textEdited: scroll.textEdited,
      });
      updateScrollUi();
      scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
      return false;
    }

    scroll.restoreWarning = ""; // D6: Clean recovery starts with blank warning
    scroll.restoredTextTruncated = false; // E4
    scroll.textEdited = false;
    scroll.restoredSourceText = restoredText;
    pendingScrollMeta = meta;
    scroll.timelineId = String(meta.scrollTimelineId || "");
    lastFwScrollTimelineId = scroll.timelineId;
    lastFwScrollHasSourceText = !!meta.hasSourceText;
    lastFwScrollFrameCount = Math.max(0, Number(meta.frameCount || 0) || 0);
    lastFwScrollDisplaying = true;
    scroll.restoredFromFirmwareMeta = true;
    applyScrollRuntimeMeta(meta, `scroll_restore_meta_${source}`);
    logScrollRestoreDebug("binding meta", {
      source,
      restoredTextLength: restoredText.length,
      timelineId: meta.scrollTimelineId,
      fontId: meta.fontId,
      generatorVersion: meta.generatorVersion,
      frameCount: meta.frameCount,
      frameIndex: meta.frameIndex,
      uploadComplete: meta.uploadComplete,
    });
    setScrollTextFromFirmware(restoredText);
    // Only report truncation when the firmware text truly exceeds the WebUI editable
    // visible-character limit. Do not compare raw firmware text to sanitize() output:
    // emoji presentation normalization / format-control stripping can change the string
    // without any actual truncation.
    if (scrollTextExceedsUiCharLimit(restoredText)) {
      scroll.restoredTextTruncated = true; // E4
      setScrollRestoreWarning("硬件滚动文字超过 WebUI 输入上限，已截断显示；预览仅供参考。"); // E5
    } else {
      scroll.restoredTextTruncated = false;
    }
    applyFirmwareScrollFps(meta, `scroll_restore_${source}`);
    if (!exactGeneratorMatch(meta)) {
      setScrollRestoreWarning("文字已从硬件恢复，但字体/生成器版本不同，预览可能与 LED 不一致。"); // E5: append instead of overwrite
    }
    updateScrollUi();
    // C4: When restoring, 6.4 is already the current page, or the firmware is scrolling/pausing, the preview will be rebuilt immediately.
    // The page returns to basic by default when refreshing, but the paused state still needs to be generated immediately and stopped at the current frame.
    // ensureScrollFontsLoaded() returns undefined (cannot .then());
    // restoreScrollPreviewIfNeeded internally uses prepareTextScrollTimelineAsync and other fonts.
    if (autoPreview && (isScrollPageActive() || meta.firmwareScrollActive || meta.firmwareScrollPaused)) {
      ensureScrollFontsLoaded();
      restoreScrollPreviewIfNeeded(
        isScrollPageActive() ? "restore_active_page" : "restore_firmware_scroll_state",
        restoreToken
      ).catch((err) => {
        warnScrollRestoreDebug("preview restore immediate failed", {
          error: err?.message || String(err),
        });
      });
    } else {
      scrollMachine.dispatch("RESTORE_DONE", meta, restoreToken);
    }
    return true;
  } catch (err) {
    warnScrollRestoreDebug("meta fetch failed", {
      source,
      error: err?.message || String(err),
    });
    scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
    return false;
  } finally {
    scrollMetaFetchInFlight = false;
  }
}

async function ensureLocalScrollFramesRestored(source = "scroll_action_restore") {
  if (scroll.frames.length) return true;
  if (!hasRestorableFirmwareScrollSource()) return false;
  scroll.restoring = true;
  updateScrollUi();
  try {
    const restored = await restoreScrollTextFromFirmware(source, { autoPreview: false });
    if (!restored && !pendingScrollMeta) return false;
    await restoreScrollPreviewIfNeeded(source);
    return scroll.frames.length > 0;
  } finally {
    scroll.restoring = false;
    updateScrollUi();
  }
}

async function syncScrollStateTextFpsLightweightAfterBoot(source = "post_loader_scroll_sync") {
  if (scroll.lightSyncing || scroll.restoring || scroll.uploading || scroll.startBusy || scrollMetaFetchInFlight) return false;
  scroll.lightSyncing = true;
  scrollMetaFetchInFlight = true;
  try {
    const meta = await apiGet(API_ENDPOINTS.scrollMeta);
    lastScrollMetaFetchAt = performance.now();
    logScrollRestoreDebug("light sync meta", { source, meta });

    const displaying = !!(meta?.firmwareScrollDisplaying || meta?.firmwareScrollActive || meta?.firmwareScrollPaused);
    applyScrollRuntimeMeta(meta, `${source}_meta`);
    applyFirmwareScrollFps(meta, source);

    if (!meta?.ok || !displaying || !meta.hasSourceText || scroll.textEdited) {
      updateScrollUi();
      renderState();
      return false;
    }

    const restoredText = meta.hasSourceText ? String(meta.sourceText ?? "") : "";
    if (restoredText && String(meta.scrollTimelineId || "")) {
      scroll.restoreWarning = "";
      scroll.restoredSourceText = restoredText;
      scroll.timelineId = String(meta.scrollTimelineId || "");
      scroll.restoredFromFirmwareMeta = true;
      pendingScrollMeta = null;
      setScrollTextFromFirmware(restoredText, { force: true });
      scroll.restoredTextTruncated = scrollTextExceedsUiCharLimit(restoredText);
      if (scroll.restoredTextTruncated) {
        setScrollRestoreWarning("硬件滚动文字超过 WebUI 输入上限，已截断显示；预览仅供参考。");
      }
      applyFirmwareScrollFps(meta, `${source}_meta_source`);
    }

    updateScrollUi();
    renderState();
    return true;
  } finally {
    scrollMetaFetchInFlight = false;
    scroll.lightSyncing = false;
  }
}

function kickPostBootScrollMetaRestore(source = "post_boot") {
  if (postBootScrollMetaRestoreStarted) {
    logScrollRestoreDebug("post_boot already started", { source });
    return Promise.resolve(false);
  }
  postBootScrollMetaRestoreStarted = true;
  scrollMetaRestoreEnabled = true;
  // Full automatic restore on every refresh/boot: read /api/scroll/meta, and when the firmware
  // is displaying text scroll with recoverable sourceText, pull the source string + set FPS,
  // regenerate the preview frames BROWSER-SIDE, snap to the firmware's current frame index, and
  // start animating the preview. The PLL (recordFirmwareScrollSample, driven by status polls)
  // then converges the preview to the device's measured ACTUAL speed. restoreScrollTextFrom
  // Firmware triggers the preview rebuild whenever the firmware is scrolling, even if the
  // current page isn't 6.4, so a refresh restores the running scroll without user action.
  return restoreScrollTextFromFirmware(source, { autoPreview: true }).catch((err) => {
    warnScrollRestoreDebug("post-loader full restore failed", {
      source,
      error: err?.message || String(err),
    });
    return false;
  });
}

async function manualRestoreScrollFromFirmware() {
  // Product behavior no longer exposes a manual restore button. Keep this as a
  // compatibility no-op for stale cached HTML or external test harnesses.
  return syncScrollStateTextFpsLightweightAfterBoot("manual_restore_compat");
}

function shouldShowScrollRestoreButton() {
  return false;
}

async function restoreScrollPreviewIfNeeded(source = "restore_preview", restoreToken = null) {
  logScrollRestoreDebug("preview restore start", {
    source,
    hasPendingMeta: !!pendingScrollMeta,
    restoredSourceTextLength: scroll.restoredSourceText?.length || 0,
    inputValue: $("scroll-text")?.value,
    timelineId: scroll.timelineId,
    framesTimelineId: scroll.framesTimelineId,
    framesLength: scroll.frames.length,
  });
  setScrollTextFromFirmware(scroll.restoredSourceText); // Late DOM padding
  if (!pendingScrollMeta) {
    logScrollRestoreDebug("preview restore end", {
      source,
      result: "no_pending_meta",
    });
    scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
    return;
  }
  const meta = pendingScrollMeta;
  const inputEl = $("scroll-text");
  if (!inputEl) {
    logScrollRestoreDebug("preview restore end", {
      source,
      result: "waiting_for_dom",
    });
    scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
    return;
  }
  if (scroll.textEdited) {
    pendingScrollMeta = null;
    logScrollRestoreDebug("preview restore end", {
      source,
      result: "local_text_edited",
    });
    scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
    return;
  }
  const currentValue = String(inputEl.value ?? "");
  if (currentValue && scroll.restoredSourceText && currentValue !== scroll.restoredSourceText) {
    scroll.restoredTextTruncated = true;
    setScrollRestoreWarning("硬件滚动文字超过 WebUI 输入上限，已截断显示；预览仅供参考。");
  }
  if (localTimelineMatchesMeta(meta)) {
    setScrollRestorePreviewProgress(0.88, "同步当前帧编号");
    const latestMeta = await fetchLatestScrollFrameMetaAfterPreview(meta, `${source}_cached`);
    if (!scrollMachine.isCurrent(restoreToken)) return;
    applyScrollRuntimeMeta(latestMeta, `scroll_restore_preview_${source}_cached`);
    applyRestoredScrollPreviewFrame(latestMeta, "text_scroll_restore_preview_cached");
    pendingScrollMeta = null;
    completeScrollRestorePreviewProgress("同步预览完成");
    logScrollRestoreDebug("preview restore end", {
      source,
      result: "local_timeline_match",
      frameIndex: scroll.frameIndex,
      framesTimelineId: scroll.framesTimelineId,
      framesLength: scroll.frames.length,
    });
    scrollMachine.dispatch("RESTORE_DONE", latestMeta, restoreToken);
    return;
  }
  try {
    setScrollRestorePreviewProgress(0.02, "开始生成同步预览");
    const prepared = await prepareTextScrollTimelineForRestoreAsync(
      true,
      (progress, label) => {
        setScrollRestorePreviewProgress(progress, label);
      },
      restoreToken ? () => !scrollMachine.isCurrent(restoreToken) : null,
    );
    if (!scrollMachine.isCurrent(restoreToken)) return;
    if (!prepared) {
      pendingScrollMeta = null;
      cancelScrollRestorePreviewProgress();
      scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
      return;
    }
  } catch (err) {
    warnScrollRestoreDebug("prepareTextScrollTimelineAsync error", {
      source,
      error: err?.message || String(err),
    });
    cancelScrollRestorePreviewProgress();
    scrollMachine.dispatch("RESTORE_DONE", {}, restoreToken);
    return;
  }
  setScrollRestorePreviewProgress(0.92, "读取当前固件帧编号");
  const latestMeta = await fetchLatestScrollFrameMetaAfterPreview(meta, source);
  if (!scrollMachine.isCurrent(restoreToken)) return;
  pendingScrollMeta = null;
  applyScrollRuntimeMeta(latestMeta, `scroll_restore_preview_${source}`);

  // D5/E4: Bind frame identity only if text is not truncated + generator identity matches exactly + frame number is consistent.
  if (
    !scroll.restoredTextTruncated && // E4
    exactGeneratorMatch(latestMeta) &&
    scroll.frames.length === Number(latestMeta.frameCount || 0)
  ) {
    scroll.framesTimelineId = String(latestMeta.scrollTimelineId || "");
  } else {
    scroll.framesTimelineId = "";
    if (scroll.frames.length !== Number(latestMeta.frameCount || 0)) {
      setScrollRestoreWarning("文字已恢复，但本地重新生成的帧数与硬件不一致；预览仅供参考。");
    }
  }

  // H-B: After the preview frame is generated, use the latest firmware frameIndex to synchronize the current frame.
  applyRestoredScrollPreviewFrame(latestMeta);
  completeScrollRestorePreviewProgress("同步预览完成");
  logScrollRestoreDebug("preview restore end", {
    source,
    result: "generated",
    frameIndex: scroll.frameIndex,
    framesTimelineId: scroll.framesTimelineId,
    framesLength: scroll.frames.length,
    expectedFrameCount: Number(latestMeta.frameCount || 0),
    exactGeneratorMatch: exactGeneratorMatch(latestMeta),
    restoredTextTruncated: scroll.restoredTextTruncated,
  });
  scrollMachine.dispatch("RESTORE_DONE", latestMeta, restoreToken);
}

function buildTextScrollBitmap(text) {
  const key = `${text}@@${TEXT_SCROLL_FONT_MODEL}@@${arkPixelFont.source}@@centerY${textScrollVerticalOffset()}`;
  if (buildTextScrollBitmap.cacheKey === key && buildTextScrollBitmap.cache)
    return buildTextScrollBitmap.cache;
  if (!arkPixelFont.ready) throw new Error("Ark Pixel Font bitmap table is not ready");
  const rawChars = Array.from(text || " ").filter(
    (ch) => !isEmojiFormatControl(codePointOfChar(ch)),
  );
  const glyphs = rawChars.map((ch) => buildTextGlyph(ch));
  const leadingBlank = COLS + 4;
  const trailingBlank = COLS + 4;
  let contentWidth = 0;
  for (let i = 0; i < glyphs.length; i++) {
    contentWidth += glyphs[i].advance;
    const next = glyphs[i + 1];
    if (next && !glyphs[i].isSpace && !next.isSpace) contentWidth += TEXT_SCROLL_CHAR_SPACING;
  }
  const width = Math.max(COLS * 2 + 8, leadingBlank + contentWidth + trailingBlank);
  const bitmap = Array.from(
    {
      length: ROWS,
    },
    () => Array(width).fill(false),
  );
  let x = leadingBlank;
  for (let i = 0; i < glyphs.length; i++) {
    const g = glyphs[i];
    if (!g.isSpace) blitGlyphBitmap(bitmap, x, g);
    x += g.advance;
    const next = glyphs[i + 1];
    if (next && !g.isSpace && !next.isSpace) x += TEXT_SCROLL_CHAR_SPACING;
  }
  buildTextScrollBitmap.cacheKey = key;
  buildTextScrollBitmap.cache = {
    bitmap,
    width,
    glyphs,
    contentWidth,
  };
  return buildTextScrollBitmap.cache;
}

function getArkGlyph(cp) {
  const codepoint = Number(cp) || 0;
  let g = arkPixelFont.glyphs.get(codepoint);
  if (g) return g;
  const missing = arkPixelFont.glyphs.get(TEXT_SCROLL_MISSING_GLYPH_CP);
  if (missing)
    return {
      ...missing,
      missingFor: codepoint,
    };
  throw new Error(`Ark Pixel Font 缺少 U+${codepoint.toString(16).toUpperCase().padStart(4, "0")}`);
}

function normalizeGlyphRows(rows, width, height) {
  const out = [];
  const w = Math.max(0, Number(width) || 0);
  const h = Math.max(0, Number(height) || 0);
  const source = Array.isArray(rows) ? rows : [];
  for (let y = 0; y < h; y++) {
    let row = String(source[y] || "");
    if (/^[01]+$/.test(row)) {
      out.push(row.padEnd(w, "0").slice(0, w));
      continue;
    }
    // Defensive fallback: Compatible with older compressed lines that may still be hex strings.
    let bits = "";
    const clean = row.replace(/[^0-9a-fA-F]/g, "");
    for (const ch of clean) bits += parseInt(ch, 16).toString(2).padStart(4, "0");
    out.push(bits.padEnd(w, "0").slice(0, w));
  }
  return out;
}

function buildTextGlyph(ch) {
  if (!buildTextGlyph.cache) buildTextGlyph.cache = new Map();
  const cp = codePointOfChar(ch || " ");
  if (buildTextGlyph.cache.has(cp)) return buildTextGlyph.cache.get(cp);

  if (!String(ch || "").trim()) {
    const spaceGlyph = {
      cp,
      char: ch,
      isSpace: true,
      advance: TEXT_SCROLL_SPACE_COLUMNS,
      width: 0,
      height: 0,
      xOffset: 0,
      yOffset: 0,
      dstY: 0,
      rows: [],
    };
    buildTextGlyph.cache.set(cp, spaceGlyph);
    return spaceGlyph;
  }

  const raw = getArkGlyph(cp);
  const width = Math.max(0, Number(raw.width) || 0);
  const height = Math.max(
    0,
    Number(raw.height) ||
      (Array.isArray(raw.rows) ? raw.rows.length : arkPixelFont.lineHeight || 12),
  );
  const rawAdvance = Number(raw.advance);
  const glyph = {
    cp,
    char: ch,
    isSpace: false,
    advance: Number.isFinite(rawAdvance)
      ? Math.max(0, rawAdvance)
      : Math.max(1, arkPixelFont.defaultAdvance || width || 12),
    width,
    height,
    xOffset: Number(raw.xOffset || 0),
    yOffset: Number(raw.yOffset || 0),
    dstY: Number(raw.dstY || 0),
    rows: normalizeGlyphRows(raw.rows, width, height),
    missingFor: raw.missingFor,
  };
  buildTextGlyph.cache.set(cp, glyph);
  return glyph;
}

function glyphPixel(glyph, x, y) {
  if (!glyph || !glyph.rows || y < 0 || y >= glyph.rows.length) return false;
  const row = String(glyph.rows[y] || "");
  return row[x] === "1";
}

function blitGlyphBitmap(bitmap, x0, glyph) {
  if (!bitmap || !bitmap.length || !glyph || glyph.isSpace) return;
  const baseY =
    textScrollVerticalOffset() + (Number(glyph.dstY) || 0) + (Number(glyph.yOffset) || 0);
  const baseX = Math.round(x0 + (Number(glyph.xOffset) || 0));
  for (let gy = 0; gy < glyph.height; gy++) {
    const y = baseY + gy;
    if (y < 0 || y >= ROWS) continue;
    const row = bitmap[y];
    for (let gx = 0; gx < glyph.width; gx++) {
      if (!glyphPixel(glyph, gx, gy)) continue;
      const x = baseX + gx;
      if (x >= 0 && x < row.length) row[x] = true;
    }
  }
}

function extractFrameFromTextImage(source, offset) {
  const frame = blankFrame();
  if (!source || !Array.isArray(source.bitmap)) return frame;
  const start = Math.max(0, Number(offset) || 0);
  for (let y = 0; y < ROWS; y++) {
    const srcRow = source.bitmap[y] || [];
    const [x0, x1] = ROW_RANGES[y];
    for (let x = x0; x <= x1; x++) {
      const idx = XY_TO_INDEX[y][x];
      if (idx < 0) continue;
      const srcX = start + x;
      frame[idx] = !!srcRow[srcX];
    }
  }
  return frame;
}

function setDomDisabledIfChanged(el, disabled) {
  if (!el) return false;
  const next = !!disabled;
  if (el.disabled === next) return false;
  el.disabled = next;
  return true;
}

function setDomTextIfChanged(el, text) {
  if (!el) return false;
  const next = String(text);
  if (el.textContent === next) return false;
  el.textContent = next;
  return true;
}

function setDomClassIfChanged(el, className, enabled) {
  if (!el) return false;
  const next = !!enabled;
  const current = el.classList.contains(className);
  if (current === next) return false;
  el.classList.toggle(className, next);
  return true;
}

function setDomAttrIfChanged(el, name, value) {
  if (!el) return false;
  if (value === null || value === undefined || value === false) {
    if (!el.hasAttribute(name)) return false;
    el.removeAttribute(name);
    return true;
  }
  const next = String(value);
  if (el.getAttribute(name) === next) return false;
  el.setAttribute(name, next);
  return true;
}

const scrollButtonUiCache = {
  send: null,
  pause: null,
  stop: null,
  stepPrev: null,
  stepNext: null,
  speedMinus: null,
  speedPlus: null,
  speedReset: null,
};

function applyScrollButtonUiState(key, el, nextState) {
  if (!el || !nextState) return;
  const prevState = scrollButtonUiCache[key];
  const same =
    prevState &&
    prevState.disabled === nextState.disabled &&
    prevState.text === nextState.text &&
    prevState.title === nextState.title &&
    prevState.pressed === nextState.pressed;
  if (same) return;
  scrollButtonUiCache[key] = { ...nextState };
  setDomDisabledIfChanged(el, nextState.disabled);
  // aria-disabled must follow disabled, otherwise the initial aria-disabled="true" in HTML
  // (scroll-pause/scroll-stop) will never be cleared, resulting in screen reading errors and invalid press animation.
  setDomAttrIfChanged(el, "aria-disabled", nextState.disabled ? "true" : "false");
  if (nextState.text !== undefined) {
    setDomTextIfChanged(el, nextState.text);
  }
  if (nextState.title !== undefined) {
    setDomAttrIfChanged(el, "title", nextState.title);
  }
  if (nextState.pressed !== undefined) {
    setDomAttrIfChanged(el, "aria-pressed", nextState.pressed ? "true" : "false");
  }
}

function updatePresetButtonActiveState(disabled = false) {
  const fps = getScrollFps();
  const box = $("scroll-speed-presets");
  if (!box) return;
  box.querySelectorAll("button").forEach((btn) => {
    const value = Number(btn.dataset.fps);
    const active = value === fps;
    setDomClassIfChanged(btn, "active", active);
    setDomAttrIfChanged(btn, "aria-pressed", active ? "true" : "false");
    setDomDisabledIfChanged(btn, disabled);
    setDomAttrIfChanged(btn, "aria-disabled", disabled ? "true" : "false");
  });
}

function updateScrollUi() {
  const stateEl = $("scroll-state");
  const indexEl = $("scroll-frame-index");
  const pauseBtn = $("scroll-pause");
  const playBtn = $("scroll-play");
  const stopBtn = $("scroll-stop");
  const stepPrevBtn = $("scroll-step-prev");
  const stepNextBtn = $("scroll-step-next");
  const speedResetBtn = $("scroll-speed-reset-default");
  const speedMinusBtn = $("scroll-speed-minus");
  const speedPlusBtn = $("scroll-speed-plus");
  const speedRangeEl = $("scroll-speed-range");
  const speedInputEl = $("scroll-speed");
  const progressWrap = $("scroll-upload-progress");
  const progressBar = $("scroll-upload-bar");
  const progressLabel = $("scroll-upload-label");

  const progressVisible = isScrollProgressVisible();
  const hasInputContent = hasScrollInputContent();
  const hasFrameCache = hasScrollFrameCache();
  const hasFramesForStep = hasUsableOrRestorableScrollFrames();

  const effectivePaused =
    state.playback === "scroll_paused" ||
    scroll.paused ||
    scroll.userPaused ||
    scroll.systemPaused;

  const scrollPlayingNow =
    !effectivePaused &&
    (scroll.active ||
      scroll.firmwareBacked ||
      state.textScrollActive ||
      state.playback === "scroll" ||
      state.playback === "scroll_step");

  const hardBusy = scroll.uploading || scroll.restoring;

  const label = scroll.startBusy
    ? "uploading"
    : scroll.restoring
      ? "syncing"
      : progressVisible
        ? "uploading"
        : effectivePaused
          ? "paused"
          : scroll.active || state.playback === "scroll"
            ? "playing"
            : scroll.dirty
              ? "dirty/idle"
              : "idle";

  if (stateEl) setDomTextIfChanged(stateEl, label);
  if (indexEl) {
    const displayIndex = Number.isFinite(scroll.displayIndex) ? scroll.displayIndex : scroll.frameIndex || 0;
    setDomTextIfChanged(indexEl, `${displayIndex || 0} / ${scroll.frames?.length || 0}`);
  }

  const nonResumableSystemPause = scroll.systemPaused && !scroll.userPaused;

  // commandBusy / pauseBusy / stepBusy / fpsBusy are single round-trip aux commands (pause/continue/
  // Stop / frame by frame / frame rate) reentrant lock, each handler function has been in the entry `if (scroll.commandBusy ...) return`
  // Block repeated clicks yourself. Therefore these transient in-transit flags should not be reflected on the disabled button - otherwise
  // Every normal click will cause all buttons to flash disabled->enabled. only real long process
  // (uploading / restoring) requires visibly disabling the control on the button.
  const anyCommandBusy = hardBusy;

  // Pause/resume only makes sense when actually playing or in a controlled pause; only when text is entered or frames are cached
  // (idle) Pause button should not be shown as available/pressed.
  const scrollLiveOrPaused = scrollPlayingNow || effectivePaused;

  applyScrollButtonUiState("send", playBtn, {
    disabled: anyCommandBusy || scroll.startBusy || !hasInputContent,
    text: scroll.uploading ? "发送中…" : "发送",
  });

  applyScrollButtonUiState("pause", pauseBtn, {
    disabled: anyCommandBusy || nonResumableSystemPause || !scrollLiveOrPaused,
    text: effectivePaused ? "继续" : "暂停",
    pressed: scrollPlayingNow,
  });

  applyScrollButtonUiState("stop", stopBtn, {
    disabled: anyCommandBusy || !hasFrameCache,
  });

  const stepDisabled = anyCommandBusy || scrollPlayingNow || !hasFramesForStep;
  applyScrollButtonUiState("stepPrev", stepPrevBtn, { disabled: stepDisabled });
  applyScrollButtonUiState("stepNext", stepNextBtn, { disabled: stepDisabled });

  const speedDisabled = anyCommandBusy;
  applyScrollButtonUiState("speedMinus", speedMinusBtn, { disabled: speedDisabled });
  applyScrollButtonUiState("speedPlus", speedPlusBtn, { disabled: speedDisabled });
  applyScrollButtonUiState("speedReset", speedResetBtn, { disabled: speedDisabled });

  if (speedRangeEl) {
    setDomDisabledIfChanged(speedRangeEl, speedDisabled);
    setDomAttrIfChanged(speedRangeEl, "aria-disabled", speedDisabled ? "true" : "false");
  }
  if (speedInputEl) {
    setDomDisabledIfChanged(speedInputEl, speedDisabled);
    setDomAttrIfChanged(speedInputEl, "aria-disabled", speedDisabled ? "true" : "false");
  }

  updatePresetButtonActiveState(speedDisabled);

  if (progressWrap) progressWrap.hidden = !progressVisible;
  if (progressBar) progressBar.value = Math.round(clamp(scroll.uploadProgress || 0, 0, 1) * 100);
  if (progressLabel) setDomTextIfChanged(progressLabel, scroll.uploadLabel || "等待发送");

  // Restore warnings (can be multi-line, E5); textContent + CSS white-space:pre-line renders newlines.
  const restoreWarnEl = $("scroll-restore-warning");
  if (restoreWarnEl) {
    setDomTextIfChanged(restoreWarnEl, scroll.restoreWarning || "");
    restoreWarnEl.hidden = !scroll.restoreWarning;
  }

  // No manual restore button: boot/page-entry sync is automatic and lightweight.
  const restoreBtnEl = $("scroll-restore-btn");
  if (restoreBtnEl) {
    restoreBtnEl.hidden = true;
    setDomDisabledIfChanged(restoreBtnEl, true);
  }
}

// Matrix previews share the same initialization path to ensure consistent size and rendering.
// Debugging controls and lazy initialization
// Connection relationship:
// - initializeMatrixViews() must create all matrix instances before rendering.
// - debug controls only send diagnostic commands or local test frames and do not change the page structure.
// - deferred init makes the first screen appear first, and the heavier list/debug/font reading continues to complete after the mask is loaded.
function initializeMatrixViews() {
  matrixViews = [];
  initMatrix("matrix-basic", () => currentFrame, false, null, false);
  initMatrix("matrix-custom-edit", () => editFrame, true, editCell, false);
  initMatrix("matrix-parts", () => partsFrame, false, null, false);
  initMatrix("matrix-scroll", () => scrollFrame, false, null, false);
  initMatrix("matrix-debug", () => debugPreviewFrame, false, null, false);
}

function resetBatteryVoltageRecord(kind) {
  const isMax = String(kind) === "max";
  const cmd = isMax ? "reset_battery_max" : "reset_battery_min";
  const label = isMax ? "最高电压" : "最低电压";
  if (isOfflineHtmlMode()) {
    alert("离线 HTML 模式无法重置固件电池记录。");
    return;
  }
  const packet = sendAuxCommand(cmd, {}, `debug_reset_battery_${kind}`);
  packet.promise
    ?.then((data) => {
      if (!data || data.ok === false) {
        throw new Error(firmware.lastError || "battery reset command failed");
      }
      const powerPayload = data?.power && typeof data.power === "object" ? data.power : null;
      if (powerPayload) applyPowerData(powerPayload);
      return refreshPowerStatusFromFirmware(`debug_reset_battery_${kind}_refresh`, true);
    })
    .then(() => {
      log(`已重置电池${label}记录`);
      renderState();
    })
    .catch((err) => {
      log(`重置电池${label}记录失败: ${err.message}`);
    });
}

// ============================================================
// page-debug rewrite: diagnostic rendering helper + 11 panel renderer + safe action helper.
// Note: The function declaration will be promoted, so it can also be called after renderState/updateDps.
// ============================================================
let debugApPasswordShown = false;

function fmtDebugTime(ts) {
  return ts ? new Date(ts).toLocaleTimeString() : "—";
}

function debugSourceClass(source) {
  return (
    {
      Firmware: "src-fw",
      Browser: "src-br",
      Resource: "src-res",
      Config: "src-cfg",
      Computed: "src-cmp",
      Fallback: "src-fallback",
    }[source] || ""
  );
}

// Explicit source metadata for individual kv lines (source no longer inferred from label text, v2 rule 2).
function buildDebugRow({ label, value, source = "", stale = false, note = "", html = false }) {
  const v = value === null || value === undefined || value === "" ? "—" : value;
  return { label, value: v, source, stale: !!stale, note, html: !!html };
}

function renderDebugKvList(targetId, rows) {
  const el = $(targetId);
  if (!el) return;
  el.innerHTML = rows
    .map((r) => {
      const valHtml = r.html ? String(r.value) : escapeHtml(String(r.value));
      const chip = r.source
        ? `<span class="debug-source ${debugSourceClass(r.source)}${r.stale ? " is-stale" : ""}">${escapeHtml(r.stale ? r.source + " · 旧值" : r.source)}</span>`
        : "";
      const note = r.note
        ? ` <span class="debug-source src-cmp">${escapeHtml(r.note)}</span>`
        : "";
      return `<span class="k">${escapeHtml(r.label)}</span><span>${valHtml}${chip}${note}</span>`;
    })
    .join("");
}

function renderDebugBadge(label, dotClass = "status-dot") {
  return `<span class="badge"><span class="${dotClass}"></span>${escapeHtml(label)}</span>`;
}

// Parametric power estimate common to DPS / full-light warning (pulled from updateDps, v2 rule 6).
function estimateFrameWatts(frame, colorHex, brightness) {
  const rgb = hexToRgb(colorHex);
  const colorFactor = (rgb.r + rgb.g + rgb.b) / (LED_FULL_BRIGHTNESS * 3);
  return (
    onCount(frame) *
    LED_ESTIMATED_WATTS_PER_CHANNEL *
    LED_CHANNEL_COUNT *
    (brightness / LED_FULL_BRIGHTNESS) *
    colorFactor
  );
}

// Pure function: save expression -> frame, no side effects (for preview-only, v2 rule 5).
function getSavedFaceFrame(i) {
  const face = getAllFaces()[i];
  return faceFrame(face);
}

function renderDpsWarning() {
  ["debug-summary-dps-warning", "debug-power-dps-warning"].forEach((id) => {
    const el = $(id);
    if (el) el.classList.toggle("show", !!state.dpsActive);
  });
}

function setDebugActionBusy(actionId, busy) {
  const el = $(actionId);
  if (!el) return;
  el.disabled = !!busy;
  el.classList.toggle("busy", !!busy);
}

function showDebugActionResult(resultId, result) {
  const el = $(resultId);
  if (!el) return;
  el.classList.remove("ok", "err", "pending");
  if (!result) {
    el.textContent = "";
    return;
  }
  el.classList.add(result.pending ? "pending" : result.ok ? "ok" : "err");
  el.textContent = result.msg || "";
}

function validatePackedFrameInput(text) {
  const raw = String(text || "");
  const compact = raw.trim().replace(/^(?:PACKED|FRAME|HEX|BASE64):/i, "").replace(/\s+/g, "");
  const expectedLen = PACKED_FRAME_HEX_CHARS;
  try {
    parsePackedFrameText(raw);
    return { valid: true, normalizedLen: compact.length, expectedLen, error: "" };
  } catch (err) {
    return { valid: false, normalizedLen: compact.length, expectedLen, error: err.message || String(err) };
  }
}

function parsePackedFrameOrError(text) {
  try {
    return { frame: parsePackedFrameText(text) };
  } catch (err) {
    return { error: err.message || String(err) };
  }
}

// preview-only only writes debugPreviewFrame (does not touch currentFrame/setCurrentFrame/queueFirmwareFrame,
// updateDps is not called); send uses setCurrentFrame and then mirrors to the preview buffer (v2 rule 1).
function applyDebugFrame(frame, source = "debug pattern", options = {}) {
  if (options.send) {
    setCurrentFrame(frame, options.reason || "debug_send", "idle");
    debugPreviewFrame = cloneFrame(currentFrame);
    debugPreviewSource = "firmware";
  } else {
    debugPreviewFrame = cloneFrame(frame);
    debugPreviewSource = source;
  }
  debugPreviewReason = options.reason || source;
  debugPreviewUpdatedAt = Date.now();
  renderMatrices();
  renderDebugPreviewPanel();
}

function confirmDangerAction({ title = "确认操作", body = "", confirmWord = "" } = {}) {
  if (confirmWord) {
    const ans = window.prompt(`${title}\n\n${body}\n\n输入 ${confirmWord} 以确认：`);
    return ans != null && ans.trim().toUpperCase() === confirmWord.toUpperCase();
  }
  return window.confirm(`${title}\n\n${body}`);
}

// Copy the diagnostic JSON; never include the AP password (v2 rule 10).
function copyDebugDiagnostics(scope = "full") {
  const summary = {
    mode: state.mode,
    faceIndex: state.faceIndex,
    brightness: state.brightness,
    color: state.color,
    playback: state.playback,
    textScrollActive: state.textScrollActive,
    apIp: state.apIp,
    apIpSource: state.apIpSource,
    apDomain: state.apDomain,
    apDomainSource: state.apDomainSource,
    battery: batteryPowerText(),
    batteryPercent: state.batteryPercent,
    lastStatusSyncAt: state.lastStatusSyncAt,
  };
  const fw = {
    online: firmware.online,
    lastRequest: firmware.lastRequest,
    lastStatus: firmware.lastStatus,
    lastError: firmware.lastError,
    firmwareLastSyncAt,
    sentFrames: firmware.sentFrames,
    sentCommands: firmware.sentCommands,
    droppedFrames: firmware.droppedFrames,
    droppedCommands: firmware.droppedCommands,
    frameQueue: firmware.frameQueue,
    buttonQueue: firmware.buttonQueue,
    savedFacesSync: firmware.savedFacesSync,
  };
  const power = {
    batteryPowered: state.batteryPowered,
    batteryV: state.batteryV,
    batteryPercent: state.batteryPercent,
    batteryMinV: state.batteryMinV,
    batteryMaxV: state.batteryMaxV,
    chargeV: state.chargeV,
    charging: state.charging,
    dpsActive: state.dpsActive,
    lastPowerSyncAt: state.lastPowerSyncAt,
  };
  let payload;
  if (scope === "summary") payload = summary;
  else if (scope === "firmware") payload = fw;
  else
    payload = {
      summary,
      firmware: fw,
      power,
      resource: {
        ledCount: TOTAL_LEDS,
        matrix: `${COLS}x${ROWS}`,
        defaultFaces: defaultFaces.length,
        userSavedFaces: userFaces.length,
      },
      preview: {
        source: debugPreviewSource,
        reason: debugPreviewReason,
        updatedAt: debugPreviewUpdatedAt,
        onCount: onCount(debugPreviewFrame),
      },
    };
  copyText(JSON.stringify(payload, null, 2));
  log(`已复制诊断 JSON (${scope})；可能含 SSID/IP/域名，已排除 AP 密码`);
}

// ---- Read-only panel renderer (called by renderDebugReadouts when the debug page is active) ----
function renderDebugReadouts() {
  if (document.body?.dataset?.page !== "debug") return;
  renderDebugDeviceSummary();
  renderDebugFirmwareHealth();
  renderDebugPowerPanel();
  renderDebugNetworkPanel();
  renderDebugResourcePanel();
  renderDebugPreviewPanel();
}

function renderDebugDeviceSummary() {
  const lib = getAllFaces();
  const face = lib[state.faceIndex] || { name: "—", type: "—" };
  const online = firmware.online;
  const stale = !online;

  const connection = firmwareConnectionUiState();
  const linkBadge = renderDebugBadge(connection.label, connection.dotClass);

  let outTxt = "未知",
    outDot = "status-dot dim";
  const pb = String(state.playback || "").toLowerCase();
  if (state.textScrollActive) {
    outTxt = "滚动文字";
    outDot = "status-dot";
  } else if (pb.includes("pause")) {
    outTxt = "已暂停";
    outDot = "status-dot warn";
  } else if (pb === "idle" || pb === "manual" || pb === "auto" || pb === "playing") {
    outTxt = "显示表情";
    outDot = "status-dot";
  }

  let powerTxt = "未知",
    powerDot = "status-dot dim";
  if (state.charging === true) {
    powerTxt = "充电中";
    powerDot = "status-dot";
  } else if (state.batteryPowered === false) {
    powerTxt = "未上电";
    powerDot = "status-dot danger";
  } else if (state.batteryLowVoltageUnpowered) {
    powerTxt = "低压锁定";
    powerDot = "status-dot warn";
  } else if (state.batteryPowered) {
    powerTxt = "电池供电";
    powerDot = "status-dot";
  }

  let pipeTxt = "本地预览",
    pipeDot = "status-dot dim";
  if (firmware.droppedFrames > 0 || firmware.droppedCommands > 0) {
    pipeTxt = "队列有丢弃";
    pipeDot = "status-dot warn";
  } else if (firmware.sentFrames > 0) {
    pipeTxt = "已发送固件帧";
    pipeDot = "status-dot";
  }

  const netKnown = state.apIpSource === "Firmware";
  renderDebugKvList("debug-summary-conclusions", [
    buildDebugRow({ label: "固件连接", value: linkBadge, html: true }),
    buildDebugRow({ label: "输出状态", value: renderDebugBadge(outTxt, outDot), html: true }),
    buildDebugRow({ label: "电源状态", value: renderDebugBadge(powerTxt, powerDot), html: true }),
    buildDebugRow({ label: "帧管线", value: renderDebugBadge(pipeTxt, pipeDot), html: true }),
    buildDebugRow({
      label: "网络",
      value: renderDebugBadge(netKnown ? "固件 IP 已知" : "配置回退", netKnown ? "status-dot" : "status-dot warn"),
      html: true,
    }),
  ]);

  const colorHex = normalizeHexColor(state.color) || "#000000";
  const colorSwatch = `<span style="display:inline-block;width:10px;height:10px;border-radius:2px;background:${colorHex};vertical-align:middle"></span> ${escapeHtml(state.color)}`;
  renderDebugKvList("debug-summary-kv", [
    buildDebugRow({ label: "当前模式", value: state.mode, source: "Firmware", stale }),
    buildDebugRow({
      label: "表情序号",
      value: `${lib.length ? state.faceIndex + 1 : 0} / ${lib.length}`,
      source: "Firmware",
      stale,
    }),
    buildDebugRow({ label: "表情名称", value: face.name, source: "Firmware", stale }),
    buildDebugRow({ label: "表情属性", value: faceTypeLabel(face.type), source: "Resource" }),
    buildDebugRow({ label: "亮度", value: `${state.brightness}/255`, source: "Firmware", stale }),
    buildDebugRow({ label: "颜色", value: colorSwatch, html: true }),
    buildDebugRow({ label: "播放状态", value: state.playback, source: "Firmware", stale }),
    buildDebugRow({
      label: "文字滚动",
      value: state.textScrollActive ? "active" : "inactive",
      source: "Firmware",
      stale,
    }),
    buildDebugRow({ label: "实际 FPS", value: Number(state.actualFps || 0).toFixed(1), source: "Firmware", stale }),
    buildDebugRow({
      label: "AP IP",
      value: state.apIp,
      source: state.apIpSource,
      stale: stale && state.apIpSource === "Firmware",
    }),
    buildDebugRow({ label: "电池", value: batteryPowerText(), source: "Firmware", stale }),
    buildDebugRow({ label: "最近状态同步", value: fmtDebugTime(state.lastStatusSyncAt), source: "Browser" }),
  ]);
}

function renderDebugFirmwareHealth() {
  renderDebugKvList("debug-firmware-kv", [
    buildDebugRow({ label: "online", value: firmware.online ? "✓ connected" : "✗ offline", source: "Firmware" }),
    buildDebugRow({ label: "最近请求", value: firmware.lastRequest, source: "Browser" }),
    buildDebugRow({ label: "最近状态", value: firmware.lastStatus, source: "Firmware" }),
    buildDebugRow({ label: "最近错误", value: firmware.lastError, source: "Firmware" }),
    buildDebugRow({ label: "最近成功同步", value: fmtDebugTime(firmwareLastSyncAt), source: "Browser" }),
    buildDebugRow({ label: "sent frames", value: String(firmware.sentFrames), source: "Browser", note: "浏览器队列诊断" }),
    buildDebugRow({ label: "sent commands", value: String(firmware.sentCommands), source: "Browser", note: "浏览器队列诊断" }),
    buildDebugRow({ label: "frame queue", value: `${firmware.frameQueue}/${WEBUI_FRAME_QUEUE_MAX}`, source: "Browser" }),
    buildDebugRow({ label: "button queue", value: `${firmware.buttonQueue}/${WEBUI_BUTTON_COMMAND_QUEUE_MAX}`, source: "Browser" }),
    buildDebugRow({ label: "dropped frames", value: String(firmware.droppedFrames), source: "Browser" }),
    buildDebugRow({ label: "dropped commands", value: String(firmware.droppedCommands), source: "Browser" }),
    buildDebugRow({ label: "savedFacesSync", value: firmware.savedFacesSync, source: "Firmware" }),
  ]);
}

function renderDebugPowerPanel() {
  const stale = !firmware.online;
  renderDebugKvList("debug-power-kv", [
    buildDebugRow({ label: "供电状态", value: state.batteryPowered === false ? "未上电" : "已上电", source: "Firmware", stale }),
    buildDebugRow({ label: "电池显示", value: batteryPowerText(), source: "Firmware", stale }),
    buildDebugRow({ label: "电量百分比", value: formatBatteryPercent(state.batteryPercent), source: "Firmware", stale }),
    buildDebugRow({ label: "Vbat 滤波", value: formatVolts(state.batteryV), source: "Firmware", stale }),
    buildDebugRow({ label: "Vbat 瞬时", value: formatVolts(state.batteryLastInstantVbat), source: "Firmware", stale }),
    buildDebugRow({ label: "Vbat 最低", value: formatVolts(state.batteryMinV), source: "Firmware", stale }),
    buildDebugRow({ label: "Vbat 最高", value: formatVolts(state.batteryMaxV), source: "Firmware", stale }),
    buildDebugRow({ label: "最近电源同步", value: fmtDebugTime(state.lastPowerSyncAt), source: "Browser" }),
  ]);
  renderDebugKvList("debug-adc-kv", [
    buildDebugRow({ label: "电池 ADC raw", value: formatMilliVolts(state.batteryAdcMv), source: "Firmware", stale }),
    buildDebugRow({ label: "上次电池 ADC", value: formatMilliVolts(state.batteryPrevAdcMv), source: "Firmware", stale }),
    buildDebugRow({ label: "充电 ADC raw", value: formatMilliVolts(state.chargeAdcMv), source: "Firmware", stale }),
    buildDebugRow({ label: "Vcharge", value: formatVolts(state.chargeV), source: "Firmware", stale }),
    buildDebugRow({ label: "充电状态", value: formatChargingState(state.charging), source: "Firmware", stale }),
    buildDebugRow({ label: "低压未上电锁定", value: state.batteryLowVoltageUnpowered ? "是" : "否", source: "Firmware", stale }),
    buildDebugRow({ label: "未上电低阈值", value: formatVolts(state.batteryUnpoweredLowThreshold), source: "Config" }),
    buildDebugRow({
      label: "断电快速压降",
      value: `${formatMilliVolts(state.batteryDisconnectDropMv)} / 阈值 ${formatMilliVolts(state.batteryDisconnectDropThresholdMv)}`,
      source: "Firmware",
      stale,
    }),
    buildDebugRow({ label: "断电低 ADC 阈值", value: formatMilliVolts(state.batteryDisconnectLowThresholdMv), source: "Firmware", stale }),
    buildDebugRow({ label: "恢复 ADC 阈值", value: formatMilliVolts(state.batteryReconnectThresholdMv), source: "Firmware", stale }),
    buildDebugRow({ label: "DPS 状态", value: state.dpsActive ? "active" : "inactive", source: "Computed" }),
  ]);
  renderDpsWarning();
}

function renderDebugNetworkPanel() {
  const stale = !firmware.online;
  renderDebugKvList("debug-network-kv", [
    buildDebugRow({ label: "AP SSID", value: DEVICE_AP_SSID, source: "Config" }),
    buildDebugRow({
      label: "AP 密码",
      value: debugApPasswordShown ? DEVICE_AP_PASSWORD : "•".repeat(8),
      source: "Config",
    }),
    buildDebugRow({
      label: "AP 域名",
      value: state.apDomain,
      source: state.apDomainSource,
      stale: stale && state.apDomainSource === "Firmware",
    }),
    buildDebugRow({
      label: "AP IP",
      value: state.apIp,
      source: state.apIpSource,
      stale: stale && state.apIpSource === "Firmware",
    }),
  ]);
  const toggle = $("debug-ap-pass-toggle");
  if (toggle) toggle.textContent = debugApPasswordShown ? "隐藏密码" : "显示密码";
}

function renderDebugResourcePanel() {
  const c = EXPRESSION_PARTS.counts;
  renderDebugKvList("debug-resource-kv", [
    buildDebugRow({ label: "LED 数量", value: TOTAL_LEDS, source: "Config" }),
    buildDebugRow({ label: "矩阵", value: `${COLS}x${ROWS} / 不规则 370`, source: "Config" }),
    buildDebugRow({ label: "帧格式", value: `packed-lsb-first · ${PACKED_FRAME_BYTES} bytes / ${PACKED_FRAME_HEX_CHARS} hex`, source: "Config" }),
    buildDebugRow({ label: "物理接线", value: SERPENTINE_WIRING ? "serpentine / 奇数行反向" : "linear", source: "Config" }),
    buildDebugRow({ label: "JSON format", value: EXPRESSION_PARTS.format, source: "Resource" }),
    buildDebugRow({ label: "version", value: EXPRESSION_PARTS.version, source: "Resource" }),
    buildDebugRow({ label: "stored_unique_parts", value: c.stored_unique_parts, source: "Resource" }),
    buildDebugRow({ label: "callable_ids", value: c.callable_ids, source: "Resource" }),
    buildDebugRow({ label: "eye_left", value: c.stored_by_group.eye_left, source: "Resource" }),
    buildDebugRow({ label: "eye_right", value: c.stored_by_group.eye_right, source: "Resource" }),
    buildDebugRow({ label: "mouth", value: c.stored_by_group.mouth, source: "Resource" }),
    buildDebugRow({ label: "cheek", value: c.callable_by_group.cheek, source: "Resource" }),
    buildDebugRow({ label: "default_faces", value: defaultFaces.length, source: "Resource" }),
    buildDebugRow({ label: "user_saved_faces", value: userFaces.length, source: "Resource" }),
    buildDebugRow({ label: "saved_faces_path", value: firmware.savedFacesPath, source: "Config" }),
    buildDebugRow({ label: "savedFacesSync", value: firmware.savedFacesSync, source: "Firmware" }),
    buildDebugRow({ label: "parts_eye_symmetry", value: partsSymmetry ? "on" : "off", source: "Config" }),
  ]);
}

function renderDebugPreviewPanel() {
  const frameHex = packedFrameToHex(debugPreviewFrame);
  renderDebugKvList("debug-preview-kv", [
    buildDebugRow({ label: "来源", value: debugPreviewSource, source: "Computed" }),
    buildDebugRow({ label: "更新原因", value: debugPreviewReason, source: "Browser" }),
    buildDebugRow({ label: "更新时间", value: fmtDebugTime(debugPreviewUpdatedAt), source: "Browser" }),
    buildDebugRow({ label: "亮点数", value: onCount(debugPreviewFrame), source: "Computed" }),
    buildDebugRow({ label: "帧 hex 长度", value: `${frameHex.length} 字符`, source: "Computed" }),
  ]);
}

// Whether offline/online sending should be blocked (send-to-firmware control).
function debugSendBlockedOffline(resultId) {
  if (!firmware.online || isOfflineHtmlMode()) {
    showDebugActionResult(resultId, { ok: false, msg: "固件离线，无法发送到固件" });
    return true;
  }
  return false;
}

// Unified handling of "simulate command" buttons: busy disable + result feedback + only refresh runtime summary on success.
// Handle two offline scenarios (v2 section7): no promise (offline HTML local fallback) / promise failure (network disconnection).
function runDebugSimCommand(btnEl, label, packet) {
  showDebugActionResult("debug-sim-result", { pending: true, msg: `${label}：发送中…` });
  if (btnEl) btnEl.disabled = true;
  const done = (ok, msg) => {
    if (btnEl) btnEl.disabled = false;
    showDebugActionResult("debug-sim-result", { ok, msg: `${label}：${msg}` });
    if (ok) syncRuntimeSummaryFromFirmware(`debug_sim_${label}`);
  };
  const p = packet && packet.promise;
  if (p && typeof p.then === "function") {
    p.then(() =>
      firmware.online
        ? done(true, "成功，已刷新运行时状态")
        : done(false, `失败：${firmware.lastError || "网络错误"}`),
    ).catch((err) => done(false, `失败：${err?.message || err}`));
  } else {
    done(false, isOfflineHtmlMode() ? "离线（已执行本地回退）" : "已发送");
  }
}

function refreshDebugFrameValidation() {
  const ta = $("debug-frame");
  const el = $("debug-frame-validation");
  if (!el) return;
  el.classList.remove("ok", "err");
  const raw = ta?.value || "";
  if (!raw.trim()) {
    el.textContent = "";
    return;
  }
  const v = validatePackedFrameInput(raw);
  el.classList.add(v.valid ? "ok" : "err");
  const meta = `${v.normalizedLen}/${v.expectedLen} hex`;
  el.textContent = v.valid ? `有效 · ${meta}` : `无效：${v.error} · ${meta}`;
}

function refreshDebugRawValidation() {
  const el = $("debug-raw-validation");
  const sendBtn = $("debug-raw-send");
  const confirmed = $("debug-raw-confirm")?.checked;
  const raw = $("debug-raw-json")?.value || "";
  let valid = false;
  let msg = "";
  if (!raw.trim()) {
    msg = "";
  } else {
    try {
      const packet = JSON.parse(raw);
      if (!packet || typeof packet !== "object" || typeof packet.cmd !== "string") {
        msg = "JSON 必须是对象且包含字符串 cmd 字段";
      } else {
        valid = true;
        msg = `合法：cmd = ${packet.cmd}`;
      }
    } catch (err) {
      msg = `JSON 解析错误：${err.message}`;
    }
  }
  if (el) {
    el.classList.remove("ok", "err");
    if (raw.trim()) el.classList.add(valid ? "ok" : "err");
    el.textContent = msg;
  }
  if (sendBtn) sendBtn.disabled = !(valid && confirmed && !isOfflineHtmlMode() && firmware.online);
}

// Debugging controls: local pattern preview only/send to firmware/packed frame verification/dangerous actions, etc.
function initializeDebugControls() {
  setClickHandlers([
    // --- 2. Firmware Connection/API Health ---
    [
      "firmware-ping",
      () => {
        showDebugActionResult("debug-firmware-result", { pending: true, msg: "刷新固件状态中…" });
        syncRuntimeStateFromFirmware("firmware_ping")
          .then(() =>
            showDebugActionResult("debug-firmware-result", {
              ok: firmware.online,
              msg: firmware.online ? "固件状态已刷新" : `失败：${firmware.lastError || "离线"}`,
            }),
          )
          .catch((err) =>
            showDebugActionResult("debug-firmware-result", { ok: false, msg: `失败：${err?.message || err}` }),
          );
      },
    ],
    [
      "debug-fw-refresh-power",
      () => {
        refreshPowerStatusFromFirmware("debug_fw_refresh_power", true);
        showDebugActionResult("debug-firmware-result", { ok: true, msg: "已请求刷新电源状态" });
      },
    ],
    [
      "debug-clear-api-error",
      () => {
        firmware.lastError = "—";
        lastApiErrorLogAt = 0;
        renderState();
        showDebugActionResult("debug-firmware-result", { ok: true, msg: "已清除本地 API 错误" });
      },
    ],
    [
      "debug-copy-diag",
      () => {
        copyDebugDiagnostics("full");
        showDebugActionResult("debug-firmware-result", { ok: true, msg: "已复制诊断 JSON（不含 AP 密码）" });
      },
    ],

    // --- 3. Power supply / battery / ADC ---
    [
      "debug-refresh-power",
      () => {
        refreshPowerStatusFromFirmware("debug_refresh_power", true);
        showDebugActionResult("debug-power-result", { ok: true, msg: "已请求刷新电池状态" });
      },
    ],
    ["debug-reset-battery-min", () => resetBatteryVoltageRecord("min")],
    ["debug-reset-battery-max", () => resetBatteryVoltageRecord("max")],
    [
      "update-adc",
      () => {
        state.batteryLastInstantVbat = Number($("battery-v")?.value || state.batteryV);
        state.chargeV = Number($("charge-v")?.value || state.chargeV);
        state.charging = Number(state.chargeV || 0) > 4.0;
        state.batteryLowVoltageUnpowered =
          !state.charging &&
          Number(state.batteryLastInstantVbat || 0) <
            Number(state.batteryUnpoweredLowThreshold || 5.0);
        state.batteryPowered = state.charging || !state.batteryLowVoltageUnpowered;
        state.batteryV = state.batteryPowered ? state.batteryLastInstantVbat : 0;
        state.batteryPercent = null;
        state.batteryStateText = state.batteryPowered ? "电池" : "未上电";
        const icon = batteryIconForPercent(state.batteryPowered, state.batteryPercent);
        state.batteryIconClass = icon.cls;
        state.batteryIconColor = icon.color;
        renderState();
        showDebugActionResult("debug-power-result", { ok: true, msg: "已应用浏览器本地 ADC 模拟" });
      },
    ],

    // --- 4. Network/Access Point ---
    [
      "debug-ap-pass-toggle",
      () => {
        debugApPasswordShown = !debugApPasswordShown;
        renderDebugNetworkPanel();
      },
    ],
    ["debug-network-refresh", () => syncRuntimeStateFromFirmware("debug_network_refresh")],

    // --- 5. Pause scrolling (same group as button simulator) ---
    [
      "firmware-pause",
      () => runDebugSimCommand($("firmware-pause"), "暂停滚动", sendAuxCommand("pause_scroll", {}, "debug_firmware_pause")),
    ],

    // --- 6. LED Test: Preview Only ---
    [
      "debug-preview-off",
      () => {
        applyDebugFrame(blankFrame(), "debug pattern", { reason: "debug_preview_off" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "预览：全黑（未发送）" });
      },
    ],
    [
      "debug-preview-checker",
      () => {
        applyDebugFrame(makePatternFrame("checker"), "debug pattern", { reason: "debug_preview_checker" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "预览：棋盘（未发送）" });
      },
    ],
    [
      "debug-preview-border",
      () => {
        applyDebugFrame(makePatternFrame("border"), "debug pattern", { reason: "debug_preview_border" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "预览：边框（未发送）" });
      },
    ],
    [
      "debug-preview-saved",
      () => {
        applyDebugFrame(getSavedFaceFrame(state.faceIndex), "saved face", { reason: "debug_preview_saved" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "预览：当前保存表情（未发送）" });
      },
    ],

    // --- 6. LED test: send to firmware ---
    [
      "debug-send-off",
      () => {
        if (debugSendBlockedOffline("debug-lab-result")) return;
        applyDebugFrame(blankFrame(), "firmware", { send: true, reason: "debug_send_off" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "全黑：已发送固件帧" });
      },
    ],
    [
      "debug-send-on",
      () => {
        if (debugSendBlockedOffline("debug-lab-result")) return;
        const allOn = blankFrame().map(() => true);
        const watts = estimateFrameWatts(allOn, state.color, state.brightness);
        const warnEl = $("debug-allon-warning");
        if (watts >= LED_POWER_WARNING_WATTS) {
          if (warnEl) warnEl.classList.add("show");
          if (!confirm(`全亮帧功耗估算约 ${watts.toFixed(1)}W，超过 ${LED_POWER_WARNING_WATTS}W 警戒线。确认发送？`)) {
            showDebugActionResult("debug-lab-result", { ok: false, msg: "已取消全亮发送" });
            return;
          }
        } else if (warnEl) {
          warnEl.classList.remove("show");
        }
        applyDebugFrame(allOn, "firmware", { send: true, reason: "debug_send_all_on" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: `全亮：已发送固件帧（约 ${watts.toFixed(1)}W）` });
      },
    ],
    [
      "debug-send-checker",
      () => {
        if (debugSendBlockedOffline("debug-lab-result")) return;
        applyDebugFrame(makePatternFrame("checker"), "firmware", { send: true, reason: "debug_send_checker" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "棋盘：已发送固件帧" });
      },
    ],
    [
      "debug-send-border",
      () => {
        if (debugSendBlockedOffline("debug-lab-result")) return;
        applyDebugFrame(makePatternFrame("border"), "firmware", { send: true, reason: "debug_send_border" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "边框：已发送固件帧" });
      },
    ],
    [
      "debug-send-saved",
      () => {
        if (debugSendBlockedOffline("debug-lab-result")) return;
        applyDebugFrame(getSavedFaceFrame(state.faceIndex), "firmware", { send: true, reason: "debug_send_saved" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "当前保存表情：已发送固件帧" });
      },
    ],

    // --- 6. packed frame input ---
    [
      "debug-frame-preview",
      () => {
        const res = parsePackedFrameOrError($("debug-frame")?.value || "");
        refreshDebugFrameValidation();
        if (res.error) {
          showDebugActionResult("debug-lab-result", { ok: false, msg: `packed frame 无效：${res.error}（未发送）` });
          return;
        }
        applyDebugFrame(res.frame, "packed frame input", { reason: "debug_frame_preview" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "packed frame：已解析为预览（未发送）" });
      },
    ],
    [
      "debug-frame-send",
      () => {
        const res = parsePackedFrameOrError($("debug-frame")?.value || "");
        refreshDebugFrameValidation();
        if (res.error) {
          showDebugActionResult("debug-lab-result", { ok: false, msg: `packed frame 无效：${res.error}（已阻止发送）` });
          return;
        }
        if (debugSendBlockedOffline("debug-lab-result")) return;
        applyDebugFrame(res.frame, "firmware", { send: true, reason: "debug_frame_send" });
        showDebugActionResult("debug-lab-result", { ok: true, msg: "packed frame：已发送固件帧" });
      },
    ],
    [
      "debug-frame-clear",
      () => {
        const ta = $("debug-frame");
        if (ta) ta.value = "";
        refreshDebugFrameValidation();
        showDebugActionResult("debug-lab-result", null);
      },
    ],
    [
      "debug-frame-copy",
      () => {
        copyText(packedFrameToHex(debugPreviewFrame));
        showDebugActionResult("debug-lab-result", { ok: true, msg: "已复制调试预览 packed frame" });
      },
    ],

    // --- 7. Preview panel copy ---
    ["debug-preview-copy", () => copyText(packedFrameToHex(debugPreviewFrame))],

    // --- 9. Communication log ---
    [
      "log-clear",
      () => {
        logs = [];
        renderLog();
      },
    ],
    ["log-download", () => downloadJsonFile("rina_webui_log.txt", logs.join("\n"))],
    ["log-copy", () => copyText(logs.join("\n"))],

    // --- 10. Advanced primitive instructions ---
    ["debug-raw-validate", () => refreshDebugRawValidation()],
    [
      "debug-raw-send",
      () => {
        const raw = $("debug-raw-json")?.value || "";
        if (!$("debug-raw-confirm")?.checked) {
          showDebugActionResult("debug-raw-result", { ok: false, msg: "请先勾选确认框" });
          return;
        }
        let packet;
        try {
          packet = JSON.parse(raw);
        } catch (err) {
          showDebugActionResult("debug-raw-result", { ok: false, msg: `JSON 格式错误：${err.message}` });
          return;
        }
        if (!packet || typeof packet !== "object" || typeof packet.cmd !== "string") {
          showDebugActionResult("debug-raw-result", { ok: false, msg: "JSON 必须是对象且包含字符串 cmd 字段" });
          return;
        }
        if (isOfflineHtmlMode() || !firmware.online) {
          showDebugActionResult("debug-raw-result", { ok: false, msg: "固件离线，无法发送" });
          return;
        }
        showDebugActionResult("debug-raw-result", { pending: true, msg: "发送中…" });
        firmware.sentCommands++;
        setFirmwareStatus({
          lastRequest: `POST ${API_ENDPOINTS.command}`,
          lastStatus: "queued raw command",
        });
        apiPost(API_ENDPOINTS.command, packet)
          .then((data) => {
            applyFirmwareRuntimeState(data, "debug_raw_command");
            showDebugActionResult("debug-raw-result", { ok: true, msg: "原始指令已发送" });
          })
          .catch((err) => {
            setFirmwareStatus({ lastStatus: "raw command failed", lastError: err.message });
            log(`raw command failed: ${err.message}`);
            showDebugActionResult("debug-raw-result", { ok: false, msg: `失败：${err.message}` });
          });
      },
    ],

    // --- 11. Danger Zone ---
    [
      "debug-clear-user-faces",
      () => {
        const ok = confirmDangerAction({
          title: "清空用户表情",
          body: "此操作会永久清空所有用户保存的表情；默认 type:default 表情不受影响。",
          confirmWord: "CLEAR",
        });
        if (!ok) {
          showDebugActionResult("debug-danger-result", { ok: false, msg: "已取消（未做任何改动）" });
          return;
        }
        userFaces = [];
        persistFaceDocuments("debug_reset_user_faces");
        renderSavedFaces();
        renderState();
        showDebugActionResult("debug-danger-result", { ok: true, msg: "已清空用户表情；默认表情保留" });
      },
    ],
  ]);

  // Input/check monitoring (not click).
  $("debug-frame")?.addEventListener("input", refreshDebugFrameValidation);
  $("debug-raw-json")?.addEventListener("input", refreshDebugRawValidation);
  $("debug-raw-confirm")?.addEventListener("change", refreshDebugRawValidation);
  refreshDebugRawValidation();

  // Communication log level selection: Turning down the level can significantly reduce the rendering overhead of high-frequency/redundant entries.
  const logLevelSelect = $("log-level-select");
  if (logLevelSelect) {
    logLevelSelect.addEventListener("change", () => setLogLevel(logLevelSelect.value));
  }

  // GPIO/button emulator: with busy disable + result feedback.
  document.querySelectorAll("[data-gpio]").forEach((button) => {
    button.addEventListener("click", () => {
      const code = String(button.dataset.gpio || "").toUpperCase();
      const label = (button.textContent || code).trim();
      if (["B1", "B2", "B3", "B4", "B5", "B3B1", "B3B2"].includes(code)) {
        runDebugSimCommand(button, label, sendButtonCommand(code, `debug_gpio_${code}`));
        return;
      }
      if (code === "B6S" || code === "B6L") {
        runDebugSimCommand(
          button,
          label,
          sendAuxCommand("battery_overlay", { singleShot: code === "B6S" }, `debug_gpio_${code}`),
        );
        return;
      }
      if (code === "B6B3") {
        runDebugSimCommand(button, label, {
          promise: syncRuntimeStateFromFirmware("debug_gpio_B6B3_network_info"),
        });
        return;
      }
      showDebugActionResult("debug-sim-result", { ok: false, msg: `不支持的模拟 GPIO：${code}` });
    });
  });
}

let deferredUiInitialized = false;
let basicPreviewMatrixInitialized = false;
let firstPageRevealPrepared = false;
let firstPageRevealStarted = false;
function initializeBasicPreviewMatrix() {
  if (basicPreviewMatrixInitialized) return;
  basicPreviewMatrixInitialized = true;
  if (!matrixViews.some((view) => view.el?.id === "matrix-basic")) {
    initMatrix("matrix-basic", () => currentFrame, false, null, false);
  }
}

function firstPageRevealItems() {
  return Array.from(document.querySelectorAll(FIRST_PAGE_REVEAL_SELECTOR))
    .filter((el) => el && !el.hidden)
    .sort((a, b) => {
      const ar = a.getBoundingClientRect(),
        br = b.getBoundingClientRect();
      const dy = ar.top - br.top;
      if (Math.abs(dy) > 1) return dy;
      return ar.left - br.left;
    });
}

function prepareFirstPageProgressiveReveal() {
  if (firstPageRevealPrepared) return;
  firstPageRevealPrepared = true;
  document.documentElement.dataset.firstPageReveal = "preparing";
  firstPageRevealItems().forEach((el) => {
    el.classList.add("boot-reveal-item");
    el.classList.remove("is-revealed");
  });
}

function settleFirstPageProgressiveReveal() {
  document.querySelectorAll(".boot-reveal-item").forEach((el) => {
    el.classList.remove("boot-reveal-item", "is-revealed");
  });
}

async function revealFirstPageWaterfall() {
  if (firstPageRevealStarted) return;
  firstPageRevealStarted = true;
  prepareFirstPageProgressiveReveal();
  // 等 LED 预览背景图加载完成后再开始卡片瀑布（图片在加载动画开始后即已发起预加载）。
  // preloadRinaboardImage() 在加载失败/超时时也会 resolve，所以这里不会永久阻塞。
  await preloadRinaboardImage();
  await new Promise((resolve) => requestAnimationFrame(resolve));
  delete document.documentElement.dataset.firstPageReveal;
  await new Promise((resolve) => requestAnimationFrame(resolve));
  for (const el of firstPageRevealItems()) {
    el.classList.add("is-revealed");
    await new Promise((resolve) => setTimeout(resolve, 115));
  }
  await new Promise((resolve) => setTimeout(resolve, 260));
  settleFirstPageProgressiveReveal();
}

function initFirstPageUiBeforeShow() {
  initButtonPressAnimations();
  observeWebUiFont();
  initNav();
  initColors();
  initBrightness();
  initBasicControls();
  initCustomSelectDropdowns();
  initFaceLibraryAutoRefresh();
}

function renderFirstPageUiBeforeShow() {
  applyBrightnessLocal(state.brightness);
  setColor(state.color, "firmware_sync");
  syncAutoIntervalUi();
  setFirmwareStatus({
    savedFacesSync: "waiting for firmware runtime read",
  });
  renderState();
}

function initDeferredUiAfterShow() {
  if (deferredUiInitialized) return;
  deferredUiInitialized = true;
  initializeMatrixViews();
  basicPreviewMatrixInitialized = true;
  observeMatrixWraps();
  initCustom();
  initParts();
  initScroll();
  initializeDebugControls();
  renderSavedFaces();
  renderMatrices();
  renderState();
  fitAllMatrices();
}

function makePatternFrame(kind) {
  const frame = blankFrame();
  for (let y = 0; y < ROWS; y++) {
    const [x0, x1] = ROW_RANGES[y];
    for (let x = x0; x <= x1; x++) {
      const idx = XY_TO_INDEX[y][x];
      if (idx < 0) continue;
      if (kind === "checker") frame[idx] = ((x + y) & 1) === 0;
      else if (kind === "border") frame[idx] = y === 0 || y === ROWS - 1 || x === x0 || x === x1;
    }
  }
  return frame;
}

let postBootDeferredReadStarted = false;
async function runPostBootDeferredReads(bootOk = false) {
  if (postBootDeferredReadStarted) return;
  postBootDeferredReadStarted = true;
  await new Promise((resolve) => requestAnimationFrame(resolve));
  await new Promise((resolve) => setTimeout(resolve, 0));

  const bootPlaybackIsScroll =
    state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback);
  try {
    setFirmwareStatus({
      savedFacesSync: "loading after WebUI ready",
    });
    log("WebUI 已显示：开始异步读取 saved_faces.json 与 LED 预览矩阵。");
    await loadFaceLibrary();
  } catch (err) {
    setFirmwareStatus({
      savedFacesSync: "deferred load failed",
    });
    if (shouldLogApiError()) log(`延后读取 saved_faces.json 失败：${err.message}`, "error");
  }

  const matrixSynced = bootPlaybackIsScroll
    ? await syncRuntimeSummaryFromFirmware("post_load_scroll_summary")
    : await syncRuntimeStateFromFirmware("post_load_matrix_preview");
  if (!matrixSynced && getAllFaces().length && !bootPlaybackIsScroll) {
    if (bootOk) applyKnownFaceIndexLocal("post_load_face_index_fallback");
    else applyStartupDefaultFaceLocal("post_load_default_face_fallback");
  }
  renderSavedFaces();
  renderMatrices();
  renderState();
  scheduleMatrixFitRender(3);

  // After the key startup read (runtime state + saved_faces + preview) completes and the loading animation is still on screen,
  // Warm text scrolling browser fonts in the background (ark12.woff2, ~830KB, emoji and fallback glyphs incorporated). This text scrolls the page
  // You'll have the fonts ahead of time, so users won't have to wait a few seconds to replace them after opening them.
  // It starts after critical reads to avoid competing with the single-threaded ESP web server on those reads.
  // The larger 2.5MB ark12.json bitmap glyph table remains lazy loaded and is loaded when first entering a text scrolling page; see switchPage.
  ensureTextScrollBrowserFontReady().catch(() => {});
}

// Application launch
// Connection relationship:
// - bootstrapWebUi() is the only startup entry: fonts and basic UI first, then first screen display, and then firmware synchronization.
// - It calls the init/render functions of all previous modules, but the module itself should not call bootstrap in reverse.
// - If the startup fails, the log and status will be written, without blocking the user from viewing the local UI.
async function bootstrapWebUi() {
  const bootStart = performance.now();
  let bootOk = false;
  try {
    if (window.rinaStartLoaderAnimation) await window.rinaStartLoaderAnimation();
    // 加载动画已开始播放：现在才请求 LED 预览背景大图，让它与字体/UI 初始化并行下载。
    // 卡片瀑布揭示（revealFirstPageWaterfall）会等这张图就绪后再开始。
    preloadRinaboardImage();
    prepareFirstPageProgressiveReveal();
    // UI fonts (GNU Unifont, embedded data URI) must be in stage 4
    // Completely ready before the waterfall is revealed, so that the correct font is displayed when the fold is revealed.
    // It's inline (no network requests), so this await is fast. ark12 scroll font preservation
    // Defer and load via initScroll after stage 4.
    await ensureWebUiFontReady().catch((err) => console.warn("WebUI font bootstrap failed", err));
    initFirstPageUiBeforeShow();
    initializeBasicPreviewMatrix();
    renderFirstPageUiBeforeShow();
    showBootUiBehindLoader();
    await new Promise((resolve) => requestAnimationFrame(resolve));
    const firstPageRevealPromise = revealFirstPageWaterfall();

    // Work on stage 4 first: Wait for the above-the-fold waterfall reveal to complete.
    await firstPageRevealPromise;

    await waitForBootLoaderMinimum(bootStart);
    await new Promise((resolve) => requestAnimationFrame(resolve));

    finishBootVisibility();
    scheduleMatrixFitRender(4);
    initDeferredUiAfterShow();

    // Loader is now fully gone. Only now perform the first firmware sync so network/JSON
    // work cannot compete with the loading animation render pipeline. Use lightweight
    // status + scroll text/FPS sync; do not rebuild scroll preview frames here.
    await preloadFirmwareRuntimeState();
    bootOk = !!bootRuntimeSnapshot.ok;
    applyBrightnessLocal(state.brightness);
    syncAutoIntervalUi();
    // Before the loader hides: if the firmware is NOT scrolling, pull and render the live
    // static frame so the preview shows the real current LED frame (not a local default).
    // If it IS scrolling, skip the static frame entirely and go straight to the scroll
    // preview restore below.
    const firmwareScrollingAtBoot = !!(
      state.textScrollActive ||
      scroll.firmwareBacked ||
      isScrollPlaybackValue(state.playback)
    );
    if (bootOk && !firmwareScrollingAtBoot) {
      await loadStaticFramePreviewFromFirmware("boot_static_frame");
    }
    updatePackedFrameViews();
    updateScrollUi();
    renderSavedFaces();
    renderMatrices();
    renderState();
    fitAllMatrices();
    await kickPostBootScrollMetaRestore("post_loader_runtime_ready");

    startFirmwareStatusPolling();
    startPowerStatusPolling();
    runPostBootDeferredReads(bootOk).catch((err) => {
      if (shouldLogApiError()) log(`延后读取 saved_faces/预览矩阵失败：${err.message}`, "error");
    });
    log(
      bootOk
        ? "WebUI 启动：先初始化 UI，再读取 runtime-only 固件运行状态；读取完成后触发加载动画结束。saved_faces 与 LED 预览矩阵会在页面显示后异步读取。"
        : "WebUI 启动：先初始化 UI；固件状态读取失败/离线后使用本地默认页面结束加载动画。saved_faces 与预览矩阵会在页面显示后尝试读取。",
    );
  } catch (err) {
    console.error("WebUI bootstrap failed", err);
    const msg = `WebUI 初始化失败：${err.message || err}`;
    try {
      log(msg);
    } catch (_) {
      console.error(msg);
    }
    const logEl = $("log");
    if (logEl) logEl.textContent = msg;
    showBootUiBehindLoader();
    await revealFirstPageWaterfall().catch(() => {});
    await waitForBootLoaderMinimum(bootStart);
    await new Promise((resolve) => requestAnimationFrame(resolve));
    finishBootVisibility();
    scheduleMatrixFitRender(4);
    initDeferredUiAfterShow();
    startFirmwareStatusPolling();
    startPowerStatusPolling();
    runPostBootDeferredReads(bootOk).catch((err) => {
      if (shouldLogApiError()) log(`引导读取 saved_faces/预览矩阵失败：${err.message || err}`, "error");
    });
  }
}

// The only startup entry: the script is at the end of <body>, and the DOM is usually ready; still do a readyState protection.
// (boot: static-frame preview before loader hides when idle; full scroll-preview restore when scrolling)
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootstrapWebUi);
} else {
  bootstrapWebUi();
}
