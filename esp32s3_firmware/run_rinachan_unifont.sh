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
#
# 兼容 macOS 自带的 bash 3.2。

set -u

UPLOAD_FIRMWARE=0
UPLOAD_FS=0
SKIP_PREPARE_FONTS=0
NO_DOWNLOAD=0
CHECK_ONLY=0
UNIFONT_VERSION="17.0.04"

while [ $# -gt 0 ]; do
    case "$1" in
        --upload-firmware) UPLOAD_FIRMWARE=1 ;;
        --upload-fs) UPLOAD_FS=1 ;;
        --skip-prepare-fonts) SKIP_PREPARE_FONTS=1 ;;
        --no-download) NO_DOWNLOAD=1 ;;
        --check-only) CHECK_ONLY=1 ;;
        --unifont-version) shift; UNIFONT_VERSION="$1" ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "[error] unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$PROJECT_DIR/data"
FONT_DIR="$DATA_DIR/resources/fonts"
CACHE_DIR="$PROJECT_DIR/.font_cache"
INDEX_HTML="$DATA_DIR/index.html"
STYLES_CSS="$DATA_DIR/styles.css"
APP_JS="$DATA_DIR/app.js"
ARK_JSON="$FONT_DIR/ark12.json"
ARK_WOFF2="$FONT_DIR/ark12.woff2"
FUSION_DIR="$PROJECT_DIR/tools/font_fusion"

step() { echo "[run] $*"; }
fontmsg() { echo "[font] $*"; }
die() { echo "[error] $*" >&2; exit 1; }

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

assert_embedded_unifont_webui() {
    "$PYTHON" - "$INDEX_HTML" "$STYLES_CSS" "$PROJECT_DIR" <<'PYEOF'
import base64, hashlib, pathlib, re, sys
index_path = pathlib.Path(sys.argv[1]); css_path = pathlib.Path(sys.argv[2])
project_dir = pathlib.Path(sys.argv[3])
html = index_path.read_text(encoding="utf-8"); css = css_path.read_text(encoding="utf-8")
block_re = re.compile(r"@font-face\s*\{(?=[^{}]*font-family\s*:\s*['\"]GNU Unifont['\"])[^{}]*\}", re.S)
blocks = block_re.findall(css)
if len(blocks) != 1:
    print(f"expected exactly one GNU Unifont @font-face block, found {len(blocks)}"); raise SystemExit(1)
block = blocks[0]
for token in ("local(", "resources/fonts/unifont.woff2", "/resources/fonts/unifont.woff2", "unifont.woff2"):
    if token in block:
        print(f"GNU Unifont @font-face references forbidden non-embedded source: {token}"); raise SystemExit(1)
match = re.search(r"data:font/woff2;base64,([^\")]+)", block)
if not match:
    print("GNU Unifont @font-face does not contain an embedded WOFF2 data URL"); raise SystemExit(1)
embedded = base64.b64decode(match.group(1), validate=True)
if len(embedded) < 10000:
    print(f"embedded GNU Unifont is suspiciously small: {len(embedded)} bytes"); raise SystemExit(1)
for path in [project_dir/"data"/"resources"/"fonts"/"unifont.woff2",
             project_dir/"data"/"resources"/"fonts"/"gnu_unifont_17_0_04_webui_subset.woff2"]:
    if path.exists():
        print(f"forbidden external WebUI Unifont resource still exists: {path}"); raise SystemExit(1)
compact_css = re.sub(r"\s+", "", css)
link_re = re.compile(r"<link\b(?=[^>]*\brel=['\"]stylesheet['\"])(?=[^>]*\bhref=['\"]styles\.css(?:\?[^'\"]*)?['\"])[^>]*>", re.I)
if not link_re.search(html):
    print("index.html does not link styles.css"); raise SystemExit(1)
if '--ui-font:"GNUUnifont"' not in compact_css:
    print('CSS variable --ui-font is not pinned to "GNU Unifont"'); raise SystemExit(1)
print(hashlib.sha256(embedded).hexdigest())
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
    local sha
    sha="$(assert_embedded_unifont_webui)" || die "embedded-only GNU Unifont WebUI validation failed."
    fontmsg "embedded-only GNU Unifont validated sha256=$sha"
    fontmsg "required LittleFS font resources are present (single merged ark12.woff2; WebUI Unifont embedded in styles.css)."
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
        "unifont.woff2" \
        "ark12_fallback.woff2"; do
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
    local tmp_font="$CACHE_DIR/unifont_webui_embedded_tmp.woff2"
    [ -f "$tool" ] || die "missing GNU Unifont WebUI subset build tool: $tool"
    download_if_missing "$url" "$png" "GNU Unifont $UNIFONT_VERSION BMP PNG sheet"
    fontmsg "building and embedding WebUI GNU Unifont subset into styles.css..."
    "$PYTHON" "$tool" \
        --png "$png" --out "$tmp_font" --version "$UNIFONT_VERSION" \
        --embed-index "$STYLES_CSS" \
        --text-file "$INDEX_HTML" \
        --text-file "$STYLES_CSS" \
        --text-file "$APP_JS" \
        --text-file "$DATA_DIR/resources/saved_faces.json" \
        --text-file "$DATA_DIR/resources/runtime_settings.json" \
        --text-file "$DATA_DIR/resources/battery_calib.json" \
        || die "GNU Unifont WebUI subset build/embed failed."
    [ -f "$tmp_font" ] || die "temporary GNU Unifont WebUI subset was not generated: $tmp_font"
    local size
    size=$(wc -c < "$tmp_font" | tr -d ' ')
    [ "$size" -ge 10000 ] || die "generated GNU Unifont WebUI subset is suspiciously small: $size bytes"
    rm -f "$tmp_font"
    rm -f "$FONT_DIR/unifont.woff2"
    fontmsg "embedded WebUI GNU Unifont subset into styles.css; no LittleFS unifont.woff2 is kept."
}

