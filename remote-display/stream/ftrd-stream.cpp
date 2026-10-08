// ftrd-stream: remote-display POC M2 (docs/handoff/04-milestones.md). A throwaway standalone
// client: Sunshine (Moonlight protocol) -> qcom-iris V4L2 decode -> GPU NV12->ABGR8888 ->
// SteamVR overlay panel. Not wired into ft-screens (that's M4).
// Input (M3): SteamVR's laser mouse on the panel (a controller's laser or Frametop's 3D mouse)
// -> absolute mouse position, buttons and scroll on the PC; a keyboard button under the panel
// opens SteamVR's keyboard, whose characters go over as text (and Backspace/Enter/Tab/Esc/arrows
// as keys).
//
//   ftrd-stream --pair PIN                 pair with Vibepollo (enter PIN in its web UI)
//   ftrd-stream --check                    exit 0 if this identity is paired, 3 if not
//   ftrd-stream [options]                  a Vibepollo "Remote Monitor" (a virtual monitor) onto a panel
//     --host IP         Sunshine host (default 10.35.78.22: the PC end of the Valve USB adapter)
//     --size WxH        stream size (default 2560x1440)   --fps N (90)
//     --app NAME        host app (default "Remote Monitor"). Not "Desktop" on Vibepollo: that one
//                       makes its virtual screen the PC's only display. --app-id N: by id.
//     --bitrate KBPS    (default 50000)   --codec hevc|h264 (hevc)
//     --panel-width M   panel width in metres (2.4)   --distance M (1.5)
//     --seconds S       stop after S seconds (default: until SIGINT/SIGTERM)
//     --novr            no SteamVR: decode + convert only (headless checks)
//     --window [WxH]    M4: a Wayland window on the Frame's desktop (KWin) instead of a SteamVR
//                       overlay (default size: the stream's); NV12 straight to KWin, no GPU pass.
//                       WAYLAND_DISPLAY must name the desktop's socket (stream.sh sets it).
//     --wl-id ID, --title T   the window's app id / title (one per instance; ft-float matches the id)
//     --no-yield        keep streaming during VR games (default: yield, see GameWatch)
//     --follow-size     window mode: when the window is resized (and stays so for 1.5 s), reconnect
//                       at the window's size; with "Remote Monitor" the PC's virtual monitor takes
//                       that size (default on for Remote Monitor in window mode)
//     --dump F --dump-frame N   write decoded frame N as RGBA (after GPU conversion)
//     --keys DIR        client cert/key dir (default ~/.config/frametop-remote-display)
//     --input-test      3 s in, move the PC's cursor to (1234, 567) (checks the input path headless)
//     --latency-test N  N round trips of input to picture, all on the Frame's clock: move the PC's
//                       cursor away, then onto a spot; time from sending the move to the first
//                       decoded frame whose pixels at that spot changed (Frame -> PC input ->
//                       capture -> encode -> network -> decode). Moves the PC's real cursor.
//
// Prints a stats line every 5 s and a summary at the end: frame rate, lost frames, Sunshine's
// host processing latency, RTT, and the Frame-side latency from the first packet of a frame
// arriving to its texture being handed to SteamVR (receive + queue + decode + convert).
//
// Third-party code (fetched by build.sh, never committed): moonlight-embedded's libgamestream
// and moonlight-common-c, both GPLv3, so the built binary is GPLv3 (remote-display/README.md,
// License). It can't be merged into MIT Frametop as is.
#include "../common/rdcore.h"

extern "C" {
#include <Limelight.h>
#include "client.h"
#include "errors.h"
}

#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <cstddef>

#include <atomic>
#include <functional>
#include <mutex>
#include <thread>

