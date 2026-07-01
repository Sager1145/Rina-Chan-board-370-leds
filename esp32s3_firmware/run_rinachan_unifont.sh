#!/usr/bin/env bash
# run_rinachan_unifont.ps1 的 macOS 移植版本。
# 准备/校验融合后的 Ark12 字体资源（单个合并的 ark12.woff2，
# 含回退 CJK 字形 + Mona12 emoji）、内嵌的 GNU Unifont WebUI
# 子集，gzip 压缩 Web 资源，并通过 PlatformIO 构建/上传固件 + LittleFS。
#
# 用法（Usage）：
#   ./run_rinachan_unifont.sh                     # 准备 + 校验 + pio 构建
#   ./run_rinachan_unifont.sh --upload-firmware   # 同时烧录固件
#   ./run_rinachan_unifont.sh --upload-fs         # 同时上传 LittleFS 镜像
#   ./run_rinachan_unifont.sh --skip-prepare-fonts
#   ./run_rinachan_unifont.sh --no-download       # 缺失时直接失败而非下载
#   ./run_rinachan_unifont.sh --check-only        # 仅执行校验，不调用 pio
#   ./run_rinachan_unifont.sh --env esp32s3       # 指定 env（默认 esp32s3-rmt-dma）
#   ./run_rinachan_unifont.sh --upload-firmware --monitor   # 烧录后用同一 env 监视串口
#   ./run_rinachan_unifont.sh --monitor-baud 115200
#   ./run_rinachan_unifont.sh --version v1        # 把 WebUI/config.h 里的 "V2" 改成 "V1"（默认 v2）
#
# 默认 env = esp32s3-rmt-dma（抗 Wi-Fi 乱码后端）。基线 Adafruit 后端用 --env esp32s3。
# --version v1|v2：在构建/上传前切换版本标识（v2 = 当前实现）。
# 兼容 macOS 自带的 bash 3.2。

set -u

UPLOAD_FIRMWARE=0
UPLOAD_FS=0
SKIP_PREPARE_FONTS=0
NO_DOWNLOAD=0
CHECK_ONLY=0
UNIFONT_VERSION="17.0.04"
# 中文块：UI/固件版本标识。v2 = 当前实现（默认）；v1 = 把 index.html / app.js /
# config.h 里所有 "V2" 文案改成 "V1" 再构建/上传。用 --version v2 可改回。
VERSION="v2"
# 中文块：默认 PlatformIO 环境 esp32s3-rmt-dma —— 带 RMT+DMA / IRAM 编码器 /
# ISR 钉 Core 1 / 整帧 DMA 缓冲的抗 Wi-Fi 乱码后端。基线后端是 "esp32s3"(Adafruit,
# 仅对比用)。--monitor 上传后用同一 env 打开串口监视，避免看错固件。
ENVIRONMENT="esp32s3-rmt-dma"
MONITOR=0
MONITOR_BAUD=115200

while [ $# -gt 0 ]; do
    case "$1" in
        --upload-firmware) UPLOAD_FIRMWARE=1 ;;
        --upload-fs) UPLOAD_FS=1 ;;
        --skip-prepare-fonts) SKIP_PREPARE_FONTS=1 ;;
        --no-download) NO_DOWNLOAD=1 ;;
        --check-only) CHECK_ONLY=1 ;;
        --env) shift; ENVIRONMENT="$1" ;;
        --monitor) MONITOR=1 ;;
        --monitor-baud) shift; MONITOR_BAUD="$1" ;;
        --unifont-version) shift; UNIFONT_VERSION="$1" ;;
        --version) shift; VERSION="$1" ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "[error] unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$VERSION" in
    v1|v2) ;;
    *) echo "[error] invalid --version '$VERSION' (use v1 or v2)" >&2; exit 2 ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$PROJECT_DIR/data"
FONT_DIR="$DATA_DIR/resources/fonts"
CACHE_DIR="$PROJECT_DIR/.font_cache"
INDEX_HTML="$DATA_DIR/index.html"
STYLES_CSS="$DATA_DIR/styles.css"
APP_JS="$DATA_DIR/app.js"
ARK_JSON="$FONT_DIR/ark12.json"
ARK_WOFF2="$FONT_DIR/ark12.woff2"

step() { echo "[run] $*"; }
fontmsg() { echo "[font] $*"; }
die() { echo "[error] $*" >&2; exit 1; }

