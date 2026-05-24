"use strict";

/*
 * RinaChanBoard WebUI runtime.
 *
 * This file is intentionally organized as one browser runtime because the ESP32
 * serves it as a static asset and the page does not use a bundler. The blocks
 * below are ordered by dependency:
 *
 * 1. WEBUI_CONFIG: all tunable constants that should be changed before touching
 *    runtime logic. Later constants are aliases of these values.
 * 2. EXPRESSION_PARTS and color presets: static data used by previews, saved
 *    faces, part composition, and firmware payload generation.
 * 3. Runtime aliases, matrix geometry, and global state: bridges static data
 *    into fast lookup tables and mutable UI/firmware state.
 * 4. Shared utilities, API clients, and queues: common plumbing used by every
 *    feature page before any page-specific controls are initialized.
 * 5. Feature modules: boot loader, navigation, matrix editing, color/brightness,
 *    saved faces, part composition, text scrolling, debug controls.
 * 6. bootstrapWebUi(): wires all previous blocks together, performs the first
 *    firmware sync, then reveals the UI.
 *
 * index.html owns markup and element ids, styles.css owns layout and visual
 * states, and this file owns behavior. If an id/class is referenced here, it is
 * expected to exist in index.html and be styled in styles.css.
 */
const WEBUI_CONFIG = Object.freeze({
  // Saved-face persistence. The UI loads this JSON from LittleFS, edits it in
  // memory, and can write it back through the firmware API or local file tools.
  faces: {
    resourcePath: "/resources/saved_faces.json",
    localFilename: "saved_faces.json",
    schemaFormat: "rina_faces_370_v2",
    startupFaceId: "face_07_triangle_eyes_frown",
  },
  // Device connection defaults shown in debug/status UI and used when the page
  // is opened directly instead of through the ESP32 captive portal.
  device: {
    apSsid: "RinaChanBoard-V2",
    apPassword: "rinachan",
    apDomain: "rina.io",
    defaultApIp: "192.168.1.14",
  },
  // Navigation metadata. Each tuple maps a logical page id to the visible
  // chapter number and label; initNav() turns this into top menu buttons.
  navigation: {
    pages: [
      ["basic", "6.1", "基础功能"],
      ["custom", "6.2", "自定义表情"],
      ["parts", "6.3", "表情部件"],
      ["scroll", "6.4", "文字滚动"],
      ["debug", "6.5", "调试"],
    ],
  },
  // LED hardware limits and preview sizing. Renderer, brightness controls, and
  // power estimates all derive from this block.
  led: {
    defaultColor: "#f971d4",
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
      maxCell: 48,
      minWidth: 320,
      maxHeight: 500,
      edgeGap: 12,
    },
  },
  // Automatic face-rotation timing. UI presets and firmware command payloads
  // both use these limits to keep browser and device behavior aligned.
  autoInterval: {
    minMs: 500,
    maxMs: 10000,
    buttonStepMs: 500,
    presetsMs: [500, 1000, 2000, 3000, 5000, 7500, 10000],
  },
  // HTTP endpoints and timeouts. API helpers below add the host/origin and
  // translate failures into logs/status fields.
  api: {
    getTimeoutMs: 2500,
    postTimeoutMs: 5000,
    uploadTimeoutMs: 15000,
    bootStatusTimeoutMs: 2500,
    runtimeStatusQuery: "?runtimeOnly=1&noFrame=1",
    endpoints: {
      frame: "/api/frame",
      command: "/api/command",
      scroll: "/api/scroll",
      savedFaces: "/api/saved_faces",
      power: "/api/power",
      status: "/api/status",
    },
  },
  // Shared responsive breakpoints. CSS owns the visual rules; JS uses these
  // values only when script-side layout decisions are necessary.
  layout: {
    oneColumnMaxPx: 980,
    threeColumnsMinPx: 1471,
  },
  // Queue timing for firmware writes. These numbers protect the single-threaded
  // ESP32 web server from rapid browser events such as dragging sliders.
  firmwareQueues: {
    m370SendIntervalMs: 45,
    m370QueueMax: 3,
    buttonCommandIntervalMs: 120,
    buttonCommandQueueMax: 4,
    scrollButtonStopFullSyncDelayMs: 140,
  },
  // Text-scroll runtime limits. The preview, upload chunking, and firmware
  // scroll playback all read from this block.
  scroll: {
    defaultFps: 10,
    fpsMin: 1,
    fpsMax: 60,
    fpsPresets: [1, 10, 20, 30, 40, 50, 60],
    firmwareMaxFramesDefault: 3072,
    uploadChunkFrames: 24,
    maxTextChars: 1000,
  },
  // Browser and firmware bitmap font settings for page 6.4. The JSON table is
  // loaded lazily because it is large; the CSS font face is declared in styles.css.
  textScroll: {
    fontModel: "ark_pixel_12px_fusion_bitmap_v2",
    fontResource: "/resources/fonts/ark12.json",
    fontFamily: "Ark Pixel 12px Monospaced",
    fontFallbackFamily: "",
    browserFontSample:
      "RinaChanBoard 370 LED \u7ee7\u7eed \u6682\u505c \u3053\u3093\u306b\u3061\u306f \u7483\u5948\u3061\u3083\u3093\u30dc\u30fc\u30c9 \u7136\u71c3\u6eda\u6efe",
    browserFallbackFontSample: "",
    charSpacing: 0,
    spaceColumns: 6,
    missingGlyphCodePoint: 0x25a1,
  },
  // UI font family expected by the loader. The actual embedded data URI lives in
  // styles.css and is waited on before the first-page reveal.
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
  // Boot loader choreography. bootstrapWebUi() consumes these values to sync
  // firmware state while the loading overlay is still visible.
  boot: {
    loadingIconBefore: "./resources/loading/rina_icon1_default.png",
    loadingIconAfter: "./resources/loading/rina_icon2_hover.png",
    holdMs: 150,
    haloBreathMs: 1620,
    haloPeakRatio: 0.5,
    haloToleranceMs: 24,
    haloContractMs: 300,
    imageReleaseMs: 1300,
    blurDurationMs: 500,
    extraMs: 120,
    minDisplayMs: 400,
    firstPageRevealSelector: [
      ".sidebar",
      "#page-basic .hero",
      "#page-basic .basic-preview-card",
      "#page-basic .control-panel > .card.control-section",
    ],
  },
  // Power panel refresh cadence. The poller uses this interval after the first
  // status snapshot has been applied.
  power: {
    statusRefreshMs: 900,
  },
});
// -----------------------------------------------------------------------------
// 数据：表情/部件库
// -----------------------------------------------------------------------------
// 连接关系：
// - initParts() 用 call.ids 和 parts 生成 6.3 的部件按钮。
// - composePartsFrame() 把选中的部件叠加成 partsFrame。
// - frameToM370()/queueFirmwareFrame() 把最终 370 LED frame 发给固件。
// - saved-face 逻辑会把这些静态表情和用户保存表情合并成一个库。
// 这个块只放静态数据，不读写 DOM，也不直接发 API。
// 内嵌 LED 表情/部件库，供预览和固件载荷使用。
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
    m370: "93 hex chars; 370 logical cells scanned row-major by row_lengths and padded to 372 bits",
    strip_indices:
      "physical serpentine LED indices mapped back to logical M370 cells when used as fallback",
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
      "Resolve call IDs through call.map, OR selected parts by m370 or strip_indices, then apply selected color and global brightness.",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000300000C0000300000C0000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000080000300000C0000300000C0000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000100000A000044000000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000001800009000042000000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000200002800011000082000000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000C00001800001000018000180000000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000060000060000040001E0000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000000000007E000000000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000000000007E000280000400000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000000000000400000F0000000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000000000000440000E0000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000004200009000018000000000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000001800001E000000000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000001C00000C000000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000000000018000010000030000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000000C00003C000060000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000010000100001C0000300000C0000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000080000200000E0000300000C0000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000300001A0000780000C0000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000300001A0000780002C0000400000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000300001C0000780000C0000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000700004400002000010000000000100000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000880002800004000028000110000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000020000380001F000038000040000000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000007000044000110000440000E0000000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000200005000044000208000440000A0000100000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000D800092000208000440000A0000100000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000300000C0000300000C0000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000010000300000C0000300000C0000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000000002000014000088000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000000006000024000108000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000400005000022000104000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000300006000020000060000060000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000018000180000800001E0000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000000000000001F8000000000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000000000000001F8000050000080000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000000000000000080003C0000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000000000000000880001C0000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000000010800024000060000000000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000000000060001E0000000000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000000000E0000C0000000000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000000000000006000020000300000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000000000C0000F0000180000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000080000200000E0000300000C0000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000010000100001C0000300000C0000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000030000160000780000C0000000000000000000000000000000000000000000000000000",
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
      m370: "0000000000000000000000030000160000780000D0000080000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000300000E0000780000C0000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000400002000008000020000000000200000000000000000000000000000000000000000000000",
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
      m370: "000000000000000001100005000008000050000220000000000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000040000700003E000070000080000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000000000E000088000220000880001C0000000000000000000000000000000000000000000000000000",
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
      m370: "000000000000040000A00008800041000088000140000200000000000000000000000000000000000000000000000",
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
      m370: "000000000000000001B00012400041000088000140000200000000000000000000000000000000000000000000000",
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
      m370: "00000000000000000000000000000000000000000000000000000000000000000000001F800000000000000000000",
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
      m370: "00000000000000000000000000000000000000000000000000000000000000000408001F800000000000000000000",
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
      m370: "00000000000000000000000000000000000000000000000000000000000000000000001F800204000000000000000",
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
      m370: "0000000000000000000000000000000000000000000000000000000000000000040800108000F0000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000001020002100009000060000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000002100009000060000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000300001200010800204000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000000C00009000108000000000000000",
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
      m370: "0000000000000000000000000000000000000000000000000000000000000400042800118000F0000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000001FE0004080010800090000600000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000001FE0004080020400108000F00000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000780002100010800090000600000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000FC0002100009000060000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000780002100020400204003FC0000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000780002100010800204001F80000000000",
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
      m370: "00000000000000000000000000000000000000000000000000000000000030000120001080010800090000C000000",
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
      m370: "0000000000000000000000000000000000000000000000000000000C0000480001200009000090000600000000000",
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
      m370: "000000000000000000000000000000000000000000000000030000120000480001200009000090000600000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000300001200009000060000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000007F800204003FC000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000007F800204001F8000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000003F000204003FC000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000003F000108000F0000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000001E000108001F8000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000003F000108001F8000000000000000",
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
      m370: "00000000000000000000000000000000000000000000000000000000000102000210001F800108002040000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000CC0004C80020400264001980000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000003300026400000000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000001200016800000000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000000002100016800090000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000000000000840002D00009000000000000000000000",
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
      m370: "0000000000000000000000000000000000000000000000000000000000000000001000148000B0000000000000000",
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
      m370: "000000000000000000000000000000000000000000000000000006001800000000000000000000000000000000000",
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
      m370: "00000000000000000000000000000000000000000000000000000A001400000000000000000000000000000000000",
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
      m370: "000000000000000000000000000000000000000000000002800505002800000000000000000000000000000000000",
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
      m370: "000000000000000000000000000000000000000000000001400A0A001400000000000000000000000000000000000",
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
      m370: "00000000000000000000000000000000000000000000000000000E001C000000E001C000000000000000000000000",
      strip_indices: [212, 213, 214, 227, 228, 229, 256, 257, 258, 271, 272, 273],
      lit_count: 12,
      bbox: [2, 10, 19, 12],
    },
  },
};

