// ftrd-stream: remote-display POC M2 (docs/handoff/04-milestones.md). A throwaway standalone
// client: Sunshine (Moonlight protocol) -> qcom-iris V4L2 decode -> GPU NV12->ABGR8888 ->
// SteamVR overlay panel. Not wired into ft-screens (that's M4); no input back-channel (M3).
//
//   ftrd-stream --pair PIN                 pair with Sunshine (enter PIN in Sunshine's web UI)
//   ftrd-stream [options]                  stream the "Desktop" app onto a panel
//     --host IP         Sunshine host (default 10.35.78.22: the PC end of the Valve USB adapter)
//     --size WxH        stream size (default 5120x1440, the PC's ultrawide)   --fps N (60)
//     --bitrate KBPS    (default 50000)   --codec hevc|h264 (hevc)
//     --panel-width M   panel width in metres (2.4)   --distance M (1.5)
//     --seconds S       stop after S seconds (default: until SIGINT/SIGTERM)
//     --novr            no SteamVR: decode + convert only (headless checks)
//     --dump F --dump-frame N   write decoded frame N as RGBA (after GPU conversion)
//     --keys DIR        client cert/key dir (default ~/.config/frametop-remote-display)
//
// Prints a stats line every 5 s and a summary at the end: frame rate, lost frames, Sunshine's
// host processing latency, RTT, and the Frame-side latency from the first packet of a frame
// arriving to its texture being handed to SteamVR (receive + queue + decode + convert).
//
// Third-party code (fetched by fetch-deps.sh, never committed): moonlight-embedded's
// libgamestream and moonlight-common-c, both GPLv3. This binary is a local POC, not distributed.
#include "../common/rdcore.h"

extern "C" {
#include <Limelight.h>
#include "client.h"
#include "errors.h"
}

#include <atomic>
#include <mutex>
#include <thread>