namespace {

struct Opts {
    std::string host = "10.35.78.22", app = "Remote Monitor", keys;
    const char *pair = nullptr, *dump = nullptr;
    int w = 2560, h = 1440, fps = 90, bitrate = 50000, dumpFrame = 300;
    bool check = false;  // --check: only report whether this identity is paired (exit 0) or not (3)
    int latencyTrials = 0;
    bool hevc = true, vr = true, inputTest = false, wl = false, follow = false, followSet = false, yield = true;
    std::string wlId = "org.frametop.RemoteDisplay", wlTitle = "Remote PC";
    int appId = -1;
    int winW = 0, winH = 0;
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

// ---- yielding to VR games (M5) --------------------------------------------------------------
// Frametop's screens and floating panels hide while a VR game (a SteamVR scene app) runs, unless
// "ingames visible" is set (Frametop Display Settings). While they're hidden, the stream steps
// aside: the connection stops (decoder freed, no video over Wi-Fi, no encoding on the PC) and the
// overlay mode's panel and keyboard button hide, so no laser reaches them. Vibepollo keeps the
// Remote Monitor (so the PC's windows stay where they are) and the stream resumes on game exit.
// The game state comes from ft-screens ("state" on @ft_screens). FTRD_FAKE_GAME=<file>: the
// file's existence stands in for a running game (headless tests).
struct GameWatch {
    int fd = -1;
    int64_t lastAsk = 0;
    bool game = false, hide = true, known = false;
    void Ask(int64_t now) {
        if (now - lastAsk < 500000000LL) return;
        lastAsk = now;
        if (const char *f = getenv("FTRD_FAKE_GAME")) {
            game = access(f, F_OK) == 0, hide = true, known = true;
            return;
        }
        if (fd < 0) {
            fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
            sockaddr_un me{};
            me.sun_family = AF_UNIX;  // autobind: an abstract name of our own, for the reply
            bind(fd, reinterpret_cast<sockaddr *>(&me), sizeof(sa_family_t));
        }
        char buf[256];
        while (recv(fd, buf, sizeof buf - 1, 0) > 0) {}  // stale replies
        sockaddr_un to{};
        to.sun_family = AF_UNIX;
        const char name[] = "ft_screens";
        memcpy(to.sun_path + 1, name, sizeof name - 1);
        sendto(fd, "state", 5, 0, reinterpret_cast<sockaddr *>(&to), socklen_t(offsetof(sockaddr_un, sun_path) + 1 + sizeof name - 1));
        pollfd p{fd, POLLIN, 0};
        if (poll(&p, 1, 100) <= 0) return;  // ft-screens not answering: keep the last state
        const ssize_t n = recv(fd, buf, sizeof buf - 1, 0);
        if (n <= 0) return;
        buf[n] = 0;
        // "ok <mode> <manual> <wrist> <hand> <gesture> <controllers> <game 0|1> <ingames>"
        char mode[32], hand[16], lasers[32], ingames[16];
        int manual = 0, running = 0;
        double wrist = 0, gesture = 0;
        if (sscanf(buf, "ok %31s %d %lf %15s %lf %31s %d %15s", mode, &manual, &wrist, hand, &gesture, lasers, &running,
                   ingames) == 8)
            game = running != 0, hide = strcmp(ingames, "visible") != 0, known = true;
    }
    bool Yield() const { return known && game && hide; }
} g_game;

// ---- --latency-test: input-to-decoded-frame round trips (one clock: the Frame's) -------------
// The main loop moves the PC's cursor to a far spot B, waits, then onto spot A and arms t0. The
// decoder thread keeps a copy of the luma box at A from every frame while disarmed (the
// baseline: A without the cursor) and, once armed, reports the first frame whose box differs
// (the arrow drawn there by the PC's capture).
struct LatTest {
    std::atomic<int64_t> t0{0};  // armed at this MonoNs; 0 = disarmed
    std::atomic<int64_t> hitNs{0};
    int ax = 0, ay = 0;          // spot A (stream pixels)
    static constexpr int BW = 24, BH = 32;
    uint8_t base[BW * BH] = {};
    bool haveBase = false;
    std::vector<double> ms;      // results (main thread)
    std::vector<double> hostMs;  // Sunshine's host processing for the detected frames
    std::atomic<double> lastHost{0};
    int64_t armedNs = 0;         // main thread's copy of t0
    int misses = 0;
} g_lat;

void LatCheck(int capIdx, int frame);

// State for ftrd-presence (the PC-side link, see remote-display/host/README.md): what this
// instance shows, as JSON in $FTRD_STATE_FILE, rewritten on every change.
void WriteState(bool suspended, bool busy = false) {
    const char *path = getenv("FTRD_STATE_FILE");
    if (!path) return;
    const std::string tmp = std::string(path) + ".tmp";
    FILE *f = fopen(tmp.c_str(), "w");
    if (!f) return;
    fprintf(f, "{\"pid\": %d, \"app\": \"%s\", \"keys\": \"%s\", \"wl_id\": \"%s\", \"w\": %d, \"h\": %d, \"window\": %s, \"suspended\": %s, \"busy\": %s}\n",
            int(getpid()), g_o.app.c_str(), g_o.keys.c_str(), g_o.wl ? g_o.wlId.c_str() : "", g_o.w, g_o.h,
            g_o.wl ? "true" : "false", suspended ? "true" : "false", busy ? "true" : "false");
    fclose(f);
    rename(tmp.c_str(), path);
}

}  // namespace
#include "wlwin.h"
namespace {

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

// Returns true when the capture buffer stays out of the decoder (window mode: until KWin
// releases it).
bool ShowFrame(int capIdx, int frame) {
    const int64_t c0 = MonoNs();
    double convMs = 0;
    if (g_o.wl) {
        const Slot &s = g_slots[frame % kSlots];
        if (s.frame == frame) {
            std::lock_guard<std::mutex> l(g_mu);
            for (Window *w : {&g_win, &g_all}) {
                w->decMs.push_back((c0 - s.tQueued) / 1e6), w->convMs.push_back(0);
                if (s.hostMs > 0) w->hostMs.push_back(s.hostMs);
            }
        }
        WlQueueFrame(capIdx, frame);
        return true;
    }
#ifdef FTRD_GL
    if (!g_rgbReady) {
        g_rgb.bt709 = true;  // Sunshine is asked for BT.709 limited range (COLORSPACE_REC_709)
        if (!RgbInit(g_rgb, int(g_D.visible.width), int(g_D.visible.height))) { g_stop = 1; return false; }
        g_rgbReady = true;
    }
    Rgb::Out *ro = RgbConvert(g_rgb, g_D, capIdx);
    convMs = (MonoNs() - c0) / 1e6;
    if (!ro) return false;
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
                return false;
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
    return false;
}

void LatCheck(int capIdx, int frame) {
    const auto &pm = g_D.capFmt.fmt.pix_mp;
    const uint8_t *y = static_cast<const uint8_t *>(g_D.cap[size_t(capIdx)].map[0]);
    if (!y || g_lat.ax + LatTest::BW > int(g_D.visible.width) || g_lat.ay + LatTest::BH > int(g_D.visible.height)) return;
    const size_t stride = pm.plane_fmt[0].bytesperline;
    uint8_t box[LatTest::BW * LatTest::BH];
    for (int r = 0; r < LatTest::BH; ++r)
        memcpy(box + r * LatTest::BW, y + size_t(g_lat.ay + r) * stride + size_t(g_lat.ax), LatTest::BW);
    const int64_t t0 = g_lat.t0.load();
    if (!t0 || !g_lat.haveBase) {
        memcpy(g_lat.base, box, sizeof box);
        g_lat.haveBase = true;
        return;
    }
    int changed = 0;
    for (int i = 0; i < LatTest::BW * LatTest::BH; ++i) changed += std::abs(int(box[i]) - int(g_lat.base[i])) > 40;
    if (changed < 20) return;  // the arrow is ~100+ pixels of the box; noise/encoding is a few
    const Slot &s = g_slots[frame % kSlots];
    g_lat.lastHost = s.frame == frame ? s.hostMs : 0;
    g_lat.hitNs = MonoNs();
    g_lat.t0 = 0;
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
                if (g_o.latencyTrials) LatCheck(int(b.index), frame);
                if (ShowFrame(int(b.index), frame)) {  // window mode: KWin gives it back
                    if (frame >= target) gotTarget = true;
                    continue;
                }
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

// ---- input (M3) ------------------------------------------------------------------------
#ifdef FTRD_VR
vr::VROverlayHandle_t g_kbButton = vr::k_ulOverlayHandleInvalid;
bool g_kbShown = false;
int g_buttonsHeld = 0;  // bitmask of BUTTON_* held on the PC
uint64_t g_inMoves = 0, g_inClicks = 0, g_inScrolls = 0, g_inChars = 0, g_inKeys = 0;

int MlButton(uint32_t vrButton) {
    switch (vrButton) {
        case vr::VRMouseButton_Left: return BUTTON_LEFT;
        case vr::VRMouseButton_Right: return BUTTON_RIGHT;
        case vr::VRMouseButton_Middle: return BUTTON_MIDDLE;
        default: return 0;
    }
}

void ReleaseButtons() {
    for (int b : {BUTTON_LEFT, BUTTON_RIGHT, BUTTON_MIDDLE})
        if (g_buttonsHeld & (1 << b)) LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, b);
    g_buttonsHeld = 0;
}

void TapKey(short vk) {
    LiSendKeyboardEvent(short(0x8000 | vk), KEY_ACTION_DOWN, 0);
    LiSendKeyboardEvent(short(0x8000 | vk), KEY_ACTION_UP, 0);
    ++g_inKeys;
}

// One VREvent_KeyboardCharInput: up to 7 bytes of UTF-8 (or a control character).
void KeyboardInput(const char *in) {
    const std::string s(in, strnlen(in, 8));
    if (s.empty()) return;
    if (static_cast<unsigned char>(s[0]) < 0x20 || s[0] == 0x7f) {  // log control keys only, never typed text
        printf("input: control key from SteamVR keyboard:");
        for (unsigned char c : s) printf(" %02x", c);
        printf("\n");
    }
    if (s == "\b" || s == "\x7f") return TapKey(0x08);              // VK_BACK
    if (s == "\n" || s == "\r") return TapKey(0x0D);                // VK_RETURN
    if (s == "\t") return TapKey(0x09);                             // VK_TAB
    if (s == "\x1b") return TapKey(0x1B);                           // VK_ESCAPE
    if (s == "\x1b[A") return TapKey(0x26);                         // arrows, if the keyboard sends them
    if (s == "\x1b[B") return TapKey(0x28);
    if (s == "\x1b[C") return TapKey(0x27);
    if (s == "\x1b[D") return TapKey(0x25);
    LiSendUtf8TextEvent(s.data(), unsigned(s.size()));
    ++g_inChars;
}

void ToggleKeyboard() {
    if (g_kbShown) {
        vr::VROverlay()->HideKeyboard();
        g_kbShown = false;
        return;
    }
    auto show = [] {
        return vr::VROverlay()->ShowKeyboardForOverlay(
            g_ov, vr::k_EGamepadTextInputModeNormal, vr::k_EGamepadTextInputLineModeSingleLine,
            vr::KeyboardFlag_Minimal | vr::KeyboardFlag_ShowArrowKeys, "Remote PC", 256, "", 0);
    };
    auto e = show();
    if (e == vr::VROverlayError_KeyboardAlreadyInUse) {
        // SteamVR's keyboard "follows overlay focus": it may already be up, opened for our button
        // (or someone else). Close it and open it for the panel.
        vr::VROverlay()->HideKeyboard();
        usleep(100000);
        e = show();
    }
    if (e != vr::VROverlayError_None) printf("input: ShowKeyboardForOverlay failed: %s\n",
                                             vr::VROverlay()->GetOverlayErrorNameFromEnum(e));
    else g_kbShown = true, printf("input: keyboard shown\n");
}

void PollInput() {
    vr::VREvent_t ev;
    while (vr::VROverlay()->PollNextOverlayEvent(g_ov, &ev, sizeof ev)) {
        switch (ev.eventType) {
            case vr::VREvent_MouseMove: {  // GL space: origin bottom left, scaled to the stream size
                const int x = std::clamp(int(ev.data.mouse.x), 0, g_o.w - 1);
                const int y = std::clamp(g_o.h - 1 - int(ev.data.mouse.y), 0, g_o.h - 1);
                LiSendMousePositionEvent(short(x), short(y), short(g_o.w), short(g_o.h));
                ++g_inMoves;
                break;
            }
            case vr::VREvent_MouseButtonDown:
            case vr::VREvent_MouseButtonUp: {
                const int b = MlButton(ev.data.mouse.button);
                if (!b) break;
                const bool down = ev.eventType == vr::VREvent_MouseButtonDown;
                LiSendMouseButtonEvent(down ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, b);
                if (down) g_buttonsHeld |= 1 << b, ++g_inClicks;
                else g_buttonsHeld &= ~(1 << b);
                break;
            }
            case vr::VREvent_ScrollDiscrete: {  // notches; positive = up/right, as on the PC
                const int dy = int(std::lround(ev.data.scroll.ydelta)), dx = int(std::lround(ev.data.scroll.xdelta));
                if (dy) LiSendScrollEvent((signed char)std::clamp(dy, -127, 127));
                if (dx) LiSendHScrollEvent((signed char)std::clamp(-dx, -127, 127));  // SteamVR +x = left (as in screens/vr.cpp)
                ++g_inScrolls;
                break;
            }
            case vr::VREvent_FocusLeave:  // laser left the panel: don't leave a button held on the PC
                ReleaseButtons();
                break;
            case vr::VREvent_KeyboardCharInput:
                KeyboardInput(ev.data.keyboard.cNewInput);
                break;
            case vr::VREvent_KeyboardClosed:
            case vr::VREvent_KeyboardDone:
                g_kbShown = false;
                break;
            default:
                break;
        }
    }
    while (g_kbButton != vr::k_ulOverlayHandleInvalid &&
           vr::VROverlay()->PollNextOverlayEvent(g_kbButton, &ev, sizeof ev)) {
        if (ev.eventType == vr::VREvent_MouseButtonUp && ev.data.mouse.button == vr::VRMouseButton_Left)
            ToggleKeyboard();
        else if (ev.eventType == vr::VREvent_KeyboardCharInput)  // keyboard opened for the button
            KeyboardInput(ev.data.keyboard.cNewInput);
        else if (ev.eventType == vr::VREvent_KeyboardClosed || ev.eventType == vr::VREvent_KeyboardDone)
            g_kbShown = false;
    }
}

// A 128x128 keyboard icon: dark rounded tile, three rows of light keys and a space bar.
void MakeKeyboardButton(const vr::HmdMatrix34_t &panel, double panelW, double panelH) {
    if (vr::VROverlay()->CreateOverlay("frametop.ftrdstream.kb", "Remote keyboard", &g_kbButton) !=
        vr::VROverlayError_None) {
        g_kbButton = vr::k_ulOverlayHandleInvalid;
        return;
    }
    constexpr int N = 128;
    static uint8_t px[N * N * 4];
    for (int y = 0; y < N; ++y)
        for (int x = 0; x < N; ++x) {
            uint8_t *p = px + (y * N + x) * 4;
            const int cx = std::min(x, N - 1 - x), cy = std::min(y, N - 1 - y);
            const bool inside = !(cx < 12 && cy < 12 && (12 - cx) * (12 - cx) + (12 - cy) * (12 - cy) > 144);
            bool key = false;
            for (int row = 0; row < 3; ++row) {
                const int y0 = 30 + row * 20;
                if (y >= y0 && y < y0 + 14)
                    for (int k = 0; k < 7; ++k) {
                        const int x0 = 16 + row * 4 + k * 14;
                        if (x >= x0 && x < x0 + 10 && x0 + 10 <= 116) key = true;
                    }
            }
            if (y >= 92 && y < 104 && x >= 36 && x < 92) key = true;
            const uint8_t v = key ? 230 : 40;
            p[0] = p[1] = p[2] = v;
            p[3] = inside ? 235 : 0;
        }
    vr::VROverlay()->SetOverlayRaw(g_kbButton, px, N, N, 4);
    vr::VROverlay()->SetOverlayWidthInMeters(g_kbButton, 0.14f);
    vr::HmdVector2_t scale = {float(N), float(N)};
    vr::VROverlay()->SetOverlayMouseScale(g_kbButton, &scale);
    vr::VROverlay()->SetOverlayInputMethod(g_kbButton, vr::VROverlayInputMethod_Mouse);
    vr::VROverlay()->SetOverlayFlag(g_kbButton, vr::VROverlayFlags_MakeOverlaysInteractiveIfVisible, true);
    // Below the panel's bottom-right corner, in the panel's plane.
    const double lx = panelW / 2 - 0.10, ly = -panelH / 2 - 0.11;
    vr::HmdMatrix34_t B = panel;
    for (int r = 0; r < 3; ++r) B.m[r][3] = float(panel.m[r][3] + panel.m[r][0] * lx + panel.m[r][1] * ly);
    vr::VROverlay()->SetOverlayTransformAbsolute(g_kbButton, vr::TrackingUniverseStanding, &B);
    vr::VROverlay()->ShowOverlay(g_kbButton);
}
#endif

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
        else if (a == "--check") g_o.check = true;
        else if (a == "--host") g_o.host = next();
        else if (a == "--app") g_o.app = next();
        else if (a == "--app-id") g_o.appId = atoi(next());  // e.g. a Vibepollo control the list hides
        else if (a == "--wl-id") g_o.wlId = next();
        else if (a == "--no-yield") g_o.yield = false;
        else if (a == "--title") g_o.wlTitle = next();
        else if (a == "--follow-size") g_o.follow = true, g_o.followSet = true;
        else if (a == "--no-follow-size") g_o.follow = false, g_o.followSet = true;
        else if (a == "--size") sscanf(next(), "%dx%d", &g_o.w, &g_o.h);
        else if (a == "--fps") g_o.fps = atoi(next());
        else if (a == "--bitrate") g_o.bitrate = atoi(next());
        else if (a == "--codec") g_o.hevc = std::string(next()) != "h264";
        else if (a == "--panel-width") g_o.panelW = atof(next());
        else if (a == "--distance") g_o.dist = atof(next());
        else if (a == "--seconds") g_o.seconds = atof(next());
        else if (a == "--novr") g_o.vr = false;
        else if (a == "--window") {
            g_o.wl = true, g_o.vr = false;
            if (i + 1 < argc && argv[i + 1][0] != '-') sscanf(argv[++i], "%dx%d", &g_o.winW, &g_o.winH);
        }
        else if (a == "--latency-test") g_o.latencyTrials = atoi(next());
        else if (a == "--input-test") g_o.inputTest = true;  // 3 s in: move the PC's cursor to (1234, 567)
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
    if (g_o.check) return server.paired ? 0 : 3;
    // Vibepollo's "Desktop" app makes its own virtual screen the PC's only display (the physical
    // monitors go dark until it lets go); id 0 starts it too.
    if ((g_o.app == "Desktop" || g_o.appId == 0) && !getenv("FTRD_ALLOW_DESKTOP"))
        return fprintf(stderr, "refusing the \"Desktop\" app (on Vibepollo it blanks the PC's monitors); "
                               "FTRD_ALLOW_DESKTOP=1 to force\n"), 1;
    if (!server.paired) return fprintf(stderr, "not paired: run with --pair PIN first\n"), 1;