// -----------------------------------------------------------------------------
// 配置别名和导航元数据
// -----------------------------------------------------------------------------
// 连接关系：
// - WEBUI_CONFIG 是可编辑入口；这里建立短名称，避免后续逻辑散落深层访问。
// - PAGES 同时驱动导航按钮和 switchPage() 的目标 page id。
// - API_ENDPOINTS 被 apiGet()/apiPost()/upload helpers 统一使用。
// - MATRIX_VIEW_CONFIGS 把 index.html 中的矩阵 id 连接到对应 frame provider。
// 所有可调数值优先在 WEBUI_CONFIG 中修改；这里仅建立运行时别名。
const PAGES = WEBUI_CONFIG.navigation.pages;
const MATRIX = EXPRESSION_PARTS.matrix;
const ROW_RANGES = MATRIX.row_valid_x_ranges;
const TOTAL_LEDS = MATRIX.num_leds;
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
  ["matrix-debug", () => currentFrame, false, null, false],
];
const DEFAULT_SCROLL_FPS = WEBUI_CONFIG.scroll.defaultFps;
const SCROLL_FPS_MIN = WEBUI_CONFIG.scroll.fpsMin;
const SCROLL_FPS_MAX = WEBUI_CONFIG.scroll.fpsMax;
const SCROLL_FPS_PRESETS = WEBUI_CONFIG.scroll.fpsPresets;
const FIRMWARE_SCROLL_MAX_FRAMES_DEFAULT = WEBUI_CONFIG.scroll.firmwareMaxFramesDefault;
let firmwareScrollMaxFrames = FIRMWARE_SCROLL_MAX_FRAMES_DEFAULT;
const SCROLL_UPLOAD_CHUNK_FRAMES = WEBUI_CONFIG.scroll.uploadChunkFrames;
const RUNTIME_STATUS_QUERY = WEBUI_CONFIG.api.runtimeStatusQuery;
const SCROLL_BUTTON_STOP_FULL_SYNC_DELAY_MS =
  WEBUI_CONFIG.firmwareQueues.scrollButtonStopFullSyncDelayMs;
const WEBUI_M370_SEND_INTERVAL_MS = WEBUI_CONFIG.firmwareQueues.m370SendIntervalMs;
const WEBUI_M370_QUEUE_MAX = WEBUI_CONFIG.firmwareQueues.m370QueueMax;
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
const TEXT_SCROLL_MISSING_GLYPH_CP = WEBUI_CONFIG.textScroll.missingGlyphCodePoint; // 不使用系统字体回退。
const BOOT_STATUS_ENDPOINT = `${API_ENDPOINTS.status}${RUNTIME_STATUS_QUERY}`;
const BOOT_STATUS_TIMEOUT_MS = WEBUI_CONFIG.api.bootStatusTimeoutMs;
const BOOT_MIN_DISPLAY_MS = WEBUI_CONFIG.boot.minDisplayMs;
const FIRST_PAGE_REVEAL_SELECTOR = WEBUI_CONFIG.boot.firstPageRevealSelector.join(",");

// -----------------------------------------------------------------------------
// 数据：颜色预设库
// -----------------------------------------------------------------------------
// 连接关系：
// - initColorInput() 用 parent_color_groups 填充主色下拉框。
// - child_color_groups 根据主色选择填充子色下拉框。
// - setColor() 最终把选中颜色同步到预览、按钮状态和固件 frame payload。
const parent_color_groups = [
  {
    id: 0,
    name: "默认璃奈粉色",
    color: "f971d4",
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

// -----------------------------------------------------------------------------
// 矩阵几何以及物理/逻辑 LED 映射
// -----------------------------------------------------------------------------
// 连接关系：
// - ROW_RANGES 描述每行有效 LED 范围，用于预览格子和文字滚动裁切。
// - XY_TO_INDEX/INDEX_TO_XY 是 UI 坐标和逻辑 370 点索引之间的双向表。
// - PHYSICAL_TO_LOGICAL_INDEX 处理蛇形接线，把固件/灯条物理顺序映射回 UI。
// - 所有 frame 都保持逻辑顺序；只有与固件/物理灯条交互时才转换。
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

// -----------------------------------------------------------------------------
// 运行时状态
// -----------------------------------------------------------------------------
// 连接关系：
// - state 是 UI 和固件的共享快照；renderState() 只读它来更新控件。
// - currentFrame/editFrame/partsFrame/scrollFrame 是不同页面的工作缓冲区。
// - firmware/queue 变量记录 API 发送、轮询和错误状态，避免重复请求淹没 ESP32。
// - scroll 对象只保存 6.4 文字滚动的 timeline、播放和上传状态。
// WebUI 控件和固件之间同步的运行时状态。
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
};
let currentFrame = blankFrame();
let editFrame = blankFrame();
let partsFrame = blankFrame();
let scrollFrame = blankFrame();
let selectedCall = {
  leye: "101",
  reye: "201",
  mouth: "301",
  cheek: "400",
};
let partsSymmetry = false;
let liveSendEnabled = false;
let defaultFaces = [];
let userFaces = [];
let faceLibraryDocument = null;
let faceLibraryFileHandle = null;
let pointerFaceDrag = null;
let logs = [];
let frameSendInFlight = false;
let pendingFramePacket = null;
let frameSendQueue = [];
let frameSendTimer = 0;
let lastFrameSendAt = 0;
let buttonCommandQueue = [];
let buttonCommandInFlight = false;
let buttonCommandTimer = 0;
let lastButtonCommandAt = 0;
let lastApiErrorLogAt = 0;
let brightnessChangedByUser = false;
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
  uploadProgress: 0,
  uploadLabel: "",
  offset: 0,
  frameIndex: 0,
  frames: [],
  signature: "",
  dirty: true,
  dirtyNoticeLogged: false,
  frameCounter: 0,
  fpsStarted: performance.now(),
  measuredFps: 0,
};

// -----------------------------------------------------------------------------
// 共享辅助函数和 DOM 绑定
// -----------------------------------------------------------------------------
// 连接关系：
// - 这一组是后续所有模块的底层工具，不能依赖任何页面初始化结果。
// - bindControls()/setClickHandlers() 让重复初始化保持幂等，避免事件重复绑定。
// - safeJsonParse()/parseApiJson() 是 API 层和本地资源读取的 JSON 防线。
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
// -----------------------------------------------------------------------------
// 按钮按压反馈
// -----------------------------------------------------------------------------
// 连接关系：
// - 使用事件委托监听所有 button，不需要每个模块单独处理按压动画。
// - 只改变 CSS class 和短计时器，不改变业务状态。
// - styles.css 中的按钮 active/pressed 样式负责最终视觉效果。
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
// -----------------------------------------------------------------------------
// 字体加载
// -----------------------------------------------------------------------------
// 连接关系：
// - ensureWebUiFontReady() 等待 styles.css 中的 GNU Unifont 内嵌字体。
// - bootstrapWebUi() 在首屏瀑布揭示前等待它，避免文字先用 fallback 闪烁。
// - observeWebUiFont() 在字体状态变化后重新给动态生成节点补字体 class。
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
  // GNU Unifont 影响 textarea 字符的实际宽高，加载完成后必须重新测量，
  // 否则会保留用备用字体或字体未加载时算出的旧高度（最糟糕的情况
  // 是页面当时是 display:none，scrollHeight=0，导致 height:0px 装不下文字）。
  if (typeof autoResizeM370Textareas === "function") autoResizeM370Textareas();
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
// -----------------------------------------------------------------------------
// 文字滚动字体模型
// -----------------------------------------------------------------------------
// 连接关系：
// - CSS 的 Ark Pixel 字体只影响输入框/预览文字外观。
// - ark12.json 位图表才用于真正生成 370 LED 滚动帧。
// - ensureScrollFontsLoaded()/ensureArkPixelFontReady() 延迟加载大资源，避免拖慢启动。
// - buildTextGlyph()/buildTextScrollBitmap() 在 6.4 timeline 构建时消费这里的数据。
let textScrollBrowserFontLoading = null;