# 中文块：apply_version_label 在 V1/V2 之间切换 WebUI 与固件里的版本标识。
# v2 = 当前实现；v1 = 把 index.html / app.js / config.h 里所有 "V2" 改成 "V1"。
# 这些文件只含其中一种标识（无杂散 V1/V2），所以替换安全且幂等。
apply_version_label() {
    local target="$1" from to f
    if [ "$target" = "v1" ]; then from="V2"; to="V1"; else from="V1"; to="V2"; fi
    step "version label = $target (replacing '$from' -> '$to' in WebUI + config.h)."
    for f in "$INDEX_HTML" "$APP_JS" "$PROJECT_DIR/src/config.h"; do
        [ -f "$f" ] || continue
        if grep -q "$from" "$f"; then
            perl -i -pe "s/\Q$from\E/$to/g" "$f" || die "version label rewrite failed for $f"
            echo "[version] updated $(basename "$f")"
        fi
    done
}

[ -f "$PROJECT_DIR/platformio.ini" ] || die "run this script from inside the esp32s3_firmware project folder."
[ -f "$INDEX_HTML" ] && [ -f "$STYLES_CSS" ] && [ -f "$PROJECT_DIR/src/main.cpp" ] || \
    die "project files missing; run from the esp32s3_firmware folder."

step "project root: $PROJECT_DIR"

# ---------------------------------------------------------------------------
# Python 检测 + 字体构建模块
# ---------------------------------------------------------------------------
PYTHON=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then
        if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' >/dev/null 2>&1; then
            PYTHON="$cand"; break
        fi
    fi
done
[ -n "$PYTHON" ] || die "Python 3 was not found. Install it (e.g. 'brew install python') and re-run."

ensure_python_font_modules() {
    if "$PYTHON" -c 'import PIL, fontTools, brotli' >/dev/null 2>&1; then
        fontmsg "Python font build modules are present."
        return 0
    fi
    if [ "$NO_DOWNLOAD" = "1" ]; then
        die "Python font build modules missing and --no-download given. Required pip packages: pillow fonttools brotli"
    fi
    fontmsg "installing Python font build modules: pillow fonttools brotli"
    "$PYTHON" -m pip install --user --upgrade pillow fonttools brotli || \
        "$PYTHON" -m pip install --user --upgrade --break-system-packages pillow fonttools brotli || \
        die "failed to install Python font build modules."
    "$PYTHON" -c 'import PIL, fontTools, brotli' >/dev/null 2>&1 || \
        die "Python font build modules are still missing after pip install."
}

download_if_missing() {
    # $1=url $2=path $3=label（$1=下载地址 $2=保存路径 $3=标签）
    if [ -f "$2" ]; then
        fontmsg "$3 exists: $2"
        return 0
    fi
    [ "$NO_DOWNLOAD" = "1" ] && die "$3 is missing and --no-download was specified: $2"
    fontmsg "downloading $3..."
    mkdir -p "$(dirname "$2")"
    if ! curl -fsSL -o "$2" "$1"; then
        rm -f "$2"
        die "failed to download $3 from $1"
    fi
}