namespace {

struct Opts {
    std::string host = "10.35.78.22", app = "Desktop", keys;
    const char *pair = nullptr, *dump = nullptr;
    int w = 5120, h = 1440, fps = 60, bitrate = 50000, dumpFrame = 300;
    bool hevc = true, vr = true;
    double panelW = 2.4, dist = 1.5, seconds = 0;
} g_o;

// One decoded frame's bookkeeping, indexed by frameNumber % kSlots.
constexpr int kSlots = 128;
struct Slot { int frame = -1; int64_t tQueued = 0; uint64_t recvUs = 0; double hostMs = 0; };
Slot g_slots[kSlots];

struct Window {
    uint64_t frames = 0;
    std::vector<double> decMs, convMs, hostMs, queueMs, clientMs;
    void Clear() { *this = Window(); }
};

std::mutex g_mu;
Window g_win, g_all;
uint64_t g_lost = 0, g_decodeErrors = 0, g_idr = 0;
int g_lastFrame = -1;
std::atomic<bool> g_terminated{false};
std::atomic<int> g_termError{0};
std::atomic<uint64_t> g_shown{0};

Decoder g_D;
#ifdef FTRD_GL
Rgb g_rgb;
bool g_rgbReady = false;
#endif
#ifdef FTRD_VR
vr::VROverlayHandle_t g_ov = vr::k_ulOverlayHandleInvalid;
bool g_ovShown = false;
#endif
bool g_needIdr = false;

void Log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    printf("moonlight: ");
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

// ---- decoder renderer callbacks (called on moonlight-common-c's decoder thread) --------
int DrSetup(int videoFormat, int width, int height, int redrawRate, void *, int) {
    g_D.codec = (videoFormat & VIDEO_FORMAT_MASK_H265) ? V4L2_PIX_FMT_HEVC : V4L2_PIX_FMT_H264;
    g_D.wantFmt = V4L2_PIX_FMT_NV12;
    g_D.fd = open("/dev/video-dec0", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (g_D.fd < 0) g_D.fd = open("/dev/video22", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (g_D.fd < 0) return perror("open decoder"), -1;
    printf("stream: %s %dx%d @ %d Hz\n", (videoFormat & VIDEO_FORMAT_MASK_H265) ? "HEVC" : "H.264", width, height,
           redrawRate);
    return SetupOutput(g_D, size_t(6) << 20, width, height) ? 0 : -1;
}

void DrCleanup() {
    if (g_D.fd < 0) return;
    FreeCapture(g_D);
    int t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    Xioctl(g_D.fd, VIDIOC_STREAMOFF, &t);
    close(g_D.fd);
    g_D.fd = -1;
}

void ShowFrame(int capIdx, int frame) {
    const int64_t c0 = MonoNs();
    double convMs = 0;
#ifdef FTRD_GL
    if (!g_rgbReady) {
        g_rgb.bt709 = true;  // Sunshine is asked for BT.709 limited range (COLORSPACE_REC_709)
        if (!RgbInit(g_rgb, int(g_D.visible.width), int(g_D.visible.height))) { g_stop = 1; return; }
        g_rgbReady = true;
    }
    Rgb::Out *ro = RgbConvert(g_rgb, g_D, capIdx);
    convMs = (MonoNs() - c0) / 1e6;
    if (!ro) return;
    if (g_o.dump && int(g_shown.load()) == g_o.dumpFrame) {
        std::vector<uint8_t> px(size_t(g_rgb.w) * size_t(g_rgb.h) * 4);
        glReadPixels(0, 0, g_rgb.w, g_rgb.h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
        if (FILE *f = fopen(g_o.dump, "wb")) fwrite(px.data(), 1, px.size(), f), fclose(f);
        printf("dump: frame %llu (stream frame %d) -> %s (RGBA %dx%d)\n", (unsigned long long)g_shown.load(), frame,
               g_o.dump, g_rgb.w, g_rgb.h);
    }
#ifdef FTRD_VR
    if (g_o.vr) {
        if (!ro->vr) {
            vr::DmabufAttributes_t a{};
            a.unWidth = uint32_t(g_rgb.w), a.unHeight = uint32_t(g_rgb.h);
            a.unDepth = a.unMipLevels = a.unArrayLayers = a.unSampleCount = 1;
            a.unFormat = DRM_FORMAT_ABGR8888, a.ulModifier = DRM_FORMAT_MOD_LINEAR, a.unPlaneCount = 1;
            a.plane[0].unOffset = 0, a.plane[0].unStride = ro->stride, a.plane[0].nFd = ro->fd;
            vr::SharedTextureHandle_t h = 0;
            if (!vr::VRIPCResourceManager()->ImportDmabuf(vr::VRApplication_Overlay, &a, &h) || !h) {
                printf("vr: ImportDmabuf failed for the converted frame; stopping\n");
                g_stop = 1;
                return;
            }
            ro->vr = h;
        }
        vr::SharedTextureHandle_t h = ro->vr;
        vr::Texture_t tex = {&h, vr::TextureType_SharedTextureHandle, vr::ColorSpace_Gamma};
        vr::VROverlay()->SetOverlayTexture(g_ov, &tex);
        if (!g_ovShown) vr::VROverlay()->ShowOverlay(g_ov), g_ovShown = true;
    }
#endif
#endif
    const Slot &s = g_slots[frame % kSlots];
    if (s.frame == frame) {
        const double dec = (c0 - s.tQueued) / 1e6;
        const double client = (LiGetMicroseconds() - s.recvUs) / 1e3;
        std::lock_guard<std::mutex> l(g_mu);
        for (Window *w : {&g_win, &g_all}) {
            ++w->frames;
            w->decMs.push_back(dec), w->convMs.push_back(convMs), w->clientMs.push_back(client);
            if (s.hostMs > 0) w->hostMs.push_back(s.hostMs);
        }
    }
    ++g_shown;
}

// Reclaim bitstream buffers, handle events, show decoded frames. Returns once frame `target`
// has been shown (or timeoutMs passes).
void Pump(int target, int timeoutMs) {
    const int64_t deadline = MonoNs() + int64_t(timeoutMs) * 1000000;
    for (;;) {
        bool gotTarget = false;
        for (;;) {  // bitstream buffers back
            v4l2_plane pl[VIDEO_MAX_PLANES]{};
            v4l2_buffer b{};
            b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, b.memory = V4L2_MEMORY_MMAP, b.length = 1, b.m.planes = pl;
            if (Xioctl(g_D.fd, VIDIOC_DQBUF, &b) < 0) break;
            g_D.freeOut.push_back(int(b.index));
        }
        while (g_D.capOn) {  // decoded frames
            v4l2_plane pl[VIDEO_MAX_PLANES]{};
            v4l2_buffer b{};
            b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, b.memory = V4L2_MEMORY_MMAP;
            b.length = uint32_t(g_D.nCapPlanes), b.m.planes = pl;
            if (Xioctl(g_D.fd, VIDIOC_DQBUF, &b) < 0) break;
            const int frame = int(b.timestamp.tv_sec * 1000000 + b.timestamp.tv_usec);
            if (b.flags & V4L2_BUF_FLAG_ERROR) {
                ++g_decodeErrors;
                g_needIdr = true;
            } else if (pl[0].bytesused > 0) {
                ShowFrame(int(b.index), frame);
            }
            QueueCap(g_D, int(b.index));
            if (frame >= target) gotTarget = true;
        }
        if (gotTarget || g_stop) return;
        const int64_t left = deadline - MonoNs();
        if (left <= 0) return;
        pollfd p{g_D.fd, short(POLLIN | POLLOUT | POLLPRI), 0};
        int r = poll(&p, 1, int(std::max<int64_t>(1, left / 1000000)));
        if (r > 0 && (p.revents & POLLPRI)) {
            v4l2_event ev{};
            while (Xioctl(g_D.fd, VIDIOC_DQEVENT, &ev) == 0)
                if (ev.type == V4L2_EVENT_SOURCE_CHANGE && !SetupCapture(g_D)) g_stop = 1;
        }
        if (r > 0 && (p.revents & POLLERR) && !g_D.capOn) usleep(500);
    }
}

int DrSubmit(PDECODE_UNIT du) {
    if (g_stop) return DR_OK;
    {
        std::lock_guard<std::mutex> l(g_mu);
        if (g_lastFrame >= 0 && du->frameNumber > g_lastFrame + 1) g_lost += uint64_t(du->frameNumber - g_lastFrame - 1);
        g_lastFrame = du->frameNumber;
        const double q = (LiGetMicroseconds() - du->enqueueTimeUs) / 1e3;
        g_win.queueMs.push_back(q), g_all.queueMs.push_back(q);
    }
    // A free bitstream buffer (wait briefly if the decoder holds them all).
    if (g_D.freeOut.empty()) Pump(INT32_MAX, 0);
    for (int i = 0; i < 20 && g_D.freeOut.empty(); ++i) Pump(INT32_MAX, 1);
    if (g_D.freeOut.empty()) { ++g_idr; return DR_NEED_IDR; }
    const int i = g_D.freeOut.back();
    if (size_t(du->fullLength) > g_D.out[size_t(i)].len) {
        printf("stream: frame %d is %d bytes, bitstream buffer only %zu\n", du->frameNumber, du->fullLength,
               g_D.out[size_t(i)].len);
        ++g_idr;
        return DR_NEED_IDR;
    }
    g_D.freeOut.pop_back();
    size_t off = 0;
    for (PLENTRY e = du->bufferList; e; e = e->next) {
        memcpy(static_cast<uint8_t *>(g_D.out[size_t(i)].map) + off, e->data, size_t(e->length));
        off += size_t(e->length);
    }
    Slot &s = g_slots[du->frameNumber % kSlots];
    s.frame = du->frameNumber, s.recvUs = du->receiveTimeUs, s.hostMs = du->frameHostProcessingLatency / 10.0;
    v4l2_plane pl[VIDEO_MAX_PLANES]{};
    v4l2_buffer b{};
    b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, b.memory = V4L2_MEMORY_MMAP, b.index = uint32_t(i);
    b.length = 1, b.m.planes = pl;
    pl[0].bytesused = uint32_t(off);
    b.timestamp.tv_sec = time_t(du->frameNumber / 1000000), b.timestamp.tv_usec = suseconds_t(du->frameNumber % 1000000);
    s.tQueued = MonoNs();
    if (Xioctl(g_D.fd, VIDIOC_QBUF, &b) < 0) {
        perror("QBUF output");
        g_D.freeOut.push_back(i);
        return DR_NEED_IDR;
    }
    Pump(du->frameNumber, 30);  // no B-frames: the frame comes out a few ms later
    if (g_needIdr) {
        g_needIdr = false;
        ++g_idr;
        return DR_NEED_IDR;
    }
    return DR_OK;
}

// ---- connection callbacks --------------------------------------------------------------
void ClStageFailed(int stage, int err) { printf("moonlight: stage %s failed: %d\n", LiGetStageName(stage), err); }
void ClStarted() { printf("moonlight: connection started\n"); }
void ClTerminated(int err) {
    printf("moonlight: connection terminated (%d)\n", err);
    g_termError = err;
    g_terminated = true;
}
void ClStatus(int status) {
    printf("moonlight: connection status %s\n", status == CONN_STATUS_POOR ? "POOR" : "okay");
}

void PrintWindow(const char *label, const Window &w, double secs) {
    printf("%s %.0fs: %.1f fps | host %.1f ms (p99 %.1f) | queue %.1f | decode %.1f (p99 %.1f) | convert %.1f "
           "| client recv->shown %.1f ms (p99 %.1f)",
           label, secs, w.frames / secs, Pct(w.hostMs, 50), Pct(w.hostMs, 99), Pct(w.queueMs, 50), Pct(w.decMs, 50),
           Pct(w.decMs, 99), Pct(w.convMs, 50), Pct(w.clientMs, 50), Pct(w.clientMs, 99));
    uint32_t rtt = 0, var = 0;
    if (LiGetEstimatedRttInfo(&rtt, &var)) printf(" | rtt %u±%u ms", rtt, var);
    printf(" | lost %llu, idr %llu, dec-err %llu\n", (unsigned long long)g_lost, (unsigned long long)g_idr,
           (unsigned long long)g_decodeErrors);
    fflush(stdout);
}

}  // namespace

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    const char *home = getenv("HOME");
    g_o.keys = std::string(home ? home : ".") + "/.config/frametop-remote-display";
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char * { return i + 1 < argc ? argv[++i] : ""; };
        if (a == "--pair") g_o.pair = next();
        else if (a == "--host") g_o.host = next();
        else if (a == "--app") g_o.app = next();
        else if (a == "--size") sscanf(next(), "%dx%d", &g_o.w, &g_o.h);
        else if (a == "--fps") g_o.fps = atoi(next());
        else if (a == "--bitrate") g_o.bitrate = atoi(next());
        else if (a == "--codec") g_o.hevc = std::string(next()) != "h264";
        else if (a == "--panel-width") g_o.panelW = atof(next());
        else if (a == "--distance") g_o.dist = atof(next());
        else if (a == "--seconds") g_o.seconds = atof(next());
        else if (a == "--novr") g_o.vr = false;
        else if (a == "--dump") g_o.dump = next();
        else if (a == "--dump-frame") g_o.dumpFrame = atoi(next());
        else if (a == "--keys") g_o.keys = next();
        else return fprintf(stderr, "unknown option %s (see the comment at the top of ftrd-stream.cpp)\n", a.c_str()), 2;
    }
    signal(SIGINT, Stop);
    signal(SIGTERM, Stop);
    mkdir(g_o.keys.c_str(), 0700);

    SERVER_DATA server{};
    int r = gs_init(&server, const_cast<char *>(g_o.host.c_str()), 47989, g_o.keys.c_str(), 0, true);
    if (r != GS_OK) return fprintf(stderr, "gs_init %s failed (%d): %s\n", g_o.host.c_str(), r, gs_error ? gs_error : ""), 1;
    printf("server: %s, GPU %s, paired %s\n", g_o.host.c_str(), server.gpuType ? server.gpuType : "?",
           server.paired ? "yes" : "no");

    if (g_o.pair) {
        if (server.paired) return printf("already paired\n"), 0;
        printf("pairing: enter PIN %s in Sunshine's web UI (PIN tab) now\n", g_o.pair);
        r = gs_pair(&server, const_cast<char *>(g_o.pair));
        if (r != GS_OK) return fprintf(stderr, "pairing failed (%d): %s\n", r, gs_error ? gs_error : ""), 1;
        return printf("paired\n"), 0;
    }
    if (!server.paired) return fprintf(stderr, "not paired: run with --pair PIN first\n"), 1;

    PAPP_LIST apps = nullptr;
    int appId = -1;
    if (gs_applist(&server, &apps) == GS_OK)
        for (PAPP_LIST a = apps; a; a = a->next)
            if (g_o.app == a->name) appId = a->id;
    if (appId < 0) return fprintf(stderr, "app \"%s\" not found on the server\n", g_o.app.c_str()), 1;

    STREAM_CONFIGURATION cfg;
    LiInitializeStreamConfiguration(&cfg);
    cfg.width = g_o.w, cfg.height = g_o.h, cfg.fps = g_o.fps, cfg.bitrate = g_o.bitrate;
    cfg.packetSize = 1392;
    cfg.streamingRemotely = STREAM_CFG_LOCAL;
    cfg.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    cfg.supportedVideoFormats = g_o.hevc ? (VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264) : VIDEO_FORMAT_H264;
    cfg.colorSpace = COLORSPACE_REC_709;
    cfg.colorRange = COLOR_RANGE_LIMITED;
    cfg.encryptionFlags = ENCFLG_ALL;

#ifdef FTRD_VR
    if (g_o.vr) {
        vr::EVRInitError err = vr::VRInitError_None;
        vr::VR_Init(&err, vr::VRApplication_Overlay);
        if (err != vr::VRInitError_None)
            return fprintf(stderr, "openvr: %s\n", vr::VR_GetVRInitErrorAsEnglishDescription(err)), 1;
        if (vr::VROverlay()->CreateOverlay("frametop.ftrdstream", "Remote display", &g_ov) != vr::VROverlayError_None)
            return fprintf(stderr, "can't create the overlay (already running?)\n"), 1;
        vr::VROverlay()->SetOverlayWidthInMeters(g_ov, float(g_o.panelW));
        vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
        vr::VRSystem()->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0, poses,
                                                        vr::k_unMaxTrackedDeviceCount);
        const auto &hm = poses[vr::k_unTrackedDeviceIndex_Hmd].mDeviceToAbsoluteTracking;
        const double yaw = std::atan2(hm.m[0][2], hm.m[2][2]);
        vr::HmdMatrix34_t P{};
        P.m[0][0] = float(std::cos(yaw)), P.m[0][2] = float(std::sin(yaw));
        P.m[1][1] = 1;
        P.m[2][0] = float(-std::sin(yaw)), P.m[2][2] = float(std::cos(yaw));
        P.m[0][3] = float(hm.m[0][3] - std::sin(yaw) * g_o.dist);
        P.m[1][3] = float(hm.m[1][3]);
        P.m[2][3] = float(hm.m[2][3] - std::cos(yaw) * g_o.dist);
        vr::VROverlay()->SetOverlayTransformAbsolute(g_ov, vr::TrackingUniverseStanding, &P);
        vr::VROverlay()->SetOverlayFlag(g_ov, vr::VROverlayFlags_IgnoreTextureAlpha, true);
        vr::ETrackedPropertyError pe;
        g_comp.hz = vr::VRSystem()->GetFloatTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd,
                                                                  vr::Prop_DisplayFrequency_Float, &pe);
        SampleComp(g_comp);
    }