function applyTextScrollInputFont() {
  const el = document.getElementById("scroll-text");
  if (!el) return;
  document.documentElement.style.setProperty("--scroll-font", TEXT_SCROLL_FONT_STACK);
  el.style.setProperty("font-family", TEXT_SCROLL_FONT_STACK, "important");
  el.style.setProperty("font-size", "12px", "important");
  el.style.setProperty("line-height", "1.2", "important");
  el.style.setProperty("font-synthesis", "none", "important");
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

function clearTextScrollCaches() {
  buildTextScrollBitmap.cacheKey = "";
  buildTextScrollBitmap.cache = null;
  buildTextGlyph.cache = new Map();
}
async function ensureArkPixelFontReady() {
  if (arkPixelFont.ready) return arkPixelFont;
  if (arkPixelFont.loading) return arkPixelFont.loading;
  arkPixelFont.loading = fetch(TEXT_SCROLL_FONT_RESOURCE, {
    cache: "no-store",
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
    arkPixelFont.glyphs.set(cp, {
      cp,
      advance: Math.max(1, Number(packed.advance || data.defaultAdvance || 12)),
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

// -----------------------------------------------------------------------------
// 通用工具函数
// -----------------------------------------------------------------------------
// 连接关系：
// - 这些函数不拥有状态，只做小型转换：DOM 查询、数值夹取、frame 编码、日志等。
// - frameToM370()/m370ToFrame() 是浏览器 frame 和固件 M370 字符串之间的边界。
// - log()/renderLog() 给调试页显示最近事件，也被 API/上传流程复用。
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

function frameToM370(frame) {
  let bits =
    frame
      .slice(0, TOTAL_LEDS)
      .map((v) => (v ? "1" : "0"))
      .join("") + "00";
  let out = "";
  for (let i = 0; i < bits.length; i += 4)
    out += parseInt(bits.slice(i, i + 4), 2)
      .toString(16)
      .toUpperCase();
  return "M370:" + out.padEnd(93, "0").slice(0, 93);
}

function m370ToFrame(text) {
  let s = String(text || "").trim();
  if (s.toUpperCase().startsWith("M370:")) s = s.slice(5);
  s = s.replace(/\s+/g, "");
  if (!/^[0-9a-fA-F]{93}$/.test(s)) throw new Error("M370 必须是 93 个 hex 字符，或 M370:<93 hex>");
  let bits = "";
  for (const ch of s) bits += parseInt(ch, 16).toString(2).padStart(4, "0");
  return bits
    .slice(0, TOTAL_LEDS)
    .split("")
    .map((b) => b === "1");
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

function log(msg) {
  const line = `[${new Date().toLocaleTimeString()}] ${msg}`;
  logs.push(line);
  if (logs.length > 500) logs.shift();
  renderLog();
}

function renderLog() {
  const el = $("log");
  if (el) {
    el.textContent = logs.join("\n");
    el.scrollTop = el.scrollHeight;
  }
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
    // file:// 无法访问 ESP32 的相对 API。保留这些调用为无操作失败，
    // 这样用户导入或打开 saved_faces.json 后，HTML 仍可离线使用。
    return null;
  }
  return p.startsWith("/") ? p : "/" + p;
}
// -----------------------------------------------------------------------------
// 固件 API 客户端
// -----------------------------------------------------------------------------
// 连接关系：
// - apiGet()/apiPost() 是所有固件 HTTP 通信的唯一入口。
// - 上层模块只传 endpoint 和 payload；这里统一加超时、错误处理和离线模式判断。
// - apiPostWithUploadProgress() 专门服务 6.4 的大 scroll timeline 上传。
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
  firmware.lastRequest = `POST ${path}`;
  renderState();
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = "offline html mode";
    firmware.lastError = `offline: ${path}`;
    throw new Error(`offline html mode: ${path}`);
  }
  const timeoutMs = options.timeoutMs || API_POST_TIMEOUT_MS;
  const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
  const timeout = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(payload || {}),
      signal: controller?.signal,
    });
    firmware.online = res.ok;
    firmware.lastStatus = `${res.status} ${res.statusText || ""}`.trim();
    if (!res.ok) {
      firmware.lastError = firmware.lastStatus;
      throw new Error(firmware.lastStatus);
    }
    const text = await res.text();
    return parseApiJson(text, path, {
      ok: true,
    });
  } catch (err) {
    const message =
      err?.name === "AbortError"
        ? `POST ${path} timeout after ${timeoutMs}ms`
        : err.message || String(err);
    firmware.online = false;
    firmware.lastError = message;
    throw new Error(message);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

function apiPostWithUploadProgress(path, payload, onProgress = () => {}) {
  const url = apiUrl(path);
  const body = JSON.stringify(payload || {});
  firmware.lastRequest = `POST ${path}`;
  setFirmwareStatus({
    lastRequest: firmware.lastRequest,
    lastStatus: "uploading",
  });
  if (!url) {
    firmware.online = false;
    firmware.lastStatus = "offline html mode";
    firmware.lastError = `offline: ${path}`;
    return Promise.reject(new Error(`offline html mode: ${path}`));
  }
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", url, true);
    xhr.timeout = API_UPLOAD_TIMEOUT_MS;
    xhr.setRequestHeader("Content-Type", "application/json");
    xhr.setRequestHeader("Accept", "application/json");
    xhr.upload.onprogress = (ev) => {
      if (ev.lengthComputable && ev.total > 0) onProgress(ev.loaded / ev.total);
    };
    xhr.onload = () => {
      firmware.online = xhr.status >= 200 && xhr.status < 300;
      firmware.lastStatus = `${xhr.status} ${xhr.statusText || ""}`.trim();
      if (!firmware.online) {
        firmware.lastError = firmware.lastStatus;
        reject(new Error(firmware.lastStatus));
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
      firmware.lastError = `POST ${path} failed`;
      reject(new Error(firmware.lastError));
    };
    xhr.ontimeout = () => {
      firmware.online = false;
      firmware.lastStatus = "timeout";
      firmware.lastError = `POST ${path} timeout after ${API_UPLOAD_TIMEOUT_MS}ms`;
      reject(new Error(firmware.lastError));
    };
    xhr.send(body);
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

// -----------------------------------------------------------------------------
// 电源和固件状态同步
// -----------------------------------------------------------------------------
// 连接关系：
// - applyFirmwareRuntimeState() 把 /api/status 返回值合并进 state、firmware 和 scroll。
// - renderState()/renderMatrices() 随后读取这些状态更新 UI。
// - scroll stop 事件会触发一次更完整的同步，确保固件按钮操作能回到 WebUI。
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
    setFinitePowerField(
      "batteryDisconnectLowThresholdMv",
      powerData.batteryDisconnectLowThresholdMv,
    ) || stateChanged;
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
  const skipFrame = !!options.skipFrame;
  const renderer = data.renderer || data;
  let stateChanged = false;
  let faceChanged = false;
  let frameChanged = false;
  const wasScrollBeforeFirmwareSync =
    state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback);

  if (data.ap?.ip) {
    state.apIp = data.ap.ip;
    stateChanged = true;
  }
  if (data.ap?.domain) {
    state.apDomain = data.ap.domain;
    stateChanged = true;
  }

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
    scroll.firmwareBacked = firmwareScrollActive || firmwareScrollPaused;
    const playbackIsScroll = isScrollPlaybackValue(playbackValue);
    scroll.userPaused = hasSplitPauseFlags
      ? firmwareScrollUserPaused
      : playbackValue === "scroll_paused" || firmwareScrollPaused;
    scroll.systemPaused = hasSplitPauseFlags ? firmwareScrollSystemPaused : false;
    scroll.paused =
      scroll.userPaused ||
      scroll.systemPaused ||
      playbackValue === "scroll_paused" ||
      firmwareScrollPaused;
    scroll.active = playbackValue === "scroll" && !scroll.paused;
    state.textScrollActive = playbackIsScroll || firmwareScrollActive || firmwareScrollPaused;
    if (!playbackIsScroll && !firmwareScrollActive && !firmwareScrollPaused) {
      scroll.active = false;
      scroll.paused = false;
      scroll.userPaused = false;
      scroll.systemPaused = false;
      state.textScrollActive = false;
    }
    stateChanged = true;
  }

  const scrollMaxFramesValue = Number(renderer.scrollMaxFrames ?? data.scrollMaxFrames);
  if (Number.isFinite(scrollMaxFramesValue) && scrollMaxFramesValue > 0) {
    firmwareScrollMaxFrames = Math.floor(scrollMaxFramesValue);
  }

  const scrollFrameCountValue = Number(renderer.scrollFrameCount ?? data.scrollFrameCount);
  if (
    Number.isFinite(scrollFrameCountValue) &&
    scrollFrameCountValue === 0 &&
    !isScrollPlaybackValue(state.playback)
  ) {
    scroll.firmwareBacked = false;
  }
  const scrollFrameIndexValue = Number(renderer.scrollFrameIndex ?? data.scrollFrameIndex);
  if (Number.isFinite(scrollFrameIndexValue) && scroll.frames.length) {
    scroll.frameIndex = clamp(scrollFrameIndexValue, 0, Math.max(0, scroll.frames.length - 1));
  }

  const brightnessValue = Number(renderer.brightness ?? data.brightness);
  if (Number.isFinite(brightnessValue)) {
    const nextBrightness = clampBrightness(brightnessValue);
    if (!brightnessChangedByUser) state.defaultBrightness = nextBrightness;
    if (state.brightness !== nextBrightness) {
      state.brightness = nextBrightness;
      if ($("brightness-range")) $("brightness-range").value = state.brightness;
      if ($("brightness-input")) $("brightness-input").value = state.brightness;
      updateDps();
      stateChanged = true;
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

  const firmwareIsScrolling =
    state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback);
  const firmwareM370 = renderer.lastM370 || renderer.m370 || data.m370;
  if (
    !skipFrame &&
    !firmwareIsScrolling &&
    typeof firmwareM370 === "string" &&
    firmwareM370.trim()
  ) {
    try {
      currentFrame = m370ToFrame(firmwareM370);
      if (!firmwareIsScrolling) scrollFrame = cloneFrame(currentFrame);
      state.lastRefreshReason = renderer.lastReason || data.lastReason || source;
      frameChanged = true;
      stateChanged = true;
    } catch (e) {}
  }

  syncAutoIntervalUi();
  if (faceChanged) renderSavedFaces();
  if (frameChanged) {
    renderMatrices();
    updateM370Views();
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
  if (stateChanged) renderState();
}

// -----------------------------------------------------------------------------
// 固件命令队列
// -----------------------------------------------------------------------------
// 连接关系：
// - UI 高频操作不会直接打到固件，而是进入 button/frame 两条队列。
// - pumpButtonCommandQueue() 处理模式、按钮、停止/暂停等轻量命令。
// - pumpFrameSendQueue() 处理 370 LED frame，并按 WEBUI_CONFIG 的节奏限流。
// - guardBeforeOutput()/terminateOtherActivities() 确保 static/auto/scroll 模式互斥。
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
      if (!isOfflineHtmlMode() && shouldLogApiError()) log(`辅助指令发送失败: ${err.message}`);
    });
  return packet;
}

function scheduleButtonCommandPump(delay = 0) {
  if (buttonCommandTimer) clearTimeout(buttonCommandTimer);
  buttonCommandTimer = setTimeout(
    () => {
      buttonCommandTimer = 0;
      pumpButtonCommandQueue();
    },
    Math.max(0, delay),
  );
}

function pumpButtonCommandQueue() {
  if (buttonCommandInFlight) return;
  if (!buttonCommandQueue.length) {
    firmware.buttonQueue = 0;
    renderState();
    return;
  }
  const now = performance.now();
  const waitMs = Math.max(0, WEBUI_BUTTON_COMMAND_INTERVAL_MS - (now - lastButtonCommandAt));
  if (waitMs > 0) {
    scheduleButtonCommandPump(waitMs);
    return;
  }
  const queued = buttonCommandQueue.shift();
  firmware.buttonQueue = buttonCommandQueue.length;
  buttonCommandInFlight = true;
  lastButtonCommandAt = performance.now();
  firmware.sentCommands++;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.command}`,
    lastStatus: `queued button (${buttonCommandQueue.length}/${WEBUI_BUTTON_COMMAND_QUEUE_MAX})`,
  });
  apiPost(API_ENDPOINTS.command, queued.request)
    .then((data) => {
      applyFirmwareRuntimeState(data, queued.source);
      queued.resolve(data);
      return data;
    })
    .catch((err) => {
      setFirmwareStatus({
        lastStatus: "button command failed",
        lastError: err.message,
      });
      if (shouldLogApiError()) log(`button command failed; using local fallback: ${err.message}`);
      if (queued.fallback) queued.fallback();
      queued.resolve(null);
      return null;
    })
    .finally(() => {
      buttonCommandInFlight = false;
      firmware.buttonQueue = buttonCommandQueue.length;
      scheduleButtonCommandPump(0);
    });
  renderState();
}

function sendButtonCommand(button, source = "webui_button", fallback = null) {
  if (isScrollPageActive() && ["B1", "B2", "B3"].includes(String(button).toUpperCase())) {
    resetScrollControlsAfterButton(source);
  }
  if (isOfflineHtmlMode()) {
    if (fallback) fallback();
    return {
      cmd: "button",
      source,
      payload: {
        button,
      },
      offline: true,
    };
  }
  const packet = {
    cmd: "button",
    payload: {
      button,
    },
  };
  const queued = {
    request: packet,
    source,
    fallback,
    promise: null,
    resolve: null,
  };
  queued.promise = new Promise((resolve) => {
    queued.resolve = resolve;
  });
  if (buttonCommandQueue.length >= WEBUI_BUTTON_COMMAND_QUEUE_MAX) {
    const dropped = buttonCommandQueue.shift();
    if (dropped && typeof dropped.resolve === "function") dropped.resolve(null);
    firmware.droppedCommands++;
  }
  buttonCommandQueue.push(queued);
  firmware.buttonQueue = buttonCommandQueue.length;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.command}`,
    lastStatus: `queued button (${buttonCommandQueue.length}/${WEBUI_BUTTON_COMMAND_QUEUE_MAX})`,
  });
  scheduleButtonCommandPump(0);
  packet.promise = queued.promise;
  return packet;
}

function scheduleFrameSendPump(delay = 0) {
  if (frameSendTimer) clearTimeout(frameSendTimer);
  frameSendTimer = setTimeout(
    () => {
      frameSendTimer = 0;
      pumpFrameSendQueue();
    },
    Math.max(0, delay),
  );
}

