// F5 (BLOB transactions) + F7 (boundaries) through the REAL protocol.cpp,
// scroll_session.cpp, storage.cpp and faces.cpp with a temp-dir fake LittleFS.
// Build: test/host/stress_build.sh test/host/stress_f5_f7_blob.cpp /tmp/f5 asan && /tmp/f5 <fsroot>
#include "../../src/protocol.cpp"
#include "stress_common.h"

static CaseLog L;
static FakeTransport T(rinalink::Carrier::Tcp);
static std::string gRoot;
static uint8_t gSeq = 1;
static uint8_t nextSeq() { if (++gSeq == 0) gSeq = 1; return gSeq; }

struct Rep { uint8_t type; std::string body;
    Rep(uint8_t t, std::string b) : type(t), body(std::move(b)) {}
    Rep(const std::pair<uint8_t, std::string>& p) : type(p.first), body(p.second) {}
    int code() const { return type == 0xFF ? (parse(body)["code"] | 0) : 0; } bool ok() const { return type != 0xFF && type != 0; } };
static Rep req(TestClient& c, uint8_t type, const Bytes& p) { auto r = c.request(type, nextSeq(), p); return {r.first, r.second}; }
static Rep begin(TestClient& c, const std::string& j) { return req(c, 0x20, bytesOf(j)); }
static Rep chunk(TestClient& c, uint32_t off, const uint8_t* d, size_t n) {
    Bytes p{static_cast<uint8_t>(off), static_cast<uint8_t>(off >> 8), static_cast<uint8_t>(off >> 16), static_cast<uint8_t>(off >> 24)};
    p.insert(p.end(), d, d + n);
    return req(c, 0x21, p);
}
static Rep endb(TestClient& c, const std::string& j = "{}") { return req(c, 0x22, bytesOf(j)); }
static Rep abortb(TestClient& c) { return req(c, 0x23, {}); }
static std::string S(const Rep& r) { return "type=" + std::to_string(r.type) + (r.type == 0xFF ? " code=" + std::to_string(r.code()) + " err=" + std::string(parse(r.body)["error"] | "") : ""); }

static Bytes scrollFrames(size_t n, uint64_t seed) {
    XorShift r(seed); Bytes b(n * FRAME_BYTES);
    for (size_t i = 0; i < b.size(); ++i) b[i] = static_cast<uint8_t>(r.below(256));
    for (size_t i = 0; i < n; ++i) b[i * FRAME_BYTES + 46] &= 0x03;
    return b;
}
static uint64_t liveHash(uint16_t count) { return count ? fnv1a(runtimeScrollFrameBits(0), static_cast<size_t>(count) * FRAME_BYTES) : fnv1a(nullptr, 0); }
static Rep uploadRaw(TestClient& c, const Bytes& fr, const std::string& extra = "", bool doEnd = true, std::string endJson = "{}") {
    size_t n = fr.size() / FRAME_BYTES;
    Rep b = begin(c, "{\"kind\":\"scroll\",\"totalBytes\":" + std::to_string(fr.size()) + ",\"totalFrames\":" + std::to_string(n) + ",\"timelineId\":\"t\"" + extra + "}");
    if (!b.ok()) return b;
    for (size_t off = 0; off < fr.size(); off += 85 * FRAME_BYTES) {
        Rep r = chunk(c, static_cast<uint32_t>(off), fr.data() + off, std::min<size_t>(85 * FRAME_BYTES, fr.size() - off));
        if (!r.ok()) return r;
    }
    return doEnd ? endb(c, endJson) : b;
}
// Independent reference of docs §7.1 scroll_bitmap expansion + rotation.
static Bytes refBitmapExpand(const Bytes& bm, uint32_t W, uint16_t& rotation) {
    const uint32_t stride = (W + 7) / 8, fc = (W > 22 ? W - 22 : 1) + 1;
    auto lit = [&](uint32_t x, uint32_t y) { return x < W && ((bm[y * stride + (x >> 3)] >> (x & 7)) & 1); };
    auto frame = [&](uint32_t o, uint8_t* out) { bool any = false; std::memset(out, 0, 47);
        for (uint32_t y = 0; y < 18; ++y) { const uint32_t rl = ROW_LENGTHS[y], xs = (22 - rl) / 2;
            for (uint32_t lx = 0; lx < rl; ++lx) if (lit(o + xs + lx, y)) { uint32_t idx = ROW_OFFSETS[y] + lx; out[idx >> 3] |= static_cast<uint8_t>(1U << (idx & 7)); any = true; } }
        return any; };
    uint8_t tmp[47]; rotation = 0;
    for (uint32_t o = 0; o < fc; ++o) if (frame(o, tmp)) { rotation = static_cast<uint16_t>(o); break; }
    Bytes out(fc * 47);
    for (uint32_t i = 0; i < fc; ++i) frame((i + rotation) % fc, out.data() + i * 47);
    return out;
}
static Bytes randomBitmap(uint32_t W, uint64_t seed, uint32_t darkLead) {
    XorShift r(seed); uint32_t stride = (W + 7) / 8; Bytes b(18 * stride, 0);
    for (uint32_t y = 0; y < 18; ++y) for (uint32_t x = darkLead; x < W; ++x) if (r.below(3) == 0) b[y * stride + (x >> 3)] |= static_cast<uint8_t>(1U << (x & 7));
    return b;
}
static Rep uploadBitmap(TestClient& c, const Bytes& bm, uint32_t W, bool doEnd = true, const std::string& endJson = "{}") {
    Rep b = begin(c, "{\"kind\":\"scroll_bitmap\",\"width\":" + std::to_string(W) + ",\"rows\":18,\"totalBytes\":" + std::to_string(bm.size()) + ",\"intervalMs\":50,\"timelineId\":\"bm\"}");
    if (!b.ok()) return b;
    for (size_t off = 0; off < bm.size(); off += 2000) { Rep r = chunk(c, static_cast<uint32_t>(off), bm.data() + off, std::min<size_t>(2000, bm.size() - off)); if (!r.ok()) return r; }
    return doEnd ? endb(c, endJson) : b;
}