install_bundled_ark12_fusion_resources() {
    local bundled_json="$FUSION_DIR/ark12_fusion.json"
    local bundled_woff2="$FUSION_DIR/ark12_base.woff2"
    local f
    for f in "$bundled_json" "$bundled_woff2"; do
        [ -f "$f" ] || die "bundled Ark12 fusion resource is missing: $f"
    done
    cp -f "$bundled_json" "$ARK_JSON"
    cp -f "$bundled_woff2" "$ARK_WOFF2"
    # 融合后的回退层 + Mona12 emoji 已合并进（INTO）ark12.woff2。
    rm -f "$FONT_DIR/ark12_fallback.woff2"
    test_merged_ark12_json || die "bundled Ark12 fusion JSON validation failed after copy."
    fontmsg "installed bundled Ark12 fusion resources (single merged woff2 incl. 然 / 燃 / 滚 / 滾 + Mona12 emoji)."
}

prepare_font_resources() {
    mkdir -p "$FONT_DIR" "$CACHE_DIR"
    remove_legacy_font_resources
    build_and_embed_unifont_webfont
    if [ -f "$ARK_WOFF2" ] && test_merged_ark12_json; then
        fontmsg "existing fused Ark12 text-scroll resources found; no rebuild required."
        ls -l "$ARK_WOFF2" "$ARK_JSON" 2>/dev/null || true
        return 0
    fi
    fontmsg "fused Ark12 resources are missing or stale; installing bundled fusion files."
    install_bundled_ark12_fusion_resources
    ls -l "$ARK_WOFF2" "$ARK_JSON" 2>/dev/null || true
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

if [ "$UPLOAD_FIRMWARE" = "1" ]; then
    step "uploading firmware and partition table..."
    "$PIO" run -t upload || die "firmware upload failed."
fi
if [ "$UPLOAD_FS" = "1" ]; then
    sync_web_asset_gzip_files
    step "uploading LittleFS..."
    "$PIO" run -t uploadfs || die "LittleFS upload failed."
fi
if [ "$UPLOAD_FIRMWARE" = "0" ] && [ "$UPLOAD_FS" = "0" ]; then
    step "no upload switch supplied; running PlatformIO build only..."
    "$PIO" run || die "PlatformIO build failed."
    step "build complete. Use --upload-firmware and/or --upload-fs to upload."
fi