function pumpFrameSendQueue() {
  if (frameSendInFlight) return;
  if (!frameSendQueue.length) {
    firmware.frameQueue = 0;
    renderState();
    return;
  }
  const now = performance.now();
  const waitMs = Math.max(0, WEBUI_M370_SEND_INTERVAL_MS - (now - lastFrameSendAt));
  if (waitMs > 0) {
    scheduleFrameSendPump(waitMs);
    return;
  }
  const packet = frameSendQueue.shift();
  firmware.frameQueue = frameSendQueue.length;
  frameSendInFlight = true;
  lastFrameSendAt = performance.now();
  firmware.sentFrames++;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.frame}`,
    lastStatus: isOfflineHtmlMode()
      ? "queued offline"
      : `queued frame (${frameSendQueue.length}/${WEBUI_M370_QUEUE_MAX})`,
  });
  apiPost(API_ENDPOINTS.frame, packet)
    .catch((err) => {
      setFirmwareStatus({
        lastStatus: isOfflineHtmlMode() ? "offline html mode" : "frame failed",
        lastError: err.message,
      });
      if (!isOfflineHtmlMode() && shouldLogApiError()) log(`M370 帧发送失败: ${err.message}`);
    })
    .finally(() => {
      frameSendInFlight = false;
      firmware.frameQueue = frameSendQueue.length;
      scheduleFrameSendPump(0);
    });
  renderState();
}

function queueFirmwareFrame(frame, reason = "frame_update", playback = "idle") {
  const m370 = frameToM370(frame);
  pendingFramePacket = {
    type: "m370_frame",
    m370,
    reason,
    mode: playback,
    at: Date.now(),
  };
  if (frameSendQueue.length >= WEBUI_M370_QUEUE_MAX) {
    frameSendQueue.shift();
    firmware.droppedFrames++;
  }
  frameSendQueue.push(pendingFramePacket);
  firmware.frameQueue = frameSendQueue.length;
  setFirmwareStatus({
    lastRequest: `POST ${API_ENDPOINTS.frame}`,
    lastStatus: isOfflineHtmlMode()
      ? "queued offline"
      : `queued frame (${frameSendQueue.length}/${WEBUI_M370_QUEUE_MAX})`,
  });
  scheduleFrameSendPump(0);
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
  updateM370Views();
}

function orFrameIntoFrame(targetFrame, sourceFrame) {
  for (let i = 0; i < TOTAL_LEDS; i++) if (sourceFrame[i]) targetFrame[i] = true;
}

function orPartIntoFrame(frame, part) {
  // 标准 WebUI/M370 路径：使用 part.m370，因为它是按逻辑行优先排列的数据。
  // 旧版 strip_indices 是物理蛇形位置，因此需要映射回逻辑单元。
  if (part && typeof part.m370 === "string") {
    orFrameIntoFrame(frame, m370ToFrame(part.m370));
    return;
  }
  // 仅作为畸形旧资源的兜底。
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
  updateM370Views();
  setCurrentFrame(partsFrame, reason, "idle");
  if (writeLog) log("M370 已发送到固件接口");
}

function sendPartsFrameIfLive(reason = "parts_live_send") {
  if (liveSendEnabled) sendPartsFrame(reason, false);
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

  // 单向保护规则：
  // 启动/发送另一种模式是硬中断，不是临时暂停。
  // 这里停止的内容不会在新模式结束后自动恢复。
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

function setCurrentFrame(frame, reason = "manual_update", playback = null) {
  guardBeforeOutput(reason, playback);
  currentFrame = cloneFrame(frame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  if (playback !== null) state.playback = playback;
  updateDps();
  renderMatrices();
  renderState();
  updateM370Views();
  queueFirmwareFrame(currentFrame, reason, state.playback);
}

function updateDps() {
  const rgb = hexToRgb(state.color);
  const colorFactor = (rgb.r + rgb.g + rgb.b) / (LED_FULL_BRIGHTNESS * 3);
  const estimatedW =
    onCount(currentFrame) *
    LED_ESTIMATED_WATTS_PER_CHANNEL *
    LED_CHANNEL_COUNT *
    (state.brightness / LED_FULL_BRIGHTNESS) *
    colorFactor;
  state.dpsActive = estimatedW > LED_POWER_WARNING_WATTS;
  const warn = $("dps-warning");
  if (warn) warn.classList.toggle("show", state.dpsActive);
}

function setColor(hex, source = "color_change") {
  const c = normalizeHexColor(hex);
  if (!c) {
    alert("颜色必须是 #RRGGBB 或 RRGGBB");
    return;
  }
  const unchangedFirmwareSync = source === "firmware_sync" && state.color === c;
  state.color = c;
  document.documentElement.style.setProperty("--led-color", c);
  if ($("color-input")) $("color-input").value = c;
  if ($("color-swatch")) $("color-swatch").style.background = c;
  syncColorDropdownsToHex(c);
  updateDps();
  renderMatrices();
  renderState();
  if (unchangedFirmwareSync) return;
  log(`颜色更新 ${c} (${source})`);
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
  brightnessChangedByUser = true;
  applyBrightnessLocal(v);
  log(`亮度更新 raw=${state.brightness} (${source})`);
  sendAuxCommand(
    "set_brightness",
    {
      raw: state.brightness,
    },
    source,
  );
}

// -----------------------------------------------------------------------------
// 启动加载器和初始固件同步
// -----------------------------------------------------------------------------
// 连接关系：
// - loading-overlay 的视觉状态由 index.html 标记和 styles.css 动画控制。
// - 本块只负责切换 data-boot-phase/class，并把首个固件快照预加载进 state。
// - bootstrapWebUi() 调用这些函数，让网络读取和加载动画时间重叠。
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
// ── Rina 加载遮罩动画 ─────────────────────────────────
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
  let peakTimer = null,
    haloTimer = null,
    holdTimer = null,
    removeTimer = null,
    blurTimer = null,
    rafId = null;
  let afterImageReadyPromise = null;
  let loaderHorizontalRaf = 0;
  let lockedCenterX = 0,
    lockedCenterY = 0;

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

  function syncLoaderHorizontalCenter() {
    const center = firstViewportCenter();
    lockedCenterX = center.x;
    document.documentElement.style.setProperty("--rina-loader-x", lockedCenterX.toFixed(2) + "px");
  }

  function scheduleLoaderHorizontalCenterSync() {
    if (!started || overlay.hidden) return;
    if (loaderHorizontalRaf) return;
    loaderHorizontalRaf = requestAnimationFrame(() => {
      loaderHorizontalRaf = 0;
      syncLoaderHorizontalCenter();
      if (blurScreen.classList.contains("is-revealing")) setOrigin();
    });
  }

  function loaderSurfaceRect() {
    return (blurScreen || overlay).getBoundingClientRect();
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

  function getMaxR() {
    syncLoaderHorizontalCenter();
    const o = loaderSurfaceRect();
    const cx = lockedCenterX - o.left,
      cy = lockedCenterY - o.top;
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
    syncLoaderHorizontalCenter();
    const o = loaderSurfaceRect();
    blurScreen.style.setProperty("--rina-reveal-x", (lockedCenterX - o.left).toFixed(2) + "px");
    blurScreen.style.setProperty("--rina-reveal-y", (lockedCenterY - o.top).toFixed(2) + "px");
  }

  function animateReveal() {
    setOrigin();
    const start = performance.now(),
      maxR = getMaxR(),
      f = Math.max(96, Math.min(180, Math.round(maxR * 0.12)));
    blurScreen.classList.add("is-revealing");
    overlay.classList.add("is-scroll-passthrough");
    unlockBootPageScroll();

    function fr(now) {
      const t = Math.min(1, (now - start) / BLUR_DUR_MS),
        r = maxR * eic(t);
      [
        ["--rina-reveal-solid", Math.max(0, r - f)],
        ["--rina-reveal-a", Math.max(0, r - f * 0.72)],
        ["--rina-reveal-b", Math.max(0, r - f * 0.42)],
        ["--rina-reveal-c", Math.max(0, r - f * 0.12)],
        ["--rina-reveal-d", Math.max(0, r + f * 0.22)],
        ["--rina-reveal-e", Math.max(0, r + f * 0.56)],
        ["--rina-reveal-outer", Math.max(0, r + f)],
      ].forEach(([p, v]) => blurScreen.style.setProperty(p, v.toFixed(2) + "px"));
      if (t < 1) rafId = requestAnimationFrame(fr);
    }
    rafId = requestAnimationFrame(fr);
  }

  function finishOverlay() {
    const wait = Math.max(IMG_RELEASE_MS, IMG_SHRINK_MS + BLUR_DUR_MS);
    removeTimer = window.setTimeout(() => {
      overlay.classList.add("is-hidden");
      removeTimer = window.setTimeout(() => {
        overlay.hidden = true;
        overlay.classList.remove("is-animating");
        unlockBootPageScroll();
      }, EXTRA_MS);
    }, wait + EXTRA_MS);
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
    peakTimer = window.setTimeout(doFinish, delayToPeak());
  }
  async function doFinish() {
    if (finished) return;
    finished = true;
    finishPending = false;
    avatarBefore.src = ICON_BEFORE;
    try {
      await preloadAfterLoadingImage();
    } catch (err) {
      console.warn("Rina loading hover image failed", err);
    }
    overlay.classList.add("is-ring-contracting", "is-image-pop");
    overlay.setAttribute("aria-label", "页面加载完成");
    haloTimer = window.setTimeout(() => overlay.classList.add("is-halo-hidden"), HALO_CONTRACT_MS);
    holdTimer = window.setTimeout(() => {
      overlay.classList.add("is-final-release");
      blurTimer = window.setTimeout(animateReveal, IMG_SHRINK_MS);
      finishOverlay();
    }, HOLD_MS);
  }

  function initOverlay() {
    if (started) return;
    finished = false;
    finishPending = false;
    haloCycleStart = performance.now();
    [peakTimer, haloTimer, holdTimer, removeTimer, blurTimer].forEach((t) =>
      window.clearTimeout(t),
    );
    if (rafId) {
      cancelAnimationFrame(rafId);
      rafId = null;
    }
    overlay.hidden = false;
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
    [
      "--rina-reveal-solid",
      "--rina-reveal-a",
      "--rina-reveal-b",
      "--rina-reveal-c",
      "--rina-reveal-d",
      "--rina-reveal-e",
      "--rina-reveal-outer",
    ].forEach((p) => blurScreen.style.setProperty(p, "0px"));
    setOrigin();
    overlay.setAttribute("aria-label", "页面加载中");
    started = true;
    window.rinaLoaderStartedAt = haloCycleStart;
    // 悬停加载图片刻意不在这里（第 3 阶段）预加载。它会在
    // doFinish() 中延迟加载，也就是第 4 阶段首屏揭示之后，以保持初始预加载最小。
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
  window.addEventListener("resize", scheduleLoaderHorizontalCenterSync, {
    passive: true,
  });
  window.visualViewport?.addEventListener("resize", scheduleLoaderHorizontalCenterSync, {
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
    // 获取完整状态（包含 renderer.lastM370 中的第一帧 LED），
    // 而不是 runtimeOnly/noFrame 摘要，并用 skipFrame:false 应用它，
    // 让基础矩阵预览在加载动画期间就由第一帧填充。
    const data = await bootFastJsonGet(firmwareStatusPath(false));
    rememberFirmwareStatusPoll(data);
    bootRuntimeSnapshot = {
      attempted: true,
      ok: true,
      error: "",
      data,
    };
    applyFirmwareRuntimeState(data, "page_boot_runtime", {
      skipFrame: false,
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
    if (shouldLogApiError()) log(`启动读取固件状态失败: ${bootRuntimeSnapshot.error}`);
    return bootRuntimeSnapshot;
  }
}
async function syncRuntimeStateFromFirmware(source = "webui_load") {
  if (firmwareFullStatusInFlight) return false;
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
      log(`读取固件运行/预览状态失败: ${err.message}`);
    return false;
  } finally {
    firmwareFullStatusInFlight = false;
  }
}
async function syncRuntimeSummaryFromFirmware(source = "firmware_poll_runtime_summary") {
  if (firmwareRuntimeSummaryInFlight) return false;
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
    if (!isOfflineHtmlMode() && shouldLogApiError()) log(`读取固件轻量状态失败: ${err.message}`);
    return false;
  } finally {
    firmwareRuntimeSummaryInFlight = false;
  }
}

function startFirmwareStatusPolling() {
  if (firmwareStatusPollTimer || isOfflineHtmlMode()) return;
  firmwareStatusPollTimer = setInterval(() => {
    const firmwareIsScrolling =
      state.textScrollActive || scroll.firmwareBacked || isScrollPlaybackValue(state.playback);
    const scrollPageNeedsFastStopNotice = firmwareIsScrolling && isScrollPageActive();
    const minInterval = scrollPageNeedsFastStopNotice
      ? Math.min(550, firmwareNextPollMs)
      : Math.max(1000, firmwareNextPollMs);
    if (performance.now() - lastFirmwareStatusPollAt < minInterval) return;
    if (firmwareIsScrolling) {
      syncRuntimeSummaryFromFirmware(
        scrollPageNeedsFastStopNotice
          ? "firmware_poll_scroll_runtime"
          : "firmware_poll_scroll_summary",
      );
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
    firmwareRuntimeSummaryInFlight
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
    if (shouldLogApiError()) log(`power status refresh failed: ${err.message}`);
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

function scheduleDebugMasonryLayout(force = false) {
  if (document.body?.dataset?.page !== "debug") return;
  if (debugLayoutRaf) cancelAnimationFrame(debugLayoutRaf);
  debugLayoutRaf = requestAnimationFrame(() => {
    debugLayoutRaf = 0;
    setupDebugMasonryLayout(force);
  });
}

function setupDebugMasonryLayout(force = false) {
  const layout = document.querySelector("#page-debug .debug-layout");
  if (!layout) return;
  const currentCards = [...layout.querySelectorAll(".debug-column > .card, :scope > .card")];
  if (!debugLayoutCards.length) {
    debugLayoutCards = currentCards;
    debugLayoutCards.forEach((card, index) => {
      card.dataset.debugOrder = String(index);
    });
  }
  const cards = debugLayoutCards.filter((card) => card && layout.contains(card));
  const count = responsiveColumnCount();
  if (
    !force &&
    debugLayoutColumnCount === count &&
    layout.querySelectorAll(":scope > .debug-column").length === count
  )
    return;
  const scrollEl = document.scrollingElement || document.documentElement;
  const prevScrollTop = scrollEl ? scrollEl.scrollTop : 0;
  const prevScrollLeft = scrollEl ? scrollEl.scrollLeft : 0;
  const columns = Array.from(
    {
      length: count,
    },
    (_, index) => {
      const column = document.createElement("div");
      column.className = "debug-column";
      column.dataset.debugColumn = String(index + 1);
      return column;
    },
  );
  const columnHeights = Array.from(
    {
      length: count,
    },
    () => 0,
  );
  cards
    .sort((a, b) => Number(a.dataset.debugOrder || 0) - Number(b.dataset.debugOrder || 0))
    .forEach((card, index) => {
      const measuredHeight = card.getBoundingClientRect().height || 0;
      const shortest = columnHeights.indexOf(Math.min(...columnHeights));
      const columnIndex = measuredHeight > 0 ? shortest : index % count;
      columns[columnIndex].appendChild(card);
      columnHeights[columnIndex] += measuredHeight;
    });
  layout.replaceChildren(...columns);
  debugLayoutColumnCount = count;
  scheduleMatrixFitRender(2);
  if (force && prevScrollTop > 0 && scrollEl) {
    requestAnimationFrame(() => {
      scrollEl.scrollTop = prevScrollTop;
      scrollEl.scrollLeft = prevScrollLeft;
    });
  }
}

function switchPage(id) {
  terminateOtherActivities(modeForPage(id), `switch_page_${id}`);
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
    requestAnimationFrame(() => {
      autoResizeScrollTextInput();
      updateScrollUi();
    });
  }
  if (id === "custom")
    requestAnimationFrame(() => {
      const a = $("custom-m370");
      if (a) autoResizeTextarea(a);
    });
  if (id === "parts")
    requestAnimationFrame(() => {
      const a = $("parts-m370-text");
      if (a) autoResizeTextarea(a);
    });
  if (id === "debug") {
    requestAnimationFrame(() => {
      setupDebugMasonryLayout(true);
      const a = $("debug-m370");
      if (a) autoResizeTextarea(a);
    });
    refreshPowerStatusFromFirmware("debug_page_enter", true);
  }
  if (id === "basic") {
    syncRuntimeStateFromFirmware("basic_page_enter");
    refreshPowerStatusFromFirmware("basic_page_enter", true);
  }
}

// -----------------------------------------------------------------------------
// 导航、响应式布局和自定义选择器
// -----------------------------------------------------------------------------
// 连接关系：
// - initNav() 根据 PAGES 生成顶部页面菜单，菜单按钮切换 .page.active。
// - switchPage() 负责页面生命周期：进入 6.4 时启动字体懒加载，离开时保持状态同步。
// - 响应式辅助只设置必要 class/尺寸；真正布局仍由 styles.css 的 grid/media rules 决定。
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
  // 只是一个标记：通过拦截事件阻止滚动，保持
  // 滚动条可见且布局不变（不修改 overflow）。
  selectScrollLock = true;
}

function unlockPageScrollForSelects() {
  selectScrollLock = null;
}

function syncSelectPageScrollLock() {
  if (document.querySelector(".select-shell.open")) lockPageScrollForSelects();
  else unlockPageScrollForSelects();
}
// 阻止下拉菜单外的 touchmove（触摸滚动）
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
// 阻止下拉菜单外的 wheel 事件（鼠标/触控板滚动）
function blockPageWheelWhileSelectOpen(ev) {
  if (!selectScrollLock) return;
  const menu = ev.target?.closest?.(".select-menu");
  if (selectMenuCanScroll(menu)) return;
  ev.preventDefault();
}
// 阻止下拉菜单外的键盘滚动键
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
  // verticalOnly：跳过宽度/左偏移重算（用于窗口滚动事件，防止水平跳动）
  if (!options.verticalOnly) {
    // 镜像切换按钮的精确宽度和左边缘，不做舍入或夹取。
    shell._selectMenuWidth = r.width; // 保持为真值，让“已打开”标记持续有效
    menu.style.width = r.width + "px";
    menu.style.left = r.left + "px";
  }
  // 默认放在下方；空间不足时翻到上方
  const spaceBelow = Math.max(0, viewport.bottom - r.bottom - menuGap - viewportPadding);
  const spaceAbove = Math.max(0, r.top - viewport.top - menuGap - viewportPadding);
  const openBelow = spaceBelow >= 96 || spaceBelow >= spaceAbove;
  // 可用高度等于所选方向的完整空间，不设置任意上限。
  // 菜单会尽量展开以显示所有按钮；只有放不下时才进行不可见滚动。
  const availableHeight = Math.max(48, openBelow ? spaceBelow : spaceAbove);
  const menuStyle = getComputedStyle(menu);
  const borderY =
    parseFloat(menuStyle.borderTopWidth || "0") + parseFloat(menuStyle.borderBottomWidth || "0");
  const naturalH = menu.scrollHeight; // 内容完整高度，包含内边距但不含边框
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
  // 滚动或调整尺寸时重新定位已打开的菜单
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
  // visualViewport 滚动（双指缩放后的平移）：需要完整重定位
  window.visualViewport?.addEventListener("scroll", reposition, {
    passive: true,
  });
  // 窗口滚动：只更新垂直位置，避免水平宽度/左偏移跳动。
  // 滚动锁定时完全跳过（页面并未真正滚动，这些事件是冗余的）。
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

// -----------------------------------------------------------------------------
// LED 矩阵渲染和编辑
// -----------------------------------------------------------------------------
// 连接关系：
// - initMatrix() 把 index.html 中的矩阵容器变成 370 个可渲染 cell。
// - MATRIX_VIEW_CONFIGS 指定每个矩阵读取哪个 frame provider。
// - 点击编辑只修改对应缓冲区；setCurrentFrame()/queueFirmwareFrame() 才把结果推给固件。
// - renderMatrices() 是所有页面共享的最终视觉刷新点。
function initMatrix(id, frameProvider, editable = false, editHandler = null, compact = false) {
  const el = $(id);
  if (!el) return;
  el.innerHTML = "";
  if (compact) el.classList.add("compact");
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
      el.appendChild(cell);
    }
  }
  const view = {
    el,
    frameProvider,
    compact: !!compact,
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
  const card = wrap.closest(".led-preview-card,.debug-measure-card");
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

  // 平滑实时缩放：保持透明内边距与 --cell 成比例。
  // 适配公式会在包装层内预留 2 * edgeRatio * cell，
  // 因此 LED 矩阵边距会随 LED 网格一起缩放，
  // 不会在卡片尺寸变化时保持固定。
  const wrapRect = wrap.getBoundingClientRect();
  if (wrapRect.width <= 0 || wrap.offsetParent === null) {
    const cell = clamp(defaultCell, minCell, maxCell);
    const edgeGap = cell * edgeRatio;
    view.el.style.setProperty("--cell", cell.toFixed(4) + "px");
    view.el.dataset.cellPx = cell.toFixed(4);
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
  const cell = clamp(fitCell, minCell, maxCell);
  const edgeGap = cell * edgeRatio;
  view.el.style.setProperty("--cell", cell.toFixed(4) + "px");
  view.el.dataset.cellPx = cell.toFixed(4);
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
      .querySelectorAll(".matrix-wrap,.led-preview-card,.debug-measure-card")
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
    const frame = view.frameProvider();
    const cells = view.el.children;
    for (let y = 0, n = 0; y < ROWS; y++) {
      for (let x = 0; x < COLS; x++, n++) {
        const idx = XY_TO_INDEX[y][x];
        if (idx >= 0) cells[n].classList.toggle("on", !!frame[idx]);
      }
    }
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

// -----------------------------------------------------------------------------
// UI 渲染器
// -----------------------------------------------------------------------------
// 连接关系：
// - renderState() 是 state -> DOM 的集中出口，避免业务函数到处改 UI 文案。
// - renderFaceLibrary()/renderPartButtons()/updateScrollUi() 处理各自复杂子视图。
// - 所有渲染函数都应是幂等的：重复调用只能刷新，不应重复绑定事件或改变业务状态。
function renderState() {
  const library = getAllFaces();
  const currentFace = library[state.faceIndex] || {
    name: "—",
    type: "—",
  };
  updateModeToggleUi();
  const kv = $("state-kv");
  if (kv)
    kv.innerHTML = kvRows([
      ["当前模式", state.mode],
      ["当前表情序号", `${library.length ? state.faceIndex + 1 : 0} / ${library.length}`],
      ["当前表情名称", currentFace.name],
      ["当前表情属性", faceTypeLabel(currentFace.type)],
      ["当前亮度", `${state.brightness}/255`],
      ["当前颜色", state.color],
      ["当前播放状态", state.playback],
      ["当前 AP Domain", state.apDomain],
      ["当前 AP IP", state.apIp],
      ["刷新策略", state.refreshPolicy],
      ["最近刷新原因", state.lastRefreshReason],
      ["刷新计数", state.refreshCount],
    ]);
  const dk = $("debug-kv");
  if (dk)
    dk.innerHTML = kvRows([
      ["LED 数量", TOTAL_LEDS],
      ["矩阵", `${COLS}x${ROWS} / 不规则 370`],
      ["M370 长度", "93 hex + M370:"],
      ["亮度 raw", `${state.brightness}`],
      ["DPS 状态", state.dpsActive ? "active" : "inactive"],
      ["播放状态", state.playback],
      ["文字滚动", state.textScrollActive ? "active" : "inactive"],
      ["实际 FPS", state.actualFps.toFixed(1)],
      ["电池状态", batteryPowerText()],
      ["低压未上电锁定", state.batteryLowVoltageUnpowered ? "是" : "否"],
      ["Vbat", `${formatVolts(state.batteryV)} / ${formatBatteryPercent(state.batteryPercent)}`],
      ["电池瞬时电压", formatVolts(state.batteryLastInstantVbat)],
      ["未上电电压阈值", formatVolts(state.batteryUnpoweredLowThreshold)],
      ["电池最低电压记录", formatVolts(state.batteryMinV)],
      ["电池最高电压记录", formatVolts(state.batteryMaxV)],
      ["电池 ADC raw", formatMilliVolts(state.batteryAdcMv)],
      ["上次电池 ADC raw", formatMilliVolts(state.batteryPrevAdcMv)],
      [
        "断电快速压降",
        `${formatMilliVolts(state.batteryDisconnectDropMv)} / 阈值 ${formatMilliVolts(state.batteryDisconnectDropThresholdMv)}`,
      ],
      ["断电低 ADC 阈值", formatMilliVolts(state.batteryDisconnectLowThresholdMv)],
      ["恢复 ADC 阈值", formatMilliVolts(state.batteryReconnectThresholdMv)],
      ["Vcharge", `${formatVolts(state.chargeV)} / ${formatChargingState(state.charging)}`],
      ["充电 ADC raw", formatMilliVolts(state.chargeAdcMv)],
      ["AP SSID", DEVICE_AP_SSID],
      ["AP 密码", DEVICE_AP_PASSWORD],
      ["AP Domain", state.apDomain],
      ["AP IP", state.apIp],
    ]);
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
  const rk = $("resource-kv");
  if (rk)
    rk.innerHTML = kvRows([
      ["JSON format", EXPRESSION_PARTS.format],
      ["version", EXPRESSION_PARTS.version],
      ["stored_unique_parts", EXPRESSION_PARTS.counts.stored_unique_parts],
      ["callable_ids", EXPRESSION_PARTS.counts.callable_ids],
      ["eye_left", EXPRESSION_PARTS.counts.stored_by_group.eye_left],
      ["eye_right", EXPRESSION_PARTS.counts.stored_by_group.eye_right],
      ["mouth", EXPRESSION_PARTS.counts.stored_by_group.mouth],
      ["cheek", EXPRESSION_PARTS.counts.callable_by_group.cheek],
      ["default_faces", defaultFaces.length],
      ["user_saved_faces", userFaces.length],
      ["interface_mode", "HTML generates M370 / firmware receives commands"],
      ["face_library_json", firmware.savedFacesPath],
      ["physical_wiring", SERPENTINE_WIRING ? "serpentine / odd rows reversed" : "linear"],
      ["parts_compose", "m370 logical row-major canonical"],
      ["parts_eye_symmetry", partsSymmetry ? "on / same display index" : "off"],
      [
        "preview_scale",
        "smooth fractional --cell live scaling / card horizontal-min vertical-max fit",
      ],
      ["basic_layout", "wide side-by-side"],
    ]);
  const fk = $("firmware-kv");
  if (fk)
    fk.innerHTML = kvRows([
      ["online", firmware.online ? "✓ connected" : "✗ offline"],
      ["lastRequest", firmware.lastRequest],
      ["lastStatus", firmware.lastStatus],
      ["lastError", firmware.lastError],
      ["sentFrames", String(firmware.sentFrames)],
      ["sentCommands", String(firmware.sentCommands)],
      ["frameQueue", `${firmware.frameQueue}/${WEBUI_M370_QUEUE_MAX}`],
      ["buttonQueue", `${firmware.buttonQueue}/${WEBUI_BUTTON_COMMAND_QUEUE_MAX}`],
      ["droppedFrames", String(firmware.droppedFrames)],
      ["droppedCommands", String(firmware.droppedCommands)],
      ["savedFacesSync", firmware.savedFacesSync],
    ]);
  scheduleDebugMasonryLayout();
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
  // 如果元素（或任一祖先）是 display:none，offsetParent 会是 null，
  // scrollHeight 也会返回 0。此时直接退出，避免把高度压成 0px；
  // 页面显示后 switchPage() 会再次调用这里。
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

function autoResizeM370Textareas() {
  const a = $("custom-m370");
  if (a) autoResizeTextarea(a);
  const b = $("parts-m370-text");
  if (b) autoResizeTextarea(b);
  const c = $("debug-m370");
  if (c) autoResizeTextarea(c);
}

function updateM370Views() {
  if ($("custom-m370")) {
    $("custom-m370").value = frameToM370(editFrame);
    requestAnimationFrame(() => autoResizeTextarea($("custom-m370")));
  }
  if ($("parts-m370-text")) {
    $("parts-m370-text").value = frameToM370(partsFrame);
    requestAnimationFrame(() => autoResizeTextarea($("parts-m370-text")));
  }
}

// -----------------------------------------------------------------------------
// 颜色、亮度和模式控制
// -----------------------------------------------------------------------------
// 连接关系：
// - 初始化函数把 index.html 控件接到 state setters。
// - setColor()/setBrightness() 更新 state、预览 frame 和固件输出队列。
// - 自动/手动模式按钮最终走 sendButtonCommand()/queueFirmwareFrame()，保持 UI 与设备一致。
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
  setCurrentFrame(m370ToFrame(face.m370), reason, "idle");
  renderSavedFaces();
  log(`应用表情 #${i + 1}: ${face.name} / ${faceTypeLabel(face.type)}`);
}