// ---- saved faces documents -----------------------------------------------------
static std::string faceJson(unsigned i, const std::string& type, size_t nameLen, int order = -1) {
    std::string s = "{\"id\":\"" + std::string(type == "default" ? "face_" : "custom_") + std::to_string(i) + "\",\"name\":\"" + std::string(nameLen, 'n') + "\",\"type\":\"" + type +
                    "\",\"order\":" + std::to_string(order < 0 ? static_cast<int>(i) : order) + ",\"frameBytes\":[";
    for (int k = 0; k < 47; ++k) s += std::to_string(k == 46 ? (i & 3) : ((i * 7 + k) & 0xFF)) + (k < 46 ? "," : "");
    return s + "]}";
}
static std::string facesDoc(unsigned n, size_t nameLen = 8, const std::string& pad = "") {
    std::string s = "{\"category\":\"unified_saved_faces\"" + (pad.empty() ? "" : ",\"pad\":\"" + pad + "\"") + ",\"faces\":[";
    for (unsigned i = 1; i <= n; ++i) s += faceJson(i, i == 1 ? "default" : "custom", nameLen) + (i < n ? "," : "");
    return s + "]}";
}
static const std::string facesPath() { return gRoot + "/resources/saved_faces.json"; }
static uint64_t fileHash() { Bytes b = readFile(facesPath()); return fnv1a(b.data(), b.size()); }
static Rep uploadFaces(TestClient& c, const std::string& doc, size_t chunkBytes = 4000) {
    Rep b = begin(c, "{\"kind\":\"faces\",\"totalBytes\":" + std::to_string(doc.size()) + "}");
    if (!b.ok()) return b;
    for (size_t off = 0; off < doc.size(); off += chunkBytes) { Rep r = chunk(c, static_cast<uint32_t>(off), reinterpret_cast<const uint8_t*>(doc.data()) + off, std::min(chunkBytes, doc.size() - off)); if (!r.ok()) return r; }
    return endb(c);
}
static void seedFaces(unsigned n, size_t nameLen = 8) {
    writeFile(facesPath(), facesDoc(n, nameLen));
    loadSavedFaces(false);
}