# ---------------------------------------------------------------------------
# 校验辅助函数（与 PowerShell 脚本执行相同的检查）
# ---------------------------------------------------------------------------
test_merged_ark12_json() {
    # 融合校验：本项目随附经过修补的 Ark12 JSON（>=32000 个字形，
    # 含 然/燃/滚/滾 + Mona12 emoji），而非原始的 24,408 字形 Ark 字表。
    "$PYTHON" - "$ARK_JSON" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    assert d.get("format") == "rina_ark_pixel_font_bitmap_v1"
    assert int(d["rows"]) == 12 and int(d["lineHeight"]) == 12
    assert int(d["defaultAdvance"]) == 12
    mp = d["mergePolicy"]
    assert ",".join(mp["priorityLowToHigh"]) == "zh_cn,ja,zh_tw"
    assert mp["conflictAuthority"] == "zh_tw"
    g = d["glyphs"]
    assert len(g) >= 32000
    for cp in ("7136", "71C3", "6EDA", "6EFE"):
        e = g[cp]
        assert len(e) >= 7 and int(e[1]) == 12 and len(str(e[6]).split("/")) == 12
except Exception as exc:
    print(f"ark12.json validation failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
PYEOF
}

assert_standalone_unifont_webui() {
    "$PYTHON" - "$INDEX_HTML" "$STYLES_CSS" "$PROJECT_DIR" <<'PYEOF'
import hashlib, pathlib, re, sys
index_path = pathlib.Path(sys.argv[1]); css_path = pathlib.Path(sys.argv[2])
project_dir = pathlib.Path(sys.argv[3])
html = index_path.read_text(encoding="utf-8"); css = css_path.read_text(encoding="utf-8")
block_re = re.compile(r"@font-face\s*\{(?=[^{}]*font-family\s*:\s*['\"]GNU Unifont['\"])[^{}]*\}", re.S)
blocks = block_re.findall(css)
if len(blocks) != 1:
    print(f"expected exactly one GNU Unifont @font-face block, found {len(blocks)}"); raise SystemExit(1)
block = blocks[0]
# 新契约：独立文件，不再内嵌 base64 data URI。
if "data:font/woff2;base64," in block:
    print("GNU Unifont @font-face must NOT embed a base64 data URL anymore"); raise SystemExit(1)
if not re.search(r"url\(\s*['\"]?/resources/fonts/unifont\.woff2", block):
    print("GNU Unifont @font-face must reference /resources/fonts/unifont.woff2 via url()"); raise SystemExit(1)
font_path = project_dir/"data"/"resources"/"fonts"/"unifont.woff2"
if not font_path.exists():
    print(f"standalone WebUI Unifont resource is missing: {font_path}"); raise SystemExit(1)
data = font_path.read_bytes()
if data[:4] != b"wOF2":
    print("standalone unifont.woff2 is not a valid WOFF2 (bad magic)"); raise SystemExit(1)
if len(data) < 10000:
    print(f"standalone GNU Unifont is suspiciously small: {len(data)} bytes"); raise SystemExit(1)
compact_css = re.sub(r"\s+", "", css)
link_re = re.compile(r"<link\b(?=[^>]*\brel=['\"]stylesheet['\"])(?=[^>]*\bhref=['\"]styles\.css(?:\?[^'\"]*)?['\"])[^>]*>", re.I)
if not link_re.search(html):
    print("index.html does not link styles.css"); raise SystemExit(1)
# 必须在 index.html 里 preload 独立 unifont，确保它最先加载。
preload_re = re.compile(r"<link\b(?=[^>]*\brel=['\"]preload['\"])(?=[^>]*\bas=['\"]font['\"])(?=[^>]*href=['\"][^'\"]*?/resources/fonts/unifont\.woff2)[^>]*>", re.I)
if not preload_re.search(html):
    print("index.html must <link rel=preload as=font> the standalone unifont.woff2"); raise SystemExit(1)
if '--ui-font:"GNUUnifont"' not in compact_css:
    print('CSS variable --ui-font is not pinned to "GNU Unifont"'); raise SystemExit(1)
print(hashlib.sha256(data).hexdigest())
PYEOF
}

assert_required_font_resources() {
    local missing=0
    for f in "$ARK_WOFF2" "$ARK_JSON"; do
        if [ ! -f "$f" ]; then
            fontmsg "missing required LittleFS font resource: $f"
            missing=1
        fi
    done
    [ "$missing" = "0" ] || die "required font resources are missing. Re-run without --skip-prepare-fonts before uploadfs."
    test_merged_ark12_json || die "fused Ark12 JSON validation failed (needs 然/燃/滚/滾 + >=32000 glyphs). Re-run without --skip-prepare-fonts."
    ensure_python_font_modules
    "$PYTHON" "$PROJECT_DIR/tools/sync_ark12_css_glyphs.py" --project-dir "$PROJECT_DIR" || \
        die "Ark12 CSS glyph fusion validation failed. Re-run without --skip-prepare-fonts."
    local sha
    sha="$(assert_standalone_unifont_webui)" || die "standalone GNU Unifont WebUI validation failed."
    fontmsg "standalone GNU Unifont validated sha256=$sha"
    fontmsg "required LittleFS font resources are present (merged ark12.woff2; standalone unifont.woff2 referenced by styles.css and preloaded by index.html)."
}

assert_littlefs_name_lengths() {
    local toolong
    toolong="$(find "$DATA_DIR" -name '.*' -prune -o -print | awk -F/ 'length($NF) > 31 {print}')"
    if [ -n "$toolong" ]; then
        echo "[littlefs] names longer than 31 characters may fail in mklittlefs:" >&2
        echo "$toolong" >&2
        die "rename the listed LittleFS files/directories to 31 characters or fewer before uploadfs."
    fi
    echo "[littlefs] all LittleFS file/directory names are <= 31 characters."
}

# ---------------------------------------------------------------------------
# 字体准备（对应 PowerShell 中的 Prepare-FontResources）
# ---------------------------------------------------------------------------
remove_legacy_font_resources() {
    local old_prefix="u8g2"
    local legacy
    for legacy in \
        "${old_prefix}_16.woff2" \
        "rina_${old_prefix}_16_webui_20260511.woff2" \
        "rina_${old_prefix}_16_webui_20260511.ttf" \
        "ark-pixel-font-12px-monospaced.otf.woff2" \
        "ark-pixel-font-12px-monospaced.rinafont.json" \
        "ark12_merged_trad_priority.json" \
        "ark12_merged_trad_priority_report.txt" \
        "gnu_unifont_17_0_04_webui_subset.woff2" \
        "ark12_fallback.woff2"; do
        # 注意：unifont.woff2 现在是独立 WebUI 字体资源，由 build_and_embed_unifont_webfont
        # 生成并被 styles.css 引用，绝不能当作 legacy 删除。
        if [ -f "$FONT_DIR/$legacy" ]; then
            fontmsg "removing redundant font resource: $FONT_DIR/$legacy"
            rm -f "$FONT_DIR/$legacy"
        fi
    done
}

build_and_embed_unifont_webfont() {
    ensure_python_font_modules
    local png="$CACHE_DIR/unifont-$UNIFONT_VERSION.png"
    local url="https://ftp.gnu.org/gnu/unifont/unifont-$UNIFONT_VERSION/unifont-$UNIFONT_VERSION.png"
    local tool="$PROJECT_DIR/tools/build_unifont_webui_subset_from_png.py"
    local out_font="$FONT_DIR/unifont.woff2"
    local href="/resources/fonts/unifont.woff2?v=$UNIFONT_VERSION-webui-2"
    [ -f "$tool" ] || die "missing GNU Unifont WebUI subset build tool: $tool"
    download_if_missing "$url" "$png" "GNU Unifont $UNIFONT_VERSION BMP PNG sheet"
    fontmsg "building standalone WebUI GNU Unifont subset -> $out_font (referenced by styles.css)..."
    mkdir -p "$FONT_DIR"
    "$PYTHON" "$tool" \
        --png "$png" --out "$out_font" --version "$UNIFONT_VERSION" \
        --external-css "$STYLES_CSS" \
        --external-href "$href" \
        --text-file "$INDEX_HTML" \
        --text-file "$STYLES_CSS" \
        --text-file "$APP_JS" \
        --text-file "$DATA_DIR/resources/saved_faces.json" \
        --text-file "$DATA_DIR/resources/runtime_settings.json" \
        --text-file "$DATA_DIR/resources/battery_calib.json" \
        || die "GNU Unifont WebUI subset build failed."
    [ -f "$out_font" ] || die "standalone GNU Unifont WebUI subset was not generated: $out_font"
    local size
    size=$(wc -c < "$out_font" | tr -d ' ')
    [ "$size" -ge 10000 ] || die "generated GNU Unifont WebUI subset is suspiciously small: $size bytes"
    fontmsg "wrote standalone LittleFS unifont.woff2 ($size bytes); styles.css references it via url()."
}

# 中文：data/resources/fonts/ 是唯一字体资源来源（旧 tools/font_fusion 镜像已
# 移除）。此处只做校验；重新生成资源请用 tools/merge_mona12_emoji.py /
# tools/build_ark12_merged.py。
sync_ark12_fusion_resources() {
    local tool="$PROJECT_DIR/tools/sync_ark12_css_glyphs.py"
    [ -f "$tool" ] || die "missing Ark12 CSS glyph sync tool: $tool"
    rm -f "$FONT_DIR/ark12_fallback.woff2"
    "$PYTHON" "$tool" --project-dir "$PROJECT_DIR" || \
        die "Ark12 CSS glyph fusion validation failed."
    ls -l "$ARK_WOFF2" "$ARK_JSON" 2>/dev/null || true
}

prepare_font_resources() {
    mkdir -p "$FONT_DIR" "$CACHE_DIR"
    remove_legacy_font_resources
    build_and_embed_unifont_webfont
    fontmsg "validating fused Ark12 glyph resources."
    sync_ark12_fusion_resources
}

# ---------------------------------------------------------------------------
# Gzip 压缩 Web 资源（为 LittleFS 镜像生成，之后再删除）
# ---------------------------------------------------------------------------
WEB_ASSETS="$INDEX_HTML
$APP_JS
$STYLES_CSS
$ARK_JSON"

sync_web_asset_gzip_files() {
    echo "$WEB_ASSETS" | while IFS= read -r src; do
        [ -n "$src" ] || continue
        "$PYTHON" - "$src" <<'PYEOF' || exit 1
import gzip, pathlib, shutil, sys
src = pathlib.Path(sys.argv[1])
if not src.exists():
    print(f"missing web asset: {src}"); raise SystemExit(1)
dst = src.with_name(src.name + ".gz")
with src.open("rb") as fin, gzip.GzipFile(filename="", mode="wb", fileobj=dst.open("wb"), mtime=0) as fout:
    shutil.copyfileobj(fin, fout)
raw = src.read_bytes()
if gzip.decompress(dst.read_bytes()) != raw:
    print(f"gzip verification failed: {src}"); raise SystemExit(1)
print(f"gzipped {src.name} -> {dst.name} ({len(raw)} bytes)")
PYEOF
    done || die "failed to synchronize gzip web assets."
}

remove_web_asset_gzip_files() {
    local removed=0
    echo "$WEB_ASSETS" | while IFS= read -r src; do
        [ -n "$src" ] && [ -f "$src.gz" ] && rm -f "$src.gz" && echo "[gzip] removed ${src#$DATA_DIR/}.gz"
    done
    return 0
}

# ---------------------------------------------------------------------------
# PlatformIO
# ---------------------------------------------------------------------------
find_pio() {
    if command -v pio >/dev/null 2>&1; then echo "pio"; return 0; fi
    if [ -x "$HOME/.platformio/penv/bin/pio" ]; then echo "$HOME/.platformio/penv/bin/pio"; return 0; fi
    return 1
}

# ---------------------------------------------------------------------------
# 主流程（对应 PowerShell 脚本）
# ---------------------------------------------------------------------------
apply_version_label "$VERSION"

if [ "$SKIP_PREPARE_FONTS" = "0" ]; then
    prepare_font_resources
else
    step "skipping font preparation by request."
fi

assert_required_font_resources
assert_littlefs_name_lengths

if [ "$CHECK_ONLY" = "1" ]; then
    step "check-only mode: all validations passed; skipping PlatformIO."
    exit 0
fi

PIO="$(find_pio)" || die "PlatformIO 'pio' not found. Install with: brew install platformio  (or: pipx install platformio)"

cd "$PROJECT_DIR" || die "cannot cd to project dir"
trap remove_web_asset_gzip_files EXIT

step "PlatformIO environment: $ENVIRONMENT"
if [ "$UPLOAD_FIRMWARE" = "1" ]; then
    step "uploading firmware and partition table (env=$ENVIRONMENT)..."
    "$PIO" run -e "$ENVIRONMENT" -t upload || die "firmware upload failed."
fi
if [ "$UPLOAD_FS" = "1" ]; then
    sync_web_asset_gzip_files
    step "uploading LittleFS (env=$ENVIRONMENT)..."
    "$PIO" run -e "$ENVIRONMENT" -t uploadfs || die "LittleFS upload failed."
fi
if [ "$UPLOAD_FIRMWARE" = "0" ] && [ "$UPLOAD_FS" = "0" ]; then
    step "no upload switch supplied; running PlatformIO build only (env=$ENVIRONMENT)..."
    "$PIO" run -e "$ENVIRONMENT" || die "PlatformIO build failed."
    step "build complete. Use --upload-firmware and/or --upload-fs to upload."
fi
if [ "$MONITOR" = "1" ]; then
    # 中文块：用同一 env 打开串口监视，避免“烧 rmt-dma 却监视 esp32s3”看错固件。
    # 启动日志应出现：LEDDRV event=begin backend=rmt-dma dma=1 isr_core=1 whole_frame=1
    step "opening serial monitor (env=$ENVIRONMENT baud=$MONITOR_BAUD). Ctrl+C to quit."
    "$PIO" device monitor -e "$ENVIRONMENT" -b "$MONITOR_BAUD"
fi