function initCustom() {
  $("custom-clear").onclick = () => {
    editFrame = blankFrame();
    renderMatrices();
    updateM370Views();
    sendCustomFrameIfLive("custom_live_clear");
    log("自定义画板清空");
  };
  $("custom-fill").onclick = () => {
    editFrame = blankFrame().map(() => true);
    renderMatrices();
    updateM370Views();
    sendCustomFrameIfLive("custom_live_fill");
    log("自定义画板全亮");
  };
  $("custom-invert").onclick = () => {
    editFrame = editFrame.map((v) => !v);
    renderMatrices();
    updateM370Views();
    sendCustomFrameIfLive("custom_live_invert");
    log("自定义画板反转");
  };
  $("custom-send").onclick = () => sendCustomFrame("custom_face_send", true);
  $("custom-live-toggle").onclick = () => toggleLiveSend("实时发送");
  $("custom-copy").onclick = () => {
    copyText(frameToM370(editFrame));
    log("复制自定义 M370");
  };
  $("custom-import").onclick = () => {
    try {
      editFrame = m370ToFrame($("custom-m370").value);
      renderMatrices();
      updateM370Views();
      log("导入自定义 M370 成功");
    } catch (e) {
      alert(e.message);
    }
  };
  $("custom-save").onclick = () =>
    saveFace($("custom-name").value || "custom_face", editFrame, "custom");
  updateLiveToggles();
  initFaceManagerControls();
}