    PAPP_LIST apps = nullptr;
    int appId = -1;
    auto find = [&](const char *name) {
        apps = nullptr;
        int id = -1;
        if (gs_applist(&server, &apps) == GS_OK)
            for (PAPP_LIST a = apps; a; a = a->next)
                if (!strcmp(name, a->name)) id = a->id;
        return id;
    };
    appId = g_o.appId >= 0 ? g_o.appId : find(g_o.app.c_str());
    // Vibepollo keeps a client's Remote Monitor (its virtual display) after the stream ends, and
    // then lists only "Resume" and "Disconnect Monitor" to that client; Resume can't change the
    // display's size. So release it and ask again, for the size we want (~3 s).
    if (appId < 0 && g_o.app == "Remote Monitor") {
        const int disc = find("Disconnect Monitor");
        if (disc >= 0) {
            STREAM_CONFIGURATION c;
            LiInitializeStreamConfiguration(&c);
            c.width = g_o.w, c.height = g_o.h, c.fps = g_o.fps, c.bitrate = g_o.bitrate;
            gs_start_app(&server, &c, disc, false, true, 0);  // replies with an "error" that says it worked
            printf("host: released this client's previous Remote Monitor (%s)\n", gs_error ? gs_error : "");
            server.currentGame = 0;  // libgamestream "resumes" when this is set; launch afresh
            for (int i = 0; i < 20 && appId < 0; ++i) {
                appId = g_o.appId >= 0 ? g_o.appId : find(g_o.app.c_str());
                if (appId < 0) usleep(250000);
            }
        }
    }
    if (appId < 0) {
        fprintf(stderr, "app \"%s\" not found on the server; it lists:\n", g_o.app.c_str());
        for (PAPP_LIST a = apps; a; a = a->next) fprintf(stderr, "  %d  %s\n", a->id, a->name);
        return 1;
    }

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
        // Input: SteamVR's laser mouse, in stream pixels; controllers work with the dashboard closed.
        vr::HmdVector2_t mscale = {float(g_o.w), float(g_o.h)};
        vr::VROverlay()->SetOverlayMouseScale(g_ov, &mscale);
        vr::VROverlay()->SetOverlayInputMethod(g_ov, vr::VROverlayInputMethod_Mouse);
        vr::VROverlay()->SetOverlayFlag(g_ov, vr::VROverlayFlags_SendVRDiscreteScrollEvents, true);
        vr::VROverlay()->SetOverlayFlag(g_ov, vr::VROverlayFlags_MakeOverlaysInteractiveIfVisible, true);
        MakeKeyboardButton(P, g_o.panelW, g_o.panelW * g_o.h / g_o.w);
        vr::ETrackedPropertyError pe;
        g_comp.hz = vr::VRSystem()->GetFloatTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd,
                                                                  vr::Prop_DisplayFrequency_Float, &pe);
        SampleComp(g_comp);
    }