#endif

    r = gs_start_app(&server, &cfg, appId, false, true /* audio stays on the PC */, 0);
    if (r != GS_OK) return fprintf(stderr, "starting %s failed (%d): %s\n", g_o.app.c_str(), r, gs_error ? gs_error : ""), 1;
    printf("app: %s started at %dx%d %d fps %d kbps %s\n", g_o.app.c_str(), cfg.width, cfg.height, cfg.fps,
           cfg.bitrate, g_o.hevc ? "HEVC" : "H.264");

    DECODER_RENDERER_CALLBACKS dr;
    LiInitializeVideoCallbacks(&dr);
    dr.setup = DrSetup;
    dr.cleanup = DrCleanup;
    dr.submitDecodeUnit = DrSubmit;
    dr.capabilities = 0;
    CONNECTION_LISTENER_CALLBACKS cl;
    LiInitializeConnectionCallbacks(&cl);
    cl.stageFailed = ClStageFailed;
    cl.connectionStarted = ClStarted;
    cl.connectionTerminated = ClTerminated;
    cl.connectionStatusUpdate = ClStatus;
    cl.logMessage = Log;

    const int64_t t0 = MonoNs();
    r = LiStartConnection(&server.serverInfo, &cfg, &cl, &dr, nullptr, nullptr, 0, nullptr, 0);
    if (r != 0) {
        fprintf(stderr, "LiStartConnection failed (%d)\n", r);
        gs_quit_app(&server);
        return 1;
    }
    int64_t lastPrint = MonoNs();
    const CpuStat cpu0 = ReadCpu();
    while (!g_stop && !g_terminated) {
        usleep(250000);
#ifdef FTRD_VR
        if (g_o.vr) SampleComp(g_comp);
#endif
        const int64_t now = MonoNs();
        if (now - lastPrint >= 5000000000LL) {
            std::lock_guard<std::mutex> l(g_mu);
            PrintWindow("stats", g_win, (now - lastPrint) / 1e9);
            g_win.Clear();
            lastPrint = now;
        }
        if (g_o.seconds > 0 && (now - t0) / 1e9 >= g_o.seconds) break;
    }
    const double wall = (MonoNs() - t0) / 1e9;
    const CpuStat cpu1 = ReadCpu();
    LiStopConnection();
    gs_quit_app(&server);
    {
        std::lock_guard<std::mutex> l(g_mu);
        printf("\nRESULT %s %dx%d %s %d kbps, %.1f s, %llu frames shown\n", g_o.host.c_str(), g_o.w, g_o.h,
               g_o.hevc ? "HEVC" : "H.264", g_o.bitrate, wall, (unsigned long long)g_shown.load());
        PrintWindow("  all", g_all, wall);
        printf("  SoC busy %.1f%% of 8 cores\n",
               cpu1.total > cpu0.total ? 100.0 * double(cpu1.busy - cpu0.busy) / double(cpu1.total - cpu0.total) : NAN);
    }
#ifdef FTRD_VR
    if (g_o.vr) {
        PrintComp(g_comp, wall);
        vr::VROverlay()->DestroyOverlay(g_ov);
#ifdef FTRD_GL
        for (auto &ro : g_rgb.out)
            if (ro.vr) vr::VRIPCResourceManager()->UnrefResource(ro.vr);
#endif
        vr::VR_Shutdown();
    }
#endif
    return g_terminated && g_termError ? 1 : 0;
}