function toggleLiveSend(label = "实时发送") {
  liveSendEnabled = !liveSendEnabled;
  updateLiveToggles();
  log(`${label} ${liveSendEnabled ? "开启" : "关闭"}`);
}

function updateLiveToggles() {
  ["custom-live-toggle", "parts-live-toggle"].forEach((id) => {
    const btn = $(id);
    if (!btn) return;
    btn.classList.toggle("active", liveSendEnabled);
    btn.setAttribute("aria-pressed", liveSendEnabled ? "true" : "false");
    btn.textContent = "实时";
  });
}

function sendCustomFrame(reason = "custom_face_send", writeLog = true) {
  updateM370Views();
  setCurrentFrame(editFrame, reason, "idle");
  if (writeLog) log("自定义 M370 已发送到固件接口");
}

function sendCustomFrameIfLive(reason = "custom_live_send") {
  if (liveSendEnabled) sendCustomFrame(reason, false);
}

function editCell(idx, value, tool) {
  editFrame[idx] = !!value;
  renderMatrices();
  updateM370Views();
  sendCustomFrameIfLive("custom_live_send");
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
  currentFrame = m370ToFrame(face.m370);
  scrollFrame = cloneFrame(currentFrame);
  state.lastRefreshReason = reason;
  state.refreshCount++;
  renderMatrices();
  updateM370Views();
  renderSavedFaces();
  return true;
}