#endif

    if (g_o.wl && !WlInit(g_o.w, g_o.h, g_o.winW ? g_o.winW : g_o.w, g_o.winH ? g_o.winH : g_o.h, g_o.wlId.c_str(),
                          g_o.wlTitle.c_str()))
        return 1;
    if (!g_o.followSet) g_o.follow = g_o.wl && g_o.app == "Remote Monitor";
    if (g_o.follow) {
        // ft-floatd sizes the window to its panel right after it maps; start the monitor at that
        // size rather than reconnecting (and re-jogging the PC's displays) a second later.
        const int64_t w0 = MonoNs();
        while (MonoNs() - w0 < 4000000000LL) {
            WlPoll(50, [](int) {});
            if (g_wl.closed) return 1;
            if (g_wl.winW > 0 && MonoNs() - g_wl.resizedNs > 1200000000LL && MonoNs() - w0 > 1500000000LL) break;
        }
        if (g_wl.winW > 0 && g_wl.winH > 0) {
            const int w = std::clamp(g_wl.winW & ~7, 640, 7680), h = std::clamp(g_wl.winH & ~7, 360, 4320);
            if (w != g_o.w || h != g_o.h) {
                printf("window: %dx%d after %.1f s; monitor starts at %dx%d\n", g_wl.winW, g_wl.winH, (MonoNs() - w0) / 1e9, w, h);
                g_o.w = w, g_o.h = h, cfg.width = w, cfg.height = h;
                WlNewStream(w, h);
            }
        }
    }
    WriteState(false, true);

  auto launch = [&]() -> int {
    r = gs_start_app(&server, &cfg, appId, false, true /* audio stays on the PC */, 0);
    // Vibepollo 2.0.0: when the PC's primary monitor isn't the one Windows would put at 0,0, its
    // first Remote Monitor attempt fails ("composed display topology did not apply") and leaves
    // Windows' default arrangement, from which another attempt usually works. A failed attempt
    // can leave this client owning a half-made monitor, so release it before each retry.
    // Another client's start or resize is in progress on the host: wait for it.
    for (int attempt = 1; attempt <= 10 && r != GS_OK && gs_error && strstr(gs_error, "still running"); ++attempt) {
        printf("host: busy with another stream; retry %d/10 in 2 s\n", attempt);
        sleep(2);
        server.currentGame = 0;
        r = gs_start_app(&server, &cfg, appId, false, true, 0);
    }
    // "not yet capture-ready": a monitor of this client's is stuck at another size. Same cure.
    // Each attempt makes Vibepollo re-jog the PC's whole display topology (all screens blink), so
    // back off rather than hammer it: 3 s, 6 s.
    for (int attempt = 1; attempt <= 2 && r != GS_OK && gs_error &&
                          (strstr(gs_error, "did not apply") || strstr(gs_error, "not yet capture-ready"));
         ++attempt) {
        printf("host: \"%s\"; release and retry (%d/2) in %d s\n", gs_error, attempt, 3 * attempt);
        server.currentGame = 0;
        gs_start_app(&server, &cfg, 2147483502 /* Disconnect Monitor */, false, true, 0);
        sleep(3 * attempt);
        server.currentGame = 0;
        r = gs_start_app(&server, &cfg, appId, false, true, 0);
    }
    if (r != GS_OK) return fprintf(stderr, "starting %s failed (%d): %s\n", g_o.app.c_str(), r, gs_error ? gs_error : ""), 1;
    printf("app: %s started at %dx%d %d fps %d kbps %s\n", g_o.app.c_str(), cfg.width, cfg.height, cfg.fps,
           cfg.bitrate, g_o.hevc ? "HEVC" : "H.264");
    return 0;
  };
    if (launch()) return 1;
    WriteState(false);

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
    int64_t lastResize = MonoNs();
    int64_t retryAt = 0;
    int retries = 0;
    auto reconnect = [&]() -> bool {  // launch + connect; on failure schedule a retry
        if (retries && g_o.app == "Remote Monitor") {  // a failed attempt may have left a half-made monitor
            server.currentGame = 0;
            gs_start_app(&server, &cfg, 2147483502 /* Disconnect Monitor */, false, true, 0);
            sleep(2);
        }
        server.currentGame = 0;
        if (launch() == 0) {
            r = LiStartConnection(&server.serverInfo, &cfg, &cl, &dr, nullptr, nullptr, 0, nullptr, 0);
            if (r == 0) { retries = 0; WriteState(false); return true; }
            fprintf(stderr, "LiStartConnection failed (%d)\n", r);
            gs_quit_app(&server);
        }
        ++retries;
        retryAt = MonoNs() + int64_t(std::min(5 * retries, 20)) * 1000000000LL;
        WriteState(false, true);
        return false;
    };
    bool suspended = false;
    int64_t suspendedAt = 0;
    const CpuStat cpu0 = ReadCpu();
    int64_t lastSample = MonoNs();
    bool inputTested = false;
    auto committed = [](int frame) {  // window mode: a frame went to KWin
        const Slot &s = g_slots[frame % kSlots];
        if (s.frame != frame) return;
        const double client = (LiGetMicroseconds() - s.recvUs) / 1e3;
        std::lock_guard<std::mutex> l(g_mu);
        for (Window *w : {&g_win, &g_all}) ++w->frames, w->clientMs.push_back(client);
        ++g_shown;
    };
    while (!g_stop && !g_terminated) {
        if (g_o.wl) {
            WlPoll(50, committed);
            if (g_wl.closed) { printf("window: closed (or the desktop went away)\n"); break; }
        } else {
            usleep(4000);
        }
        const int64_t now = MonoNs();
#ifdef FTRD_VR
        if (g_o.vr) {
            PollInput();
            if (now - lastSample >= 250000000) SampleComp(g_comp), lastSample = now;
        }
#endif
        if (g_o.inputTest && !inputTested && (now - t0) / 1e9 >= 3) {
            const int r2 = LiSendMousePositionEvent(1234, 567, short(g_o.w), short(g_o.h));
            printf("input-test: sent absolute mouse (1234, 567) of %dx%d -> %d\n", g_o.w, g_o.h, r2);
            inputTested = true;
        }
        // --latency-test state machine: 0 = wait for video, 1 = cursor at B, 2 = armed (cursor sent to A)
        if (g_o.latencyTrials && !suspended) {
            static int phase = 0, done = 0;
            static int64_t at = 0;
            static unsigned rnd = 12345;
            const short W = short(g_o.w), H = short(g_o.h);
            if (phase == 0 && g_shown.load() > 0 && (now - t0) / 1e9 >= 3) {
                g_lat.ax = g_o.w / 4, g_lat.ay = g_o.h / 4;
                LiSendMousePositionEvent(short(g_o.w * 3 / 4), short(g_o.h * 3 / 4), W, H);
                phase = 1, at = now;
            } else if (phase == 1) {
                rnd = rnd * 1103515245u + 12345u;
                // 300 ms at B, plus 0-33 ms so the moves land at random points of the capture cycle
                if (now - at >= 300000000LL + int64_t((rnd >> 8) % 33000) * 1000) {
                    g_lat.hitNs = 0;
                    g_lat.armedNs = MonoNs();
                    g_lat.t0 = g_lat.armedNs;
                    // FTRD_LAT_CONTROL=1: a negative control, the cursor goes elsewhere (expect misses)
                    if (getenv("FTRD_LAT_CONTROL")) LiSendMousePositionEvent(short(g_o.w / 4), short(g_o.h * 3 / 4), W, H);
                    else LiSendMousePositionEvent(short(g_lat.ax), short(g_lat.ay), W, H);
                    phase = 2, at = now;
                }
            } else if (phase == 2) {
                if (g_lat.t0.load() == 0 && g_lat.hitNs.load()) {
                    const double ms = (g_lat.hitNs.load() - g_lat.armedNs) / 1e6;
                    g_lat.ms.push_back(ms), g_lat.hostMs.push_back(g_lat.lastHost.load());
                    ++done;
                } else if (now - g_lat.armedNs > 1000000000LL) {
                    g_lat.t0 = 0, ++g_lat.misses, ++done;
                    printf("latency: trial %d: no change seen in 1 s\n", done);
                }
                if (g_lat.t0.load() == 0) {
                    if (done >= g_o.latencyTrials) break;
                    LiSendMousePositionEvent(short(g_o.w * 3 / 4), short(g_o.h * 3 / 4), W, H);
                    phase = 1, at = now;
                }
            }
        }
        if (now - lastPrint >= 5000000000LL) {
            std::lock_guard<std::mutex> l(g_mu);
            PrintWindow("stats", g_win, (now - lastPrint) / 1e9);
            if (g_o.wl && g_wl.moves && getenv("FTRD_POINTER_DEBUG")) WlPrintLows();
            g_win.Clear();
            lastPrint = now;
        }
        if (g_o.seconds > 0 && (now - t0) / 1e9 >= g_o.seconds) break;
        // Yield to VR games: stop the connection while one runs, resume when it ends.
        if (g_o.yield) {
            g_game.Ask(now);
            if (g_game.Yield() && !suspended) {
                const int64_t s0 = MonoNs();
                printf("game: a VR game is running; stream suspended\n");
                LiStopConnection();  // the decoder is released (DrCleanup); Vibepollo keeps the monitor
                // Frames still queued for the window point at capture buffers that are gone now.
                if (g_o.wl) WlNewStream(g_o.w, g_o.h);
#ifdef FTRD_VR
                if (g_o.vr) {
                    vr::VROverlay()->HideOverlay(g_ov), g_ovShown = false;
                    if (g_kbButton != vr::k_ulOverlayHandleInvalid) vr::VROverlay()->HideOverlay(g_kbButton);
                    if (g_kbShown) vr::VROverlay()->HideKeyboard(), g_kbShown = false;
                    ReleaseButtons();
                }
#endif
                if (g_o.wl) WlReleaseKeys(), PtrLeave(nullptr, nullptr, 0, nullptr);
                suspended = true, suspendedAt = now;
                WriteState(true);
                printf("game: suspended in %.2f s\n", (MonoNs() - s0) / 1e9);
            } else if (!g_game.Yield() && suspended) {
                const int64_t s0 = MonoNs();
                printf("game: ended after %.0f s; resuming\n", (now - suspendedAt) / 1e9);
                if (g_o.app == "Remote Monitor") {
                    // Vibepollo kept the monitor; its "Resume" control (a launch, not /resume)
                    // reattaches to it at the same size, so the PC's windows stay put.
                    server.currentGame = 0;
                    r = gs_start_app(&server, &cfg, 2147483501 /* Resume */, false, true, 0);
                    if (r != GS_OK) {
                        printf("game: Resume failed (%s); starting a new monitor\n", gs_error ? gs_error : "?");
                        server.currentGame = 0;
                        gs_start_app(&server, &cfg, 2147483502 /* Disconnect Monitor */, false, true, 0);
                        server.currentGame = 0;
                        if (launch()) { g_termError = 1; g_terminated = true; break; }
                    }
                } else if (launch()) { g_termError = 1; g_terminated = true; break; }
                r = LiStartConnection(&server.serverInfo, &cfg, &cl, &dr, nullptr, nullptr, 0, nullptr, 0);
                if (r != 0) { fprintf(stderr, "LiStartConnection failed (%d)\n", r); g_termError = 1; break; }
#ifdef FTRD_VR
                if (g_o.vr && g_kbButton != vr::k_ulOverlayHandleInvalid) vr::VROverlay()->ShowOverlay(g_kbButton);
#endif
                suspended = false;
                WriteState(false);
                printf("game: resumed in %.1f s\n", (MonoNs() - s0) / 1e9);
            }
            if (suspended) continue;
        }
        // Follow the window's size: reconnect at it once it has settled.
        if (g_o.follow && g_wl.winW > 0 && g_wl.winH > 0 && now - g_wl.resizedNs > 1500000000LL &&
            now - lastResize > 3000000000LL && !retryAt) {
            const int w = std::clamp(g_wl.winW & ~7, 640, 7680), h = std::clamp(g_wl.winH & ~7, 360, 4320);
            if (std::abs(w - g_o.w) > 8 || std::abs(h - g_o.h) > 8) {
                lastResize = now;
                printf("resize: window %dx%d -> stream %dx%d (was %dx%d)\n", g_wl.winW, g_wl.winH, w, h, g_o.w, g_o.h);
                const int64_t r0 = MonoNs();
                LiStopConnection();
                gs_quit_app(&server);
                if (g_o.app == "Remote Monitor") {
                    server.currentGame = 0;
                    gs_start_app(&server, &cfg, 2147483502 /* Disconnect Monitor */, false, true, 0);
                }
                server.currentGame = 0;
                g_o.w = w, g_o.h = h, cfg.width = w, cfg.height = h;
                WlNewStream(w, h);
                WriteState(false, true);
                sleep(2);  // let Vibepollo finish removing the old monitor ("not yet capture-ready")
                if (reconnect()) printf("resize: reconnected in %.1f s\n", (MonoNs() - r0) / 1e9);
            }
        }
        // A failed reconnect keeps the window (last frame) and tries again, gently.
        if (retryAt && now >= retryAt) {
            retryAt = 0;
            printf("reconnect: retry %d/6\n", retries);
            if (reconnect()) printf("reconnect: ok\n");
            else if (retries >= 6) { fprintf(stderr, "reconnect: giving up\n"); g_termError = 1; break; }
        }
    }
    const double wall = (MonoNs() - t0) / 1e9;
    const CpuStat cpu1 = ReadCpu();