int main(int argc, char** argv) {
    gRoot = argc > 1 ? argv[1] : "/tmp/rina-f5-fs";
    L.layer = "fw-blob"; L.evidence = "logs/firmware/f5_f7_blob.log";
    resetFakeFs(gRoot);
    protocolBegin();
    initRuntimeScrollFrameBuffer();
    runtimeFsMounted() = true;
    seedFaces(5);
    TestClient A, B; A.connect(T); B.connect(T);

    L.check("F5-CONST", MAX_FACES_BLOB_BYTES == 262144 && MAX_AUTO_FACES == 128 && MAX_SCROLL_FRAMES == 3072 && MAX_SCROLL_TEXT_BYTES == 4096,
            "MAX_FACES_BLOB_BYTES=262144 MAX_AUTO_FACES=128 MAX_SCROLL_FRAMES=3072 MAX_SCROLL_TEXT_BYTES=4096 reclaim=30000ms");

    // F5-RAW-HAPPY
    const Bytes F300 = scrollFrames(300, 1);
    { Rep e = uploadRaw(A, F300);
      auto d = parse(e.body);
      L.check("F5-RAW-HAPPY-HASH", e.ok() && runtimeState().scrollFrameCount == 300 && liveHash(300) == fnv1a(F300.data(), F300.size()) && (d["uploadComplete"] | false),
              S(e) + " frames=" + std::to_string(runtimeState().scrollFrameCount) + " liveHash=" + hex64(liveHash(300)) + " sentHash=" + hex64(fnv1a(F300.data(), F300.size()))); }
    // F5-DUP-CHUNK / OUT-OF-ORDER
    { const Bytes F = scrollFrames(200, 2);
      Rep b = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":9400,\"totalFrames\":200}");
      Rep c0 = chunk(A, 0, F.data(), 3995), dup = chunk(A, 0, F.data(), 3995);
      Rep c2early = chunk(A, 7990, F.data() + 7990, 1410);
      Rep c1 = chunk(A, 3995, F.data() + 3995, 3995), c2 = chunk(A, 7990, F.data() + 7990, 1410);
      Rep e = endb(A);
      int expOff = parse(dup.body)["expectedOffset"] | -1;
      L.check("F5-DUP-CHUNK", b.ok() && c0.ok() && dup.code() == 400 && expOff == 3995, "dup=" + S(dup) + " expectedOffset=" + std::to_string(expOff));
      L.check("F5-OUT-OF-ORDER-CHUNK", c2early.code() == 400 && c1.ok() && c2.ok() && e.ok() && liveHash(200) == fnv1a(F.data(), F.size()),
              "early=" + S(c2early) + " end=" + S(e) + " hashMatch=" + std::to_string(liveHash(200) == fnv1a(F.data(), F.size()))); }
    // F5-LEN-MISMATCH (non-multiple of 47) and short END
    { Rep b = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":470,\"totalFrames\":10}");
      Rep bad = chunk(A, 0, F300.data(), 50);
      Rep good = chunk(A, 0, F300.data(), 47 * 9);
      Rep e = endb(A);
      Rep after = chunk(A, 423, F300.data(), 47);
      L.check("F5-LEN-MISMATCH", b.ok() && bad.code() == 400 && good.ok() && e.code() == 400 && after.code() == 400,
              "bad=" + S(bad) + " endShort=" + S(e) + " chunkAfterEnd=" + S(after)); }
    // F5-OVER-LIMIT
    { Rep a1 = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":144431,\"totalFrames\":3073}");
      Rep a2 = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":144431}");
      Rep a3 = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":94,\"totalFrames\":2}");
      Rep a4 = chunk(A, 0, F300.data(), 141);
      abortb(A);
      Rep f1 = begin(A, "{\"kind\":\"faces\",\"totalBytes\":262145}");
      Rep f2 = begin(A, "{\"kind\":\"faces\",\"totalBytes\":262144}");
      abortb(A);
      L.check("F5-OVER-LIMIT", a1.code() == 413 && a2.code() == 413 && a3.ok() && a4.code() == 413 && f1.code() == 413 && f2.ok(),
              "frames3073=" + S(a1) + " implied3073=" + S(a2) + " chunkPastTotal=" + S(a4) + " faces262145=" + S(f1) + " faces262144=" + S(f2)); }

    // F5-ATOMICITY raw scroll: abort / missing chunk / disconnect after BEGIN
    const Bytes A100 = scrollFrames(100, 3);
    auto commitA = [&] { uploadRaw(A, A100, ",\"intervalMs\":50", true, "{\"start\":true}"); };
    { commitA();
      const uint64_t h0 = liveHash(100); const bool active0 = runtimeState().firmwareScrollActive;
      Rep b = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":2350,\"totalFrames\":50}");
      const uint16_t countAfterBegin = runtimeState().scrollFrameCount;
      chunk(A, 0, F300.data(), 470);
      abortb(A);
      auto st = parse(A.request(0x02, nextSeq(), bytesOf("{\"lite\":true}")).second);
      const uint16_t count = runtimeState().scrollFrameCount;
      const bool keep = count == 100 && liveHash(100) == h0;
      L.check("F5-RAW-ABORT-ATOMICITY", keep,
              "before: frames=100 active=" + std::to_string(active0) + " afterBEGIN frames=" + std::to_string(countAfterBegin) + " afterABORT frames=" + std::to_string(count) +
                  " status.firmwareScrollActive=" + std::to_string(st["renderer"]["firmwareScrollActive"] | false) + " status.scrollFrameCount=" + std::to_string(st["renderer"]["scrollFrameCount"].as<long>()) +
                  " timelineId='" + std::string(st["renderer"]["scrollTimelineId"] | "") + "'"); }
    { commitA(); const uint64_t h0 = liveHash(100);
      begin(A, "{\"kind\":\"scroll\",\"totalBytes\":8000,\"totalFrames\":170}"); chunk(A, 0, F300.data(), 3995); chunk(A, 7990, F300.data(), 10);
      Rep e = endb(A);
      L.check("F5-RAW-MISSING-CHUNK-ATOMICITY", runtimeState().scrollFrameCount == 100 && liveHash(100) == h0,
              "end=" + S(e) + " framesAfter=" + std::to_string(runtimeState().scrollFrameCount)); }
    { commitA(); const uint64_t h0 = liveHash(100);
      TestClient D; D.connect(T); begin(D, "{\"kind\":\"scroll\",\"totalBytes\":470,\"totalFrames\":10}");
      rinalink::transportUnregisterClient(D.id); serviceProtocol();
      Rep other = begin(B, "{\"kind\":\"scroll\",\"totalBytes\":47,\"totalFrames\":1}"); abortb(B);
      L.check("F5-RAW-DISCONNECT-RELEASES-SLOT", other.ok() && g_activeScrollBlobSlot == -1, "otherClientBegin=" + S(other));
      L.check("F5-RAW-DISCONNECT-ATOMICITY", runtimeState().scrollFrameCount != 0 && liveHash(100) == h0, "framesAfterDisconnect=" + std::to_string(runtimeState().scrollFrameCount)); }

    // F5-BITMAP happy + atomicity
    { commitA(); const uint64_t h0 = liveHash(100);
      const uint32_t W = 400; Bytes bm = randomBitmap(W, 7, 30);
      uploadBitmap(A, bm, W, false); abortb(A);
      L.check("F5-BITMAP-ABORT-ATOMICITY", runtimeState().scrollFrameCount == 100 && liveHash(100) == h0, "framesAfter=" + std::to_string(runtimeState().scrollFrameCount));
      uint16_t rot = 0; Bytes ref = refBitmapExpand(bm, W, rot);
      Rep e = uploadBitmap(A, bm, W);
      auto d = parse(e.body); const uint16_t fc = runtimeState().scrollFrameCount;
      L.check("F5-BITMAP-HAPPY-REFERENCE-HASH", e.ok() && fc == ref.size() / 47 && (d["rotation"] | -1) == rot && liveHash(fc) == fnv1a(ref.data(), ref.size()),
              S(e) + " frames=" + std::to_string(fc) + " rotation=" + std::to_string(d["rotation"] | -1) + " refRotation=" + std::to_string(rot) +
                  " liveHash=" + hex64(liveHash(fc)) + " refHash=" + hex64(fnv1a(ref.data(), ref.size()))); }

    // F5-APPEND
    { const Bytes base = scrollFrames(100, 11), more = scrollFrames(50, 12);
      uploadRaw(A, base);
      Rep b = begin(A, "{\"kind\":\"scroll\",\"append\":true,\"totalBytes\":2350,\"totalFrames\":150}");
      Rep c = chunk(A, 0, more.data(), more.size()); Rep e = endb(A);
      Bytes all = base; all.insert(all.end(), more.begin(), more.end());
      L.check("F5-APPEND-HASH", b.ok() && c.ok() && e.ok() && runtimeState().scrollFrameCount == 150 && liveHash(150) == fnv1a(all.data(), all.size()), S(e)); }

    // F5-INACTIVITY 30 s reclaim, before/after, per kind
    for (const std::string& kind : {std::string("faces"), std::string("scroll_bitmap"), std::string("scroll")}) {
        Rep b = kind == "faces" ? begin(A, "{\"kind\":\"faces\",\"totalBytes\":100}")
              : kind == "scroll" ? begin(A, "{\"kind\":\"scroll\",\"totalBytes\":470,\"totalFrames\":10}")
                                 : begin(A, "{\"kind\":\"scroll_bitmap\",\"width\":30,\"rows\":18,\"totalBytes\":72}");
        const uint8_t junk[47] = {0};
        advanceMs(29999); serviceProtocol();
        Rep before = chunk(A, 0, junk, kind == "scroll_bitmap" ? 36 : (kind == "scroll" ? 47 : 10));
        advanceMs(29999); serviceProtocol();
        Rep stillAlive = chunk(A, kind == "scroll_bitmap" ? 36 : (kind == "scroll" ? 47 : 10), junk, kind == "scroll" ? 47 : 10);
        advanceMs(30000); serviceProtocol();
        Rep after = chunk(A, kind == "scroll_bitmap" ? 46 : (kind == "scroll" ? 94 : 20), junk, 10);
        L.check("F5-INACTIVITY-" + kind, b.ok() && before.ok() && stillAlive.ok() && after.code() == 400 && A.t && g_clients[A.id.slot].blob.kind == BlobKind::None,
                "at29999=" + S(before) + " refreshedAt29999=" + S(stillAlive) + " at30000=" + S(after) + " (>= 30000 ms reclaims)");
    }

    // F5-GENERATION: another client's SET_FRAME / stop_scroll invalidates a bitmap upload
    { const uint32_t W = 100; Bytes bm = randomBitmap(W, 9, 0);
      begin(A, "{\"kind\":\"scroll_bitmap\",\"width\":100,\"rows\":18,\"totalBytes\":" + std::to_string(bm.size()) + "}");
      Rep c1 = chunk(A, 0, bm.data(), 100);
      Bytes sf{0, 0}; sf.resize(49, 0);
      Rep bs = req(B, 0x10, sf);
      Rep c2 = chunk(A, 100, bm.data() + 100, 100);
      Rep e = endb(A);
      L.check("F5-GENERATION-SETFRAME-INVALIDATES", c1.ok() && bs.ok() && c2.code() == 400 && e.code() == 400, "chunkAfterOtherSetFrame=" + S(c2) + " end=" + S(e)); }
    { begin(A, "{\"kind\":\"scroll\",\"totalBytes\":470,\"totalFrames\":10}");
      chunk(A, 0, F300.data(), 47);
      Rep st = B.cmd(nextSeq(), "{\"cmd\":\"start_scroll\",\"intervalMs\":50}");
      Rep c2 = chunk(A, 47, F300.data(), 47);
      Rep stop = B.cmd(nextSeq(), "{\"cmd\":\"stop_scroll\"}");
      Rep c3 = chunk(A, 94, F300.data(), 47);
      L.check("F5-GENERATION-START-VS-STOP", c2.ok() && c3.code() == 400, "chunkAfterStartScroll=" + S(c2) + " chunkAfterStopScroll=" + S(c3) + " startReply=" + std::to_string(st.type) + " stopReply=" + std::to_string(stop.type)); }

    // F5-TWO-CLIENTS
    { const Bytes F = scrollFrames(120, 21);
      Rep ba = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":5640,\"totalFrames\":120}");
      Rep bb = begin(B, "{\"kind\":\"scroll\",\"totalBytes\":47,\"totalFrames\":1}");
      Rep bbm = begin(B, "{\"kind\":\"scroll_bitmap\",\"width\":30,\"rows\":18,\"totalBytes\":72}");
      Rep ab = abortb(B);
      Rep eb = endb(B);
      Rep bf = begin(B, "{\"kind\":\"faces\",\"totalBytes\":10}"); abortb(B);
      chunk(A, 0, F.data(), 3995); chunk(A, 3995, F.data() + 3995, 1645);
      Rep ea = endb(A);
      L.check("F5-TWO-CLIENTS-EXCLUSIVE", ba.ok() && bb.code() == 409 && bbm.code() == 409 && ab.ok() && eb.code() == 400 && bf.ok() && ea.ok() && liveHash(120) == fnv1a(F.data(), F.size()),
              "B.beginScroll=" + S(bb) + " B.beginBitmap=" + S(bbm) + " B.abort=" + S(ab) + " B.end=" + S(eb) + " B.beginFaces=" + S(bf) + " A.end=" + S(ea)); }

    // F5-FACES happy + download + invalid docs keep previous
    { const std::string doc = facesDoc(10);
      Rep e = uploadFaces(A, doc, 2048);
      DynamicJsonDocument sent(65536), disk(65536);
      deserializeJson(sent, doc); Bytes fb = readFile(facesPath());
      deserializeJson(disk, static_cast<const uint8_t*>(fb.data()), fb.size()); // const: copy mode, fb untouched
      String s1, s2; serializeJson(sent, s1); serializeJson(disk, s2);
      L.check("F5-FACES-HAPPY", e.ok() && s1 == s2 && runtimeAutoFaceCount() == 10, S(e) + " diskCanonicalEq=" + std::to_string(s1 == s2) + " loaded=" + std::to_string(runtimeAutoFaceCount()));
      T.chunk = 512;
      Bytes dl; uint32_t gen = 0; bool more = true; unsigned parts = 0; uint8_t sq = nextSeq();
      while (more && parts < 1000) {
          std::string j = "{\"offset\":" + std::to_string(dl.size()) + (parts ? ",\"gen\":" + std::to_string(gen) : "") + "}";
          A.push(jsonFrame(0x24, sq, j)); serviceProtocol();
          auto fs = A.take(); if (fs.empty() || fs[0].type != 0xA4) break;
          gen = fs[0].payload[0] | (fs[0].payload[1] << 8) | (fs[0].payload[2] << 16) | (static_cast<uint32_t>(fs[0].payload[3]) << 24);
          dl.insert(dl.end(), fs[0].payload.begin() + 4, fs[0].payload.end()); more = fs[0].flags & FLAG_MORE; ++parts;
      }
      T.chunk = 4032;
      size_t firstDiff = 0; while (firstDiff < std::min(dl.size(), fb.size()) && dl[firstDiff] == fb[firstDiff]) ++firstDiff;
      L.check("F5-GET-FACES-DOWNLOAD-HASH", !more && fnv1a(dl.data(), dl.size()) == fnv1a(fb.data(), fb.size()),
              "parts=" + std::to_string(parts) + " bytes=" + std::to_string(dl.size()) + " fileBytes=" + std::to_string(fb.size()) + " firstDiff=" + std::to_string(firstDiff) +
                  " more=" + std::to_string(more) + " hashEq=" + std::to_string(fnv1a(dl.data(), dl.size()) == fnv1a(fb.data(), fb.size())));
      Rep stale = req(A, 0x24, bytesOf("{\"offset\":0,\"gen\":" + std::to_string(gen + 5) + "}"));
      L.check("F5-GET-FACES-GEN-MISMATCH-409", stale.code() == 409, S(stale)); }
    { const uint64_t h0 = fileHash(); const uint16_t n0 = runtimeAutoFaceCount();
      std::string good = facesDoc(6);
      std::vector<std::pair<std::string, std::string>> bad = {
          {"TRUNCATED-JSON", good.substr(0, good.size() / 2)},
          {"BAD-CATEGORY", "{\"category\":\"x\",\"faces\":[" + faceJson(1, "default", 3) + "]}"},
          {"NO-DEFAULT", "{\"category\":\"unified_saved_faces\",\"faces\":[" + faceJson(2, "custom", 3) + "]}"},
          {"ORDER-0", "{\"category\":\"unified_saved_faces\",\"faces\":[" + faceJson(1, "default", 3, 0) + "]}"},
          {"FRAME-46", [&] { std::string f = faceJson(1, "default", 3); f.replace(f.rfind(','), f.size() - f.rfind(','), "]}"); return "{\"category\":\"unified_saved_faces\",\"faces\":[" + f + "]}"; }()},
          {"TAIL-BITS", [&] { std::string f = faceJson(1, "default", 3); size_t p = f.rfind(','); f.replace(p + 1, f.size() - p - 1, "255]}"); return "{\"category\":\"unified_saved_faces\",\"faces\":[" + f + "]}"; }()},
          {"FACES-129", facesDoc(129)}};
      for (auto& b : bad) {
          Rep e = uploadFaces(A, b.second);
          L.check("F7-FACES-INVALID-" + b.first + "-KEEPS-PREVIOUS", e.code() == 400 && fileHash() == h0 && runtimeAutoFaceCount() == n0,
                  S(e) + " fileUnchanged=" + std::to_string(fileHash() == h0));
      } }

    // ---- F7 boundaries --------------------------------------------------------------
    for (unsigned n : {0U, 1U, 3071U, 3072U}) {
        const Bytes F = scrollFrames(n, 100 + n);
        Rep e = uploadRaw(A, F);
        L.check("F7-SCROLL-FRAMES-" + std::to_string(n), e.ok() && runtimeState().scrollFrameCount == n && liveHash(static_cast<uint16_t>(n)) == fnv1a(F.data(), F.size()),
                S(e) + " frames=" + std::to_string(runtimeState().scrollFrameCount));
    }
    { Rep b = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":144431,\"totalFrames\":3073}");
      L.check("F7-SCROLL-FRAMES-3073", b.code() == 413, S(b)); }
    { Rep b = begin(A, "{\"kind\":\"scroll\",\"totalBytes\":0,\"totalFrames\":0}"); Rep e = endb(A, "{\"start\":true}");
      auto d = parse(e.body);
      bool reported = d["started"] | false; bool active = runtimeState().firmwareScrollActive;
      L.check("F7-SCROLL-0-FRAMES-START-REPLY", reported == active, S(e) + " reply.started=" + std::to_string(reported) + " actualActive=" + std::to_string(active)); }
    for (uint32_t W : {22U, 23U, 3093U, 3094U}) {
        Bytes bm = randomBitmap(W, W, 0);
        Rep e = uploadBitmap(A, bm, W);
        if (W == 3094) { L.check("F7-BITMAP-WIDTH-3094", e.code() == 400 || e.code() == 413, S(e) + " (doc §7.1: width range 22..3093; >3072 frames -> 413)"); continue; }
        uint16_t rot; Bytes ref = refBitmapExpand(bm, W, rot);
        L.check("F7-BITMAP-WIDTH-" + std::to_string(W), e.ok() && runtimeState().scrollFrameCount == ref.size() / 47 && liveHash(runtimeState().scrollFrameCount) == fnv1a(ref.data(), ref.size()),
                S(e) + " frames=" + std::to_string(runtimeState().scrollFrameCount));
    }

    // Text boundaries. (a) code limit via handleCmd directly (bypassing framing), (b) over the wire.
    struct Txt { std::string name; std::string unit; };
    const std::vector<Txt> scripts = {{"ASCII", "a"}, {"CJK", "\xE4\xB8\xAD"}, {"EMOJI", "\xF0\x9F\x98\x80"}, {"COMBINING", "e\xCC\x81"}};
    auto makeText = [](const std::string& unit, size_t bytes) { std::string s; while (s.size() + unit.size() <= bytes) s += unit; while (s.size() < bytes) s += 'a'; return s; };
    for (auto& sc : scripts) {
        for (size_t n : {4095UL, 4096UL, 4097UL}) {
            std::string text = makeText(sc.unit, n);
            std::string json = "{\"cmd\":\"start_scroll\",\"payload\":{\"sourceText\":\"" + text + "\"}}";
            ClientSlot& cs = g_clients[A.id.slot];
            uploadRaw(A, scrollFrames(30, 5));
            uint8_t sq = nextSeq();
            handleCmd(cs, sq, reinterpret_cast<const uint8_t*>(json.data()), static_cast<uint16_t>(json.size()));
            auto rep = A.replyFor(sq);
            auto meta = parse(A.request(0x04, nextSeq(), {}).second);
            std::string back = meta["sourceText"] | "";
            bool ok = n <= 4096 ? (rep.first == 0x81 && back == text) : (rep.first == 0xFF && (parse(rep.second)["code"] | 0) == 413);
            L.check("F7-TEXT-CODELIMIT-" + sc.name + "-" + std::to_string(n), ok,
                    "replyType=" + std::to_string(rep.first) + " metaBytes=" + std::to_string(meta["sourceTextBytes"] | -1) + " roundTripEq=" + std::to_string(back == text));
        }
        // Over the wire: the smallest CMD carrying 4096 B of text exceeds the 4096 B frame payload.
        std::string text = makeText(sc.unit, 4096);
        std::string json = "{\"cmd\":\"start_scroll\",\"payload\":{\"sourceText\":\"" + text + "\"}}";
        Bytes f = jsonFrame(0x01, 0x77, json);
        uint8_t sq = 0x77;
        const unsigned disconnectsBefore = T.disconnects;
        for (size_t off = 0; off < f.size();) { size_t k = std::min(rinalink::transportInboundFree(A.id), f.size() - off); if (k == 0) break; A.push(Bytes(f.begin() + static_cast<long>(off), f.begin() + static_cast<long>(off + k))); off += k; serviceProtocol(); }
        serviceProtocol();
        auto rep = A.replyFor(sq);
        size_t maxFit = 4096 - (json.size() - text.size());
        const bool closed = T.disconnects > disconnectsBefore;
        L.check("F7-TEXT-WIRE-4096-" + sc.name, rep.first == 0xFF && (parse(rep.second)["code"] | 0) == 413 && closed,
                "framePayload=" + std::to_string(json.size()) + " replyType=" + std::to_string(rep.first) + " carrierClosed=" + std::to_string(closed) + " maxTextBytesThatFit=" + std::to_string(maxFit));
        // An oversized header closes the carrier (protocol §2); later cases reuse A.
        if (closed) A.connect(T);
    }

    // Faces 127/128/129 and upsert at the limit.
    for (unsigned n : {127U, 128U, 129U}) {
        seedFaces(3); const uint64_t h0 = fileHash();
        Rep e = uploadFaces(A, facesDoc(n));
        bool ok = n <= 128 ? (e.ok() && runtimeAutoFaceCount() == n) : (e.code() == 400 && fileHash() == h0);
        L.check("F7-FACES-BLOB-" + std::to_string(n), ok, S(e) + " loaded=" + std::to_string(runtimeAutoFaceCount()));
    }
    { const std::string up = "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"name\":\"x\",\"type\":\"custom\",\"frameHex\":\"" + std::string(94, '0') + "\"}}}";
      seedFaces(127); Rep r127 = A.cmd(nextSeq(), up); unsigned c127 = runtimeAutoFaceCount();
      const uint64_t h0 = fileHash(); Rep r128 = A.cmd(nextSeq(), up);
      L.check("F7-FACE-UPSERT-127-128-129", r127.ok() && c127 == 128 && r128.code() == 413 && fileHash() == h0,
              "at127=" + S(r127) + " count=" + std::to_string(c127) + " at128=" + S(r128) + " fileUnchanged=" + std::to_string(fileHash() == h0)); }
    { const uint64_t h0 = fileHash();
      Rep bad = A.cmd(nextSeq(), "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"name\":\"x\",\"type\":\"custom\",\"frameHex\":\"" + std::string(93, '0') + "\"}}}");
      Rep trunc = A.cmd(nextSeq(), "{\"cmd\":\"face_rename\",\"payload\":{\"id\":\"face_1\",\"na");
      L.check("F7-CMD-BAD-FIELDS-KEEP-FILE", bad.code() == 400 && trunc.code() == 400 && fileHash() == h0, "frameHex93=" + S(bad) + " truncatedJson=" + S(trunc)); }

    // Faces BLOB near 256 KiB.
    { std::string doc = facesDoc(100, 20);
      const std::string padded = facesDoc(100, 20, std::string(262144 - doc.size() - 9, 'p'));
      Rep e = uploadFaces(A, padded, 4000);
      L.check("F7-FACES-BLOB-262144-BYTES", padded.size() == 262144 && e.ok() && runtimeAutoFaceCount() == 100, "docBytes=" + std::to_string(padded.size()) + " " + S(e));
      const std::string over = facesDoc(100, 20, std::string(262145 - doc.size() - 9, 'p'));
      Rep e2 = begin(A, "{\"kind\":\"faces\",\"totalBytes\":" + std::to_string(over.size()) + "}");
      L.check("F7-FACES-BLOB-262145-BYTES", e2.code() == 413, S(e2)); }
    // Incremental upserts can grow the file past what BLOB accepts (round trip).
    { seedFaces(1);
      for (unsigned i = 0; i < 127; ++i)
          A.cmd(nextSeq(), "{\"cmd\":\"face_upsert\",\"payload\":{\"face\":{\"name\":\"" + std::string(2000, 'N') + "\",\"type\":\"custom\",\"frameHex\":\"" + std::string(94, '0') + "\"}}}");
      const size_t sz = readFile(facesPath()).size();
      Rep e = begin(A, "{\"kind\":\"faces\",\"totalBytes\":" + std::to_string(sz) + "}"); abortb(A);
      L.check("F7-UPSERT-GROWTH-VS-BLOB-LIMIT", sz <= 262144 || e.ok(),
              "faces=" + std::to_string(runtimeAutoFaceCount()) + " fileBytes=" + std::to_string(sz) + " reuploadBegin=" + S(e) + " (face_upsert has no name limit; face_rename caps 64)"); }

    // Storage fault injection on commit.
    { seedFaces(4); const uint64_t h0 = fileHash(); const uint16_t n0 = runtimeAutoFaceCount();
      g_fsFaults.writeLimitBytes = 200;
      Rep e = uploadFaces(A, facesDoc(8));
      g_fsFaults.writeLimitBytes = -1;
      const Bytes after = readFile(facesPath());
      DynamicJsonDocument chk(65536); bool parses = !deserializeJson(chk, after.data(), after.size());
      L.check("F7-FS-PARTIAL-WRITE-FACES-BLOB", e.code() >= 500 && fileHash() == h0 && runtimeAutoFaceCount() == n0,
              "reply=" + S(e) + " replyBytes=" + std::to_string(parse(e.body)["bytes"] | 0) + " fileBytesOnDisk=" + std::to_string(after.size()) + " fileParses=" + std::to_string(parses) +
                  " previousPreserved=" + std::to_string(fileHash() == h0) + " facesLoadedAfter=" + std::to_string(runtimeAutoFaceCount()) + " partialWrites=" + std::to_string(g_fsFaults.partialWrites)); }
    { seedFaces(4); const uint64_t h0 = fileHash();
      g_fsFaults.writeLimitBytes = 150;
      Rep r = A.cmd(nextSeq(), "{\"cmd\":\"face_rename\",\"payload\":{\"id\":\"custom_2\",\"name\":\"renamed\"}}");
      g_fsFaults.writeLimitBytes = -1;
      L.check("F7-FS-PARTIAL-WRITE-FACE-RENAME", r.code() >= 500 && fileHash() == h0,
              "reply=" + S(r) + " fileBytesOnDisk=" + std::to_string(readFile(facesPath()).size()) + " previousPreserved=" + std::to_string(fileHash() == h0) + " facesLoadedAfter=" + std::to_string(runtimeAutoFaceCount())); }
    { seedFaces(4); const uint64_t h0 = fileHash();
      g_fsFaults.failRename = true; Rep e = uploadFaces(A, facesDoc(8)); g_fsFaults.failRename = false;
      g_fsFaults.failOpenWrite = true; Rep e2 = uploadFaces(A, facesDoc(8)); g_fsFaults.failOpenWrite = false;
      L.check("F7-FS-RENAME-OR-OPEN-FAIL-KEEPS-FILE", e.code() == 500 && e2.code() == 500 && fileHash() == h0, "rename=" + S(e) + " open=" + S(e2)); }

    L.check("F5-LOCK-DISCIPLINE", g_lockRecursion == 0 && g_lockOrderViolations == 0,
            "recursion=" + std::to_string(g_lockRecursion) + " orderViolations=" + std::to_string(g_lockOrderViolations));
    std::cout << "SUMMARY F5F7 pass=" << L.pass << " fail=" << L.fail << std::endl;
    return 0;
}