function applyKnownFaceIndexLocal(reason = "firmware_face_index_preview") {
  const library = getAllFaces();
  if (!library.length) return false;
  const index = clamp(Number(state.faceIndex) || 0, 0, library.length - 1);
  const face = library[index];
  if (!face || typeof face.m370 !== "string") return false;
  state.faceIndex = index;
  currentFrame = m370ToFrame(face.m370);
  scrollFrame = cloneFrame(currentFrame);
  state.lastRefreshReason = reason;
  renderMatrices();
  updateM370Views();
  renderSavedFaces();
  return true;
}
// -----------------------------------------------------------------------------
// 已保存表情库持久化
// -----------------------------------------------------------------------------
// 连接关系：
// - loadFaceLibrary() 先读 LittleFS 默认库，再合并本地/用户表情。
// - save/export/import 只处理 JSON 文档；真正点阵显示仍走 setCurrentFrame()。
// - createFaceRow()/reorderFace()/deleteFace() 是 6.2 和 6.3 共享的列表 UI。
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
    version: 2,
    category: "unified_saved_faces",
    matrix: {
      leds: TOTAL_LEDS,
      m370HexChars: 93,
    },
    startupDefaultId: DEFAULT_STARTUP_FACE_ID,
    updatedAt: null,
    faces: [],
  };
  try {
    const apiDoc = await apiGet(API_ENDPOINTS.savedFaces);
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
          version: 2,
          faces: Array.isArray(doc) ? doc : [],
        };
  out.format = FACE_SCHEMA_FORMAT;
  out.version = Number(out.version || 2);
  out.category = "unified_saved_faces";
  out.matrix = out.matrix || {
    leds: TOTAL_LEDS,
    m370HexChars: 93,
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
  const m370 = String(f.m370 || "").trim();
  try {
    m370ToFrame(m370);
  } catch (e) {
    return null;
  }
  const type = normalizeFaceType(f.type || f.source || fallbackType);
  const id = String(f.id || `${type}_${i + 1}`);
  return {
    id,
    name: String(f.name || displayNameFromId(id)).slice(0, 64),
    type,
    m370: frameToM370(m370ToFrame(m370)),
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
    version: 2,
    category: "unified_saved_faces",
    matrix: {
      leds: TOTAL_LEDS,
      m370HexChars: 93,
    },
    startupDefaultId: preferredStartupDefaultId(faces),
    updatedAt: new Date().toISOString(),
    faces,
  };
}
async function saveFaceLibraryToLocalFile() {
  if (!faceLibraryFileHandle)
    throw new Error(
      "尚未打开本地 saved_faces.json。请先点击“打开本地 saved_faces.json”，或使用下载/导入流程。",
    );
  if (!window.showOpenFilePicker && !faceLibraryFileHandle.createWritable)
    throw new Error("当前浏览器不支持 File System Access API。请使用“下载 saved_faces.json”。");
  const writable = await faceLibraryFileHandle.createWritable();
  await writable.write(JSON.stringify(faceLibraryDocument || buildUnifiedFaceDocument(), null, 2));
  await writable.close();
  setFirmwareStatus({
    savedFacesSync: "saved to opened local saved_faces.json",
  });
  log("已保存到已打开的本地 saved_faces.json");
}
async function openLocalFaceLibraryFile() {
  if (!window.showOpenFilePicker) {
    alert(
      "当前浏览器不支持直接打开并写回本地文件。请使用“导入 saved_faces.json”与“下载 saved_faces.json”。",
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
    .then(() =>
      setFirmwareStatus({
        savedFacesSync: "saved to firmware saved_faces.json",
      }),
    )
    .catch(() =>
      setFirmwareStatus({
        savedFacesSync: faceLibraryFileHandle
          ? "saved locally; firmware offline"
          : "save failed/offline; use JSON download/import",
      }),
    )
    .finally(() => {
      log(`saved_faces.json 已同步：默认 ${defaultFaces.length} 项，用户 ${userFaces.length} 项`);
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
  log("已导出统一 saved_faces.json");
}
async function importFacesJsonText(text, reason = "import_saved_faces_json") {
  faceLibraryDocument = normalizeFaceDocument(JSON.parse(text), "custom");
  splitFaceLibraryDocument(faceLibraryDocument);
  state.faceIndex = 0;
  renderSavedFaces();
  renderState();
  await persistFaceDocuments(reason);
  log(`已导入统一 saved_faces.json：默认 ${defaultFaces.length} 项，用户 ${userFaces.length} 项`);
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
    m370: frameToM370(frame),
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
  persistFaceDocuments("save_user_face");
}

function renderSavedFaces() {
  const lists = document.querySelectorAll(".face-library-list");
  if (!lists.length) return;
  const library = getAllFaces();
  lists.forEach((box) => {
    box.innerHTML = "";
    if (!library.length) return;
    library.forEach((f, i) => {
      const row = createFaceRow(f, i, library.length);
      row.classList.toggle("active", i === state.faceIndex);
      box.appendChild(row);
    });
  });
  renderState();
}

function clearFaceDragOver(scope = document) {
  scope.querySelectorAll(".saved-row.drag-over").forEach((x) => x.classList.remove("drag-over"));
}

function faceRowIndexFromPoint(clientX, clientY, list) {
  const target = document.elementFromPoint(clientX, clientY);
  const row = target && target.closest && target.closest(".saved-row");
  if (!row || row.closest(".face-library-list") !== list) return null;
  const index = Number(row.dataset.index);
  return Number.isInteger(index) ? index : null;
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
      to: index,
      list,
      row,
      pointerId: ev.pointerId,
    };
    row.classList.add("dragging", "drag-over");
    handle.setPointerCapture?.(ev.pointerId);
  });
  handle.addEventListener("pointermove", (ev) => {
    if (!pointerFaceDrag || pointerFaceDrag.pointerId !== ev.pointerId) return;
    ev.preventDefault();
    autoScrollFaceList(ev.clientY);
    const to = faceRowIndexFromPoint(ev.clientX, ev.clientY, pointerFaceDrag.list);
    if (to === null) return;
    pointerFaceDrag.to = to;
    clearFaceDragOver(pointerFaceDrag.list);
    const targetRow = pointerFaceDrag.list.querySelector(`.saved-row[data-index="${to}"]`);
    if (targetRow) targetRow.classList.add("drag-over");
  });
  const finish = (ev) => {
    if (!pointerFaceDrag || pointerFaceDrag.pointerId !== ev.pointerId) return;
    ev.preventDefault();
    const { from, to, list, row: dragRow } = pointerFaceDrag;
    handle.releasePointerCapture?.(ev.pointerId);
    clearFaceDragOver(list);
    dragRow.classList.remove("dragging");
    pointerFaceDrag = null;
    if (from !== to) reorderFace(from, to);
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

  // 拖拽手柄
  const handle = document.createElement("button");
  handle.className = "drag-handle";
  handle.type = "button";
  handle.draggable = false;
  handle.title = "拖拽排序";
  handle.setAttribute("aria-label", "拖拽排序");
  attachFaceReorderHandle(handle, row, i);

  // 中间：命名框 + 元数据徽章
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
      persistFaceDocuments(f.type === "default" ? "rename_default_face" : "rename_user_face");
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
  meta.innerHTML = `<span class="face-source-badge ${badgeClass}">${faceTypeLabel(f.type)}</span> · ${onCount(m370ToFrame(f.m370))} LED`;
  body.appendChild(nameInput);
  body.appendChild(meta);

  // 右侧操作栏：应用 / 上移 / 下移 / 重命名 / 删除
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
  persistFaceDocuments("reorder_faces");
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
  persistFaceDocuments("delete_user_face");
  renderSavedFaces();
  log(`删除${faceTypeLabel(face.type)} #${i + 1}`);
}

// -----------------------------------------------------------------------------
// 表情部件组合器
// -----------------------------------------------------------------------------
// 连接关系：
// - initParts() 用 EXPRESSION_PARTS 生成 6.3 部件按钮。
// - selectPart()/randomParts() 改变 selectedCall。
// - composePartsFrame() 把 selectedCall 转成 partsFrame，再交给矩阵预览和固件队列。
// - 对称眼睛逻辑只改选择状态，不直接改 DOM；renderPartButtons() 负责显示同步。
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
  const _copyPartsM370 = () => {
    copyText(frameToM370(partsFrame));
    log("复制 M370");
  };
  $("parts-copy-m370").onclick = _copyPartsM370;
  $("parts-save-bottom").onclick = () =>
    saveFace(
      $("parts-name").value ||
        `parts_${selectedCall.leye}_${selectedCall.reye}_${selectedCall.mouth}_${selectedCall.cheek}`,
      partsFrame,
      "parts",
    );
  $("parts-import-m370").onclick = () => {
    try {
      setCurrentFrame(m370ToFrame($("parts-m370-text").value), "parts_m370_import", "idle");
      log("部件页 M370 文本已应用到当前输出");
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
    // cheek=400 表示明确的空脸颊调用，在随机模式中仍然有效。
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

// -----------------------------------------------------------------------------
// 文字滚动时间线
// -----------------------------------------------------------------------------
// 连接关系：
// - 输入框和 FPS 控件先清洗成 scroll.text/currentFps。
// - prepareTextScrollTimeline() 用 Ark 位图表生成 browser preview frames。
// - uploadFirmwareScrollTimeline() 把同一批 frames 分块发给 /api/scroll。
// - start/pause/resume/stop 同时维护本地 preview 状态和固件 playback 状态。
function truncateScrollText(text) {
  return Array.from(String(text ?? ""))
    .slice(0, MAX_SCROLL_TEXT_CHARS)
    .join("");
}

function sanitizeScrollTextInput(commit = false) {
  const el = $("scroll-text");
  const raw = el ? String(el.value ?? "") : "";
  const clean = truncateScrollText(raw);
  if (commit && el && raw !== clean) {
    el.value = clean;
    log(`滚动文字超过 ${MAX_SCROLL_TEXT_CHARS} 字，已自动截断。`);
  }
  return clean;
}

function autoResizeScrollTextInput() {
  const el = $("scroll-text");
  if (!el) return;
  el.style.height = "auto";
  const minHeight =
    parseFloat(getComputedStyle(el).getPropertyValue("--scroll-text-min-height")) || 42;
  el.style.height = Math.max(minHeight, el.scrollHeight + 2) + "px";
}

let scrollBitmapFontLazyStarted = false;
// 仅在实际使用文字滚动功能时，才延迟获取较大的 Ark Pixel 文字滚动资源
// （约 593KB 浏览器 woff2 + 约 1.8MB 位图字形表），
// 让约 2.4MB 资源避开启动/启动后瀑布流。底层两个加载器都会缓存
// 各自的承诺对象，因此重复调用（例如每次进入滚动页面）成本很低。
function ensureScrollFontsLoaded() {
  ensureTextScrollBrowserFontReady().then((loaded) => {
    if (loaded) autoResizeScrollTextInput();
  });
  if (scrollBitmapFontLazyStarted) return;
  scrollBitmapFontLazyStarted = true;
  ensureArkPixelFontReady()
    .then(() => log("Ark Pixel Font 12px bitmap table loaded"))
    .catch((err) => log(`Ark Pixel Font bitmap table load failed: ${err.message}`));
}

function initScroll() {
  applyTextScrollInputFont();
  autoResizeScrollTextInput();
  // 较大的 Ark Pixel 资源不会在这里随启动获取。它们会在
  // 首次进入文字滚动页面时延迟加载（见 switchPage -> ensureScrollFontsLoaded），
  // 而滚动启动路径也会等待 ensureArkPixelFontReady()，因此即使用户直接播放也安全。
  $("scroll-play").onclick = startScroll;
  $("scroll-pause").onclick = togglePauseScroll;
  $("scroll-stop").onclick = stopScroll;
  $("scroll-step").onclick = async () => {
    guardBeforeOutput("text_scroll_manual_step", "scroll");
    await prepareTextScrollTimelineAsync(false);
    advanceScroll(true);
    sendAuxCommand("scroll_step", {}, "text_scroll_manual_step");
  };
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

function restartScrollPreviewTimer() {
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  if (scroll.active && !scroll.paused) {
    scroll.timer = setInterval(() => advanceScroll(false), getScrollFrameIntervalMs());
  }
}

function setScrollFps(fps, source = "text_scroll_fps_change") {
  const clean = syncScrollFpsUi(fps);
  state.refreshPolicy = `text_scroll_${clean}fps_interval_${getScrollFrameIntervalMs()}ms`;
  restartScrollPreviewTimer();
  if (scroll.active || scroll.firmwareBacked || scroll.paused) {
    sendAuxCommand(
      "set_scroll_interval",
      {
        fps: clean,
        intervalMs: getScrollFrameIntervalMs(),
      },
      source,
    );
  }
  updateScrollUi();
  renderState();
}

function markScrollTextDirty() {
  scroll.dirty = true;
  scroll.signature = "";
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
  scroll.uploadProgress = clamp(progress, 0, 1);
  scroll.uploadLabel = label || "";
  updateScrollUi();
}

function completeScrollUploadProgress(label = "发送完成，滚动帧仅在固件 RAM 中运行") {
  scroll.uploadProgress = 1;
  scroll.uploadLabel = label;
  updateScrollUi();
  setTimeout(() => {
    if (!scroll.uploading && scroll.uploadProgress >= 1) {
      scroll.uploadProgress = 0;
      scroll.uploadLabel = "";
      updateScrollUi();
    }
  }, 1400);
}

function resetScrollUploadProgress() {
  scroll.uploadProgress = 0;
  scroll.uploadLabel = "";
  updateScrollUi();
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
  scroll.offset = 0;
  scroll.frameIndex = 0;
  state.textScrollActive = false;
  if (isScrollPlaybackValue(state.playback)) state.playback = "idle";
  state.lastRefreshReason = `${reason}_reset_scroll_ui`;
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
  const frames = [];
  for (let i = 0; i < source.length; i++) {
    frames.push(frameToM370(source[i]));
    if (i === 0 || i === source.length - 1 || i % 32 === 0) {
      onProgress((i + 1) / source.length);
      await nextUiFrame();
    }
  }
  return frames;
}
async function uploadFirmwareScrollTimeline() {
  setScrollUploadProgress(0.04, "准备滚动帧");
  const frames = await buildFirmwareScrollFrames((progress) => {
    setScrollUploadProgress(0.04 + progress * 0.3, `编码 ${Math.round(progress * 100)}%`);
  });
  if (!frames.length) throw new Error("no scroll frames");
  const totalChunks = Math.ceil(frames.length / SCROLL_UPLOAD_CHUNK_FRAMES);
  let data = null;
  setScrollUploadProgress(0.36, `分批上传到固件 RAM 0/${totalChunks}`);
  for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
    const start = chunkIndex * SCROLL_UPLOAD_CHUNK_FRAMES;
    const chunkFrames = frames.slice(start, start + SCROLL_UPLOAD_CHUNK_FRAMES);
    const isFirstChunk = chunkIndex === 0;
    data = await apiPostWithUploadProgress(
      API_ENDPOINTS.scroll,
      {
        frames: chunkFrames,
        stepLedPerFrame: 1,
        start: false,
        append: !isFirstChunk,
        chunkIndex,
        chunkFrames: chunkFrames.length,
        totalFrames: frames.length,
        source: "webui_text_scroll_frames_only",
        storage: "ram",
        persist: false,
        saveToFlash: false,
      },
      (progress) => {
        const chunkProgress = (chunkIndex + progress) / totalChunks;
        setScrollUploadProgress(
          0.36 + chunkProgress * 0.5,
          `分批上传到固件 RAM ${chunkIndex + 1}/${totalChunks}`,
        );
      },
    );
    await sleepMs(20);
  }

  const fps = getScrollFps();
  const intervalMs = Math.max(1, Math.round(1000 / fps));
  setScrollUploadProgress(0.9, `帧数据已完成，设置 ${fps} fps`);
  data = await apiPost(API_ENDPOINTS.command, {
    cmd: "start_scroll",
    payload: {
      fps,
      intervalMs,
      source: "webui_text_scroll_after_frames",
    },
  });
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
async function startScroll() {
  const text = sanitizeScrollTextInput(true);
  if (!text.trim()) {
    alert("空文本不进入文字滚动播放");
    return;
  }
  resetScrollUploadProgress();
  setScrollUploadProgress(0.02, "准备发送");
  try {
    await prepareTextScrollTimelineAsync(false);
  } catch (err) {
    resetScrollUploadProgress();
    return;
  }
  if (!scroll.frames.length) {
    resetScrollUploadProgress();
    alert("没有可播放的文字帧");
    return;
  }
  guardBeforeOutput("text_scroll_start", "scroll");
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  resetScrollPreviewToFirstFrame("text_scroll_start_reset_preview", "scroll");
  scroll.active = true;
  scroll.paused = false;
  scroll.userPaused = false;
  scroll.systemPaused = false;
  scroll.firmwareBacked = false;
  scroll.uploading = true;
  scroll.dirtyNoticeLogged = false;
  state.textScrollActive = true;
  state.playback = "scroll";
  state.refreshPolicy = `text_scroll_${getScrollFps()}fps_interval_${getScrollFrameIntervalMs()}ms`;
  scroll.fpsStarted = performance.now();
  scroll.frameCounter = 0;
  try {
    const data = await uploadFirmwareScrollTimeline();
    scroll.firmwareBacked = true;
    scroll.uploading = false;
    completeScrollUploadProgress("发送完成，滚动帧仅在固件 RAM 中运行");
    log(
      `文字滚动已上传到固件 RAM 并独立运行：${data?.frames || scroll.frames.length} 帧，${getScrollFps()} fps，每帧推进 1 LED；不会写入 saved_faces.json 或闪存。`,
    );
  } catch (err) {
    scroll.firmwareBacked = false;
    scroll.uploading = false;
    scroll.active = false;
    state.textScrollActive = false;
    state.playback = "idle";
    resetScrollUploadProgress();
    log(`文字滚动固件上传失败；已停止，未启用 WebUI 逐帧发送：${err.message}`);
    alert(`文字滚动上传失败：${err.message}`);
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

function togglePauseScroll() {
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
  if (scroll.userPaused) resumeScroll();
  else pauseScroll();
}

function pauseScroll() {
  if (!scroll.active && !state.textScrollActive && !scroll.firmwareBacked) {
    log("文字滚动未播放，无需暂停");
    updateScrollUi();
    renderState();
    return;
  }
  sendAuxCommand("pause_scroll", {}, "text_scroll_paused");
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
  scroll.userPaused = true;
  scroll.paused = true;
  scroll.active = false;
  state.textScrollActive = true;
  state.refreshPolicy = "dirty-frame / 按需刷新";
  state.playback = "scroll_paused";
  state.lastRefreshReason = "text_scroll_paused";
  log("文字滚动已暂停，固件停在当前帧；WebUI 不逐帧发送");
  updateScrollUi();
  renderState();
}

function resumeScroll() {
  if (!scroll.frames.length) {
    log("没有已生成/上传的文字滚动帧，改为重新发送并播放");
    startScroll();
    return;
  }
  sendAuxCommand("resume_scroll", {}, "text_scroll_resumed");
  scroll.userPaused = false;
  scroll.paused = !!scroll.systemPaused;
  scroll.active = !scroll.systemPaused;
  state.textScrollActive = true;
  state.playback = scroll.systemPaused ? "scroll_paused" : "scroll";
  state.refreshPolicy = `text_scroll_${getScrollFps()}fps_interval_${getScrollFrameIntervalMs()}ms`;
  state.lastRefreshReason = "text_scroll_resumed";
  scroll.fpsStarted = performance.now();
  scroll.frameCounter = 0;
  if (scroll.systemPaused) {
    if (scroll.timer) clearInterval(scroll.timer);
    scroll.timer = null;
  } else {
    restartScrollPreviewTimer();
  }
  log("文字滚动继续播放，固件从当前缓存继续运行");
  updateScrollUi();
  renderState();
}

function stopScroll() {
  const shouldRestoreAuto = state.restoreAutoAfterScroll || isAutoModeValue(state.mode);
  if (scroll.timer) clearInterval(scroll.timer);
  scroll.timer = null;
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
  scroll.dirty = true;
  state.textScrollActive = false;
  state.refreshPolicy = "dirty-frame / 按需刷新";
  scrollFrame = blankFrame();
  currentFrame = blankFrame();
  state.lastRefreshReason = "text_scroll_stopped_clear";
  state.playback = "idle";
  renderMatrices();
  updateM370Views();
  updateScrollUi();
  renderState();

  const didApplyDefault = applyStartupDefaultFaceLocal("text_scroll_stop_default_saved_face");
  state.playback = shouldRestoreAuto ? "auto_saved_face" : "idle";
  state.mode = shouldRestoreAuto ? "auto" : "manual";
  state.restoreAutoAfterScroll = false;
  sendAuxCommand(
    "stop_scroll",
    {
      clear: true,
      restoreAuto: shouldRestoreAuto,
    },
    "text_scroll_stopped_clear",
  );
  renderSavedFaces();
  updateScrollUi();
  renderState();
  log(
    shouldRestoreAuto
      ? `文字滚动停止/清屏，已清空并回到默认表情，返回 A 自动保存表情切换模式${didApplyDefault ? "，从默认表情开始循环" : ""}`
      : `文字滚动停止/清屏，已清空并回到默认表情，返回 M 手动保存表情模式${didApplyDefault ? "，保持不自动切换" : ""}`,
  );
}

function advanceScroll(manual = false) {
  prepareTextScrollTimeline(false);
  if (!scroll.frames.length) return;
  scroll.frameIndex = (scroll.frameIndex + 1) % scroll.frames.length;
  scroll.offset = scroll.frameIndex;
  scrollFrame = cloneFrame(scroll.frames[scroll.frameIndex]);
  setScrollPreviewFrame(
    scrollFrame,
    manual ? "text_scroll_manual_step_preview" : "text_scroll_firmware_preview",
    manual ? "scroll_step" : "scroll",
  );
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
  const source = buildTextScrollBitmap(text);
  const maxOffset = Math.max(1, source.width - COLS);
  const frames = [];
  for (let offset = 0; offset <= maxOffset; offset++) {
    const frame = extractFrameFromTextImage(source, offset);
    frames.push(frame);
  }
  scroll.frames = frames;
  scroll.signature = sig;
  scroll.dirty = false;
  scroll.frameIndex = Math.min(scroll.frameIndex, Math.max(0, frames.length - 1));
  scroll.offset = scroll.frameIndex;
  scrollFrame = cloneFrame(frames[scroll.frameIndex] || blankFrame());
  setScrollPreviewFrame(
    scrollFrame,
    "text_scroll_generated_m370_timeline",
    isScrollPlaybackValue(state.playback) ? "scroll" : "idle",
  );
  log(
    `文字滚动已生成：${frames.length} 帧，逐帧推进 1 LED，垂直居中偏移 ${textScrollVerticalOffset()} 行，约 ${((frames.length * 47) / 1024).toFixed(1)} KB packed`,
  );
  updateScrollUi();
}

function buildTextScrollBitmap(text) {
  const key = `${text}@@${TEXT_SCROLL_FONT_MODEL}@@${arkPixelFont.source}@@centerY${textScrollVerticalOffset()}`;
  if (buildTextScrollBitmap.cacheKey === key && buildTextScrollBitmap.cache)
    return buildTextScrollBitmap.cache;
  if (!arkPixelFont.ready) throw new Error("Ark Pixel Font bitmap table is not ready");
  const rawChars = Array.from(text || " ");
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
    // 防御性兜底：兼容可能仍是十六进制字符串的旧版压缩行。
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
  const glyph = {
    cp,
    char: ch,
    isSpace: false,
    advance: Math.max(1, Number(raw.advance) || arkPixelFont.defaultAdvance || width || 12),
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

function updateScrollUi() {
  const stateEl = $("scroll-state");
  const indexEl = $("scroll-frame-index");
  const pauseBtn = $("scroll-pause");
  const playBtn = $("scroll-play");
  const progressWrap = $("scroll-upload-progress");
  const progressBar = $("scroll-upload-bar");
  const progressLabel = $("scroll-upload-label");

  const firmwarePlaying =
    scroll.firmwareBacked || state.textScrollActive || isScrollPlaybackValue(state.playback);
  const label = scroll.uploading
    ? "uploading"
    : scroll.paused || state.playback === "scroll_paused"
      ? "paused"
      : scroll.active || state.playback === "scroll"
        ? "playing"
        : scroll.dirty
          ? "dirty/idle"
          : "idle";

  if (stateEl) stateEl.textContent = label;
  if (indexEl) indexEl.textContent = `${scroll.frameIndex || 0} / ${scroll.frames?.length || 0}`;
  if (pauseBtn) {
    const effectivePaused = scroll.paused || state.playback === "scroll_paused";
    const systemPauseOnly = scroll.systemPaused && !scroll.userPaused;
    const enabled = (firmwarePlaying || scroll.active || scroll.paused) && !systemPauseOnly;
    pauseBtn.disabled = !enabled;
    pauseBtn.setAttribute("aria-disabled", enabled ? "false" : "true");
    const isPaused = effectivePaused;
    pauseBtn.classList.toggle("active", !isPaused && enabled);
    pauseBtn.setAttribute("aria-pressed", !isPaused && enabled ? "true" : "false");
    pauseBtn.textContent = isPaused ? "继续" : "暂停";
  }
  if (playBtn) {
    playBtn.disabled = !!scroll.uploading;
    playBtn.textContent = scroll.uploading ? "发送中…" : "发送";
  }
  if (progressWrap) {
    const visible =
      !!scroll.uploading ||
      (scroll.uploadProgress > 0 && scroll.uploadProgress < 1.001) ||
      !!scroll.uploadLabel;
    progressWrap.hidden = !visible;
  }
  if (progressBar) progressBar.value = Math.round(clamp(scroll.uploadProgress || 0, 0, 1) * 100);
  if (progressLabel) progressLabel.textContent = scroll.uploadLabel || "等待发送";
}

// 矩阵预览共用同一条初始化路径，确保尺寸和渲染保持一致。
// -----------------------------------------------------------------------------
// 调试控件和延迟初始化
// -----------------------------------------------------------------------------
// 连接关系：
// - initializeMatrixViews() 必须在渲染前建立所有矩阵实例。
// - debug controls 只发送诊断命令或本地测试 frame，不改变页面结构。
// - deferred init 让首屏先显示，较重的列表/调试/字体读取在加载遮罩之后继续完成。
function initializeMatrixViews() {
  matrixViews = [];
  initMatrix("matrix-basic", () => currentFrame, false, null, false);
  initMatrix("matrix-custom-edit", () => editFrame, true, editCell, false);
  initMatrix("matrix-parts", () => partsFrame, false, null, false);
  initMatrix("matrix-scroll", () => scrollFrame, false, null, false);
  initMatrix("matrix-debug", () => currentFrame, false, null, false);
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

// 调试控件会发送诊断命令和本地测试图案。
function initializeDebugControls() {
  setClickHandlers([
    ["debug-all-off", () => setCurrentFrame(blankFrame(), "debug_all_off", "idle")],
    [
      "debug-all-on",
      () =>
        setCurrentFrame(
          blankFrame().map(() => true),
          "debug_all_on",
          "idle",
        ),
    ],
    ["debug-checker", () => setCurrentFrame(makePatternFrame("checker"), "debug_checker", "idle")],
    ["debug-border", () => setCurrentFrame(makePatternFrame("border"), "debug_border", "idle")],
    ["debug-current-face", () => applySavedFace(state.faceIndex, "debug_current_face")],
    [
      "debug-apply-m370",
      () => {
        try {
          setCurrentFrame(m370ToFrame($("debug-m370")?.value || ""), "debug_apply_m370", "idle");
        } catch (err) {
          alert(err.message);
        }
      },
    ],
    ["debug-copy-status", () => navigator.clipboard?.writeText(JSON.stringify(state, null, 2))],
    [
      "debug-reset-storage",
      () => {
        if (confirm("清空用户表情？默认 type:default 表情不会删除。")) {
          userFaces = [];
          persistFaceDocuments("debug_reset_user_faces");
          renderSavedFaces();
          renderState();
        }
      },
    ],
    ["debug-refresh-power", () => refreshPowerStatusFromFirmware("debug_refresh_power", true)],
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
      },
    ],
    [
      "serial-send",
      () => {
        const raw = $("serial-input")?.value || "{}";
        try {
          sendAuxCommand("manual_json", JSON.parse(raw), "debug_manual_json");
        } catch (err) {
          alert(`JSON 格式错误：${err.message}`);
        }
      },
    ],
    [
      "log-clear",
      () => {
        logs = [];
        renderLog();
      },
    ],
    ["log-download", () => downloadJsonFile("rina_webui_log.txt", logs.join("\n"))],
    ["firmware-ping", () => syncRuntimeStateFromFirmware("firmware_ping")],
    ["firmware-pause", () => sendAuxCommand("pause_scroll", {}, "debug_firmware_pause")],
  ]);
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
    if (shouldLogApiError()) log(`延后读取 saved_faces.json 失败：${err.message}`);
  }

  const matrixSynced = await syncRuntimeStateFromFirmware("post_load_matrix_preview");
  if (!matrixSynced && getAllFaces().length && !bootPlaybackIsScroll) {
    if (bootOk) applyKnownFaceIndexLocal("post_load_face_index_fallback");
    else applyStartupDefaultFaceLocal("post_load_default_face_fallback");
  }
  renderSavedFaces();
  renderMatrices();
  renderState();
  scheduleMatrixFitRender(3);

  // 关键启动读取（运行时状态 + saved_faces + 预览）完成后，且加载动画仍在屏幕上时，
  // 在后台预热文字滚动浏览器字体（ark12.woff2，约 593KB）。这样文字滚动页面
  // 会提前拥有字体，用户打开后就不会再过几秒才替换字体。
  // 它会在关键读取之后启动，避免与这些读取竞争单线程 ESP Web 服务器。
  // 较大的 1.8MB ark12.json 位图字形表仍保持延迟加载，首次进入文字滚动页面时加载；见 switchPage。
  ensureTextScrollBrowserFontReady().catch(() => {});
}

// -----------------------------------------------------------------------------
// 应用启动
// -----------------------------------------------------------------------------
// 连接关系：
// - bootstrapWebUi() 是唯一启动入口：先字体和基础 UI，再首屏揭示，再固件同步。
// - 它调用前面所有模块的 init/render 函数，但模块本身不应反向调用 bootstrap。
// - 启动失败会写入日志和状态，不阻塞用户查看本地 UI。
async function bootstrapWebUi() {
  const bootStart = performance.now();
  let bootOk = false;
  try {
    if (window.rinaStartLoaderAnimation) await window.rinaStartLoaderAnimation();
    prepareFirstPageProgressiveReveal();
    // UI 字体（GNU Unifont，内嵌 data URI）必须在第 4 阶段
    // 瀑布揭示前完全就绪，这样首屏揭示时就已经显示正确字体。
    // 它是内嵌的（无网络请求），因此这个 await 很快。ark12 滚动字体保持
    // 延后，并在第 4 阶段之后通过 initScroll 加载。
    await ensureWebUiFontReady().catch((err) => console.warn("WebUI font bootstrap failed", err));
    initFirstPageUiBeforeShow();
    initializeBasicPreviewMatrix();
    renderFirstPageUiBeforeShow();
    showBootUiBehindLoader();
    await new Promise((resolve) => requestAnimationFrame(resolve));
    const firstPageRevealPromise = revealFirstPageWaterfall();

    // 先处理第 4 阶段：等待首屏瀑布揭示完成。
    await firstPageRevealPromise;

    // 在最短显示窗口开始时启动固件启动读取（现在包含第一帧 LED），
    // 让它与原本空闲的等待时间重叠。第一帧矩阵 + 运行时状态会在
    // 加载动画仍显示时应用，因此加载器关闭/揭示页面时，
    // 基础矩阵预览已经填充完成，同时不会让关闭过程等待网络。
    const runtimePingPromise = preloadFirmwareRuntimeState()
      .then(() => {
        bootOk = !!bootRuntimeSnapshot.ok;
        applyBrightnessLocal(state.brightness);
        syncAutoIntervalUi();
        updateM370Views();
        updateScrollUi();
        setFirmwareStatus({
          savedFacesSync: "deferred until WebUI ready",
        });
        renderSavedFaces();
        renderMatrices();
        renderState();
        fitAllMatrices();
      })
      .catch((err) => {
        if (shouldLogApiError()) log(`runtime 状态读取失败：${err.message || err}`);
      });

    await waitForBootLoaderMinimum(bootStart);
    await new Promise((resolve) => requestAnimationFrame(resolve));

    finishBootVisibility();
    scheduleMatrixFitRender(4);
    initDeferredUiAfterShow();

    // 确保运行时快照（以及 bootOk）先稳定下来，
    // 再启动依赖它的延迟读取和状态轮询。
    await runtimePingPromise;

    startFirmwareStatusPolling();
    startPowerStatusPolling();
    runPostBootDeferredReads(bootOk).catch((err) => {
      if (shouldLogApiError()) log(`延后读取 saved_faces/预览矩阵失败：${err.message}`);
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
    runPostBootDeferredReads(bootOk).catch(() => {});
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", bootstrapWebUi, {
    once: true,
  });
} else {
  bootstrapWebUi();
}