#ifdef FTRD_VR
    if (g_o.vr) {
        ReleaseButtons();
        if (g_kbShown) vr::VROverlay()->HideKeyboard();
    }
#endif
    if (g_o.wl) {
        WlReleaseKeys();
        PtrLeave(nullptr, nullptr, 0, nullptr);  // releases the PC's mouse buttons
    }
    if (const char *sf = getenv("FTRD_STATE_FILE")) unlink(sf);
    if (!suspended) LiStopConnection();
    gs_quit_app(&server);
    // Vibepollo keeps a Remote Monitor's virtual display after the stream ends, and with two
    // clients its deferred cleanup can leave one behind. Release ours explicitly.
    if (g_o.app == "Remote Monitor") {
        server.currentGame = 0;
        gs_start_app(&server, &cfg, 2147483502 /* Disconnect Monitor */, false, true, 0);
        printf("host: released the Remote Monitor (%s)\n", gs_error ? gs_error : "ok");
    }
    {
        std::lock_guard<std::mutex> l(g_mu);
        printf("\nRESULT %s %dx%d %s %d kbps, %.1f s, %llu frames shown\n", g_o.host.c_str(), g_o.w, g_o.h,
               g_o.hevc ? "HEVC" : "H.264", g_o.bitrate, wall, (unsigned long long)g_shown.load());
        PrintWindow("  all", g_all, wall);
        if (g_o.latencyTrials) {
            std::vector<double> v = g_lat.ms;
            std::sort(v.begin(), v.end());
            printf("  latency-test: %zu/%d trials | input->decoded frame median %.1f ms, p10 %.1f, p90 %.1f, min %.1f, max %.1f"
                   " | host (capture+encode) median %.1f ms | rtt/2 included | %d misses\n",
                   v.size(), g_o.latencyTrials, Pct(v, 50), Pct(v, 10), Pct(v, 90), v.empty() ? NAN : v.front(),
                   v.empty() ? NAN : v.back(), Pct(g_lat.hostMs, 50), g_lat.misses);
            printf("  latency-test raw:");
            for (double x : g_lat.ms) printf(" %.1f", x);
            printf("\n");
        }
        if (g_o.wl)
            printf("  window: %llu commits; input %llu moves, %llu clicks, %llu scrolls, %llu keys; pointer lowest row %d of %d\n",
                   (unsigned long long)g_wl.commits, (unsigned long long)g_wl.moves, (unsigned long long)g_wl.clicks,
                   (unsigned long long)g_wl.scrolls, (unsigned long long)g_wl.keys, g_wl.lowY, g_wl.streamH);
        printf("  SoC busy %.1f%% of 8 cores\n",
               cpu1.total > cpu0.total ? 100.0 * double(cpu1.busy - cpu0.busy) / double(cpu1.total - cpu0.total) : NAN);
    }
#ifdef FTRD_VR
    if (g_o.vr) {
        PrintComp(g_comp, wall);
        printf("  input: %llu moves, %llu clicks, %llu scrolls, %llu chars, %llu keys\n",
               (unsigned long long)g_inMoves, (unsigned long long)g_inClicks, (unsigned long long)g_inScrolls,
               (unsigned long long)g_inChars, (unsigned long long)g_inKeys);
        if (g_kbButton != vr::k_ulOverlayHandleInvalid) vr::VROverlay()->DestroyOverlay(g_kbButton);
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
