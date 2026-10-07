// rdcore.h: shared pieces of the remote-display POC (M0 probe and M2 stream client).
// V4L2 stateful decoding on qcom-iris, GPU NV12 -> ABGR8888 conversion (EGL dmabuf import),
// SteamVR dmabuf import / compositor timing, and small stats helpers. Header-only: each
// program is one translation unit and includes this once.
// Build flags: -DFTRD_VR (OpenVR), -DFTRD_GL (EGL/GLES/GBM).
#pragma once
#include <linux/videodev2.h>
#include <drm_fourcc.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#ifdef FTRD_VR
#include <openvr.h>
#endif
#ifdef FTRD_GL
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <gbm.h>
#endif

#ifndef V4L2_PIX_FMT_QC08C
#define V4L2_PIX_FMT_QC08C v4l2_fourcc('Q', '0', '8', 'C')
#endif

namespace {

volatile sig_atomic_t g_stop = 0;
void Stop(int) { g_stop = 1; }

int64_t MonoNs() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return int64_t(t.tv_sec) * 1000000000 + t.tv_nsec;
}

int Xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do r = ioctl(fd, req, arg);
    while (r < 0 && errno == EINTR);
    return r;
}

std::string Fourcc(uint32_t f) {
    char s[5] = {char(f & 0xff), char((f >> 8) & 0xff), char((f >> 16) & 0xff), char((f >> 24) & 0xff), 0};
    return s;
}

// ---- Annex-B access-unit splitter ------------------------------------------------------
struct Au { size_t off, len; };

std::vector<Au> SplitAus(const std::vector<uint8_t> &d, bool hevc) {
    // NAL start positions (index of the first start-code byte) and payload starts.
    std::vector<std::pair<size_t, size_t>> nals;
    for (size_t i = 0; i + 3 < d.size(); ++i) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            size_t sc = (i > 0 && d[i - 1] == 0) ? i - 1 : i;
            nals.push_back({sc, i + 3});
            i += 2;
        }
    }
    std::vector<Au> aus;
    size_t auStart = nals.empty() ? 0 : nals[0].first;
    bool haveVcl = false;
    for (size_t k = 0; k < nals.size(); ++k) {
        const size_t p = nals[k].second;
        if (p + 2 >= d.size()) break;
        bool vcl, firstInPic = false, startsAu;
        if (!hevc) {
            const int t = d[p] & 0x1f;
            vcl = t >= 1 && t <= 5;
            if (vcl) firstInPic = d[p + 1] & 0x80;  // first_mb_in_slice == 0 -> ue(v) '1'
            startsAu = (vcl && firstInPic) || t == 6 || t == 7 || t == 8 || t == 9 || (t >= 14 && t <= 18);
        } else {
            const int t = (d[p] >> 1) & 0x3f;
            vcl = t <= 31;
            if (vcl) firstInPic = d[p + 2] & 0x80;  // first_slice_segment_in_pic_flag
            startsAu = (vcl && firstInPic) || (t >= 32 && t <= 35) || t == 39 || (t >= 41 && t <= 44) ||
                       (t >= 48 && t <= 55);
        }
        if (startsAu && haveVcl) {
            aus.push_back({auStart, nals[k].first - auStart});
            auStart = nals[k].first;
            haveVcl = false;
        }
        if (vcl) haveVcl = true;
    }
    if (haveVcl) aus.push_back({auStart, d.size() - auStart});
    return aus;
}

// ---- small stats helpers ---------------------------------------------------------------
double Pct(std::vector<double> v, double p) {
    if (v.empty()) return NAN;
    std::sort(v.begin(), v.end());
    size_t i = size_t(std::lround(p / 100.0 * double(v.size() - 1)));
    return v[std::min(i, v.size() - 1)];
}

struct CpuStat { uint64_t busy = 0, total = 0; };
CpuStat ReadCpu() {
    CpuStat c;
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return c;
    unsigned long long v[10] = {};
    if (fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5],
               &v[6], &v[7], &v[8], &v[9]) >= 8) {
        for (int i = 0; i < 8; ++i) c.total += v[i];
        c.busy = c.total - v[3] - v[4];  // minus idle and iowait
    }
    fclose(f);
    return c;
}

double ThermalC(const char *type) {
    for (int i = 0; i < 128; ++i) {
        char p[96], t[64] = {};
        snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone%d/type", i);
        FILE *f = fopen(p, "r");
        if (!f) continue;
        bool match = fgets(t, sizeof t, f) && !strncmp(t, type, strlen(type)) && (t[strlen(type)] == '\n');
        fclose(f);
        if (!match) continue;
        snprintf(p, sizeof p, "/sys/class/thermal/thermal_zone%d/temp", i);
        f = fopen(p, "r");
        long mc = 0;
        if (f && fscanf(f, "%ld", &mc) == 1) { fclose(f); return mc / 1000.0; }
        if (f) fclose(f);
    }
    return NAN;
}

// ---- the decoder ----------------------------------------------------------------------
struct OutBuf { void *map = nullptr; size_t len = 0; };
struct CapBuf {
    int fd[VIDEO_MAX_PLANES] = {-1, -1, -1, -1, -1, -1, -1, -1};
    void *map[VIDEO_MAX_PLANES] = {};
    size_t len[VIDEO_MAX_PLANES] = {};
    uint64_t vrHandle = 0;
};

struct Decoder {
    int fd = -1;
    uint32_t codec = 0, wantFmt = 0;
    std::vector<OutBuf> out;
    std::vector<int> freeOut;
    std::vector<CapBuf> cap;
    bool capOn = false;
    v4l2_format capFmt{};
    v4l2_rect visible{};
    int nCapPlanes = 0;
    int sourceChanges = 0;
};

bool SetupOutput(Decoder &D, size_t maxAu, int w = 1920, int h = 1080) {
    v4l2_format f{};
    f.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    f.fmt.pix_mp.pixelformat = D.codec;
    f.fmt.pix_mp.width = uint32_t(w);
    f.fmt.pix_mp.height = uint32_t(h);
    f.fmt.pix_mp.num_planes = 1;
    f.fmt.pix_mp.plane_fmt[0].sizeimage = uint32_t(std::max<size_t>(maxAu + maxAu / 4, 2 << 20));
    if (Xioctl(D.fd, VIDIOC_S_FMT, &f) < 0) return perror("S_FMT output"), false;
    v4l2_requestbuffers rb{};
    rb.count = 8;
    rb.type = f.type;
    rb.memory = V4L2_MEMORY_MMAP;
    if (Xioctl(D.fd, VIDIOC_REQBUFS, &rb) < 0) return perror("REQBUFS output"), false;
    D.out.resize(rb.count);
    for (unsigned i = 0; i < rb.count; ++i) {
        v4l2_plane pl[VIDEO_MAX_PLANES]{};
        v4l2_buffer b{};
        b.type = f.type, b.memory = V4L2_MEMORY_MMAP, b.index = i, b.length = 1, b.m.planes = pl;
        if (Xioctl(D.fd, VIDIOC_QUERYBUF, &b) < 0) return perror("QUERYBUF output"), false;
        D.out[i].len = pl[0].length;
        D.out[i].map = mmap(nullptr, pl[0].length, PROT_READ | PROT_WRITE, MAP_SHARED, D.fd, pl[0].m.mem_offset);
        if (D.out[i].map == MAP_FAILED) return perror("mmap output"), false;
        D.freeOut.push_back(int(i));
    }
    for (uint32_t ev : {uint32_t(V4L2_EVENT_SOURCE_CHANGE), uint32_t(V4L2_EVENT_EOS)}) {
        v4l2_event_subscription s{};
        s.type = ev;
        if (Xioctl(D.fd, VIDIOC_SUBSCRIBE_EVENT, &s) < 0) perror("SUBSCRIBE_EVENT");
    }
    int t = f.type;
    if (Xioctl(D.fd, VIDIOC_STREAMON, &t) < 0) return perror("STREAMON output"), false;
    printf("output: %s, %u buffers of %zu bytes\n", Fourcc(D.codec).c_str(), rb.count, D.out[0].len);
    return true;
}

void FreeCapture(Decoder &D) {
    if (D.capOn) {
        int t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        Xioctl(D.fd, VIDIOC_STREAMOFF, &t);
        D.capOn = false;
    }
    for (auto &c : D.cap)
        for (int p = 0; p < D.nCapPlanes; ++p) {
            if (c.map[p] && c.map[p] != MAP_FAILED) munmap(c.map[p], c.len[p]);
            if (c.fd[p] >= 0) close(c.fd[p]);
        }
    D.cap.clear();
    v4l2_requestbuffers rb{};
    rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, rb.memory = V4L2_MEMORY_MMAP, rb.count = 0;
    Xioctl(D.fd, VIDIOC_REQBUFS, &rb);
}

bool QueueCap(Decoder &D, int i) {
    v4l2_plane pl[VIDEO_MAX_PLANES]{};
    v4l2_buffer b{};
    b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, b.memory = V4L2_MEMORY_MMAP, b.index = uint32_t(i);
    b.length = uint32_t(D.nCapPlanes), b.m.planes = pl;
    if (Xioctl(D.fd, VIDIOC_QBUF, &b) < 0) return perror("QBUF capture"), false;
    return true;
}

bool SetupCapture(Decoder &D) {
    FreeCapture(D);
    v4l2_format f{};
    f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (Xioctl(D.fd, VIDIOC_G_FMT, &f) < 0) return perror("G_FMT capture"), false;
    printf("capture: decoder proposes %s %ux%u\n", Fourcc(f.fmt.pix_mp.pixelformat).c_str(), f.fmt.pix_mp.width,
           f.fmt.pix_mp.height);
    if (D.wantFmt && f.fmt.pix_mp.pixelformat != D.wantFmt) {
        f.fmt.pix_mp.pixelformat = D.wantFmt;
        if (Xioctl(D.fd, VIDIOC_S_FMT, &f) < 0) return perror("S_FMT capture"), false;
        if (f.fmt.pix_mp.pixelformat != D.wantFmt) {
            fprintf(stderr, "capture: decoder refused %s, gave %s\n", Fourcc(D.wantFmt).c_str(),
                    Fourcc(f.fmt.pix_mp.pixelformat).c_str());
            return false;
        }
    }
    D.capFmt = f;
    D.nCapPlanes = f.fmt.pix_mp.num_planes;
    v4l2_selection sel{};
    sel.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    sel.target = V4L2_SEL_TGT_COMPOSE;
    if (Xioctl(D.fd, VIDIOC_G_SELECTION, &sel) == 0) D.visible = sel.r;
    else D.visible = {0, 0, f.fmt.pix_mp.width, f.fmt.pix_mp.height};
    v4l2_control ctl{};
    ctl.id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE;
    int minBufs = Xioctl(D.fd, VIDIOC_G_CTRL, &ctl) == 0 ? ctl.value : 4;
    v4l2_requestbuffers rb{};
    rb.count = uint32_t(minBufs + 4);
    rb.type = f.type, rb.memory = V4L2_MEMORY_MMAP;
    if (Xioctl(D.fd, VIDIOC_REQBUFS, &rb) < 0) return perror("REQBUFS capture"), false;
    D.cap.resize(rb.count);
    printf("capture: %s coded %ux%u visible %ux%u@%d,%d planes=%d", Fourcc(f.fmt.pix_mp.pixelformat).c_str(),
           f.fmt.pix_mp.width, f.fmt.pix_mp.height, D.visible.width, D.visible.height, D.visible.left,
           D.visible.top, D.nCapPlanes);
    for (int p = 0; p < D.nCapPlanes; ++p)
        printf(" [stride=%u size=%u]", f.fmt.pix_mp.plane_fmt[p].bytesperline, f.fmt.pix_mp.plane_fmt[p].sizeimage);
    printf(" buffers=%u (min %d)\n", rb.count, minBufs);
    int exported = 0;
    for (unsigned i = 0; i < rb.count; ++i) {
        v4l2_plane pl[VIDEO_MAX_PLANES]{};
        v4l2_buffer b{};
        b.type = f.type, b.memory = V4L2_MEMORY_MMAP, b.index = i, b.length = uint32_t(D.nCapPlanes), b.m.planes = pl;
        if (Xioctl(D.fd, VIDIOC_QUERYBUF, &b) < 0) return perror("QUERYBUF capture"), false;
        for (int p = 0; p < D.nCapPlanes; ++p) {
            D.cap[i].len[p] = pl[p].length;
            D.cap[i].map[p] = mmap(nullptr, pl[p].length, PROT_READ, MAP_SHARED, D.fd, pl[p].m.mem_offset);
            v4l2_exportbuffer e{};
            e.type = f.type, e.index = i, e.plane = uint32_t(p), e.flags = O_CLOEXEC | O_RDWR;
            if (Xioctl(D.fd, VIDIOC_EXPBUF, &e) == 0) {
                D.cap[i].fd[p] = e.fd;
                ++exported;
                if (i == 0) {
                    off_t sz = lseek(e.fd, 0, SEEK_END);
                    lseek(e.fd, 0, SEEK_SET);
                    printf("dmabuf: VIDIOC_EXPBUF ok, buffer 0 plane %d -> fd %d, %lld bytes\n", p, e.fd,
                           (long long)sz);
                }
            } else if (i == 0) {
                printf("dmabuf: VIDIOC_EXPBUF FAILED: %s\n", strerror(errno));
            }
        }
    }
    printf("dmabuf: exported %d/%u capture planes\n", exported, rb.count * unsigned(D.nCapPlanes));
    for (unsigned i = 0; i < rb.count; ++i)
        if (!QueueCap(D, int(i))) return false;
    int t = f.type;
    if (Xioctl(D.fd, VIDIOC_STREAMON, &t) < 0) return perror("STREAMON capture"), false;
    D.capOn = true;
    return true;
}

// ---- SteamVR ---------------------------------------------------------------------------
#ifdef FTRD_VR
uint32_t DrmFormat(uint32_t v4l2) {
    switch (v4l2) {
    case V4L2_PIX_FMT_RGBA32: return DRM_FORMAT_ABGR8888;  // both: bytes R,G,B,A in memory
    case V4L2_PIX_FMT_NV12: return DRM_FORMAT_NV12;
    case V4L2_PIX_FMT_QC08C: return DRM_FORMAT_NV12;
    default: return 0;
    }
}
int g_mod = -1;  // --mod: -1 default, 0 linear, 1 ubwc
uint64_t DrmModifier(uint32_t v4l2) {
    // On this iris driver only NV12 comes out linear; Q08C and "AB24" are UBWC-compressed.
    const bool ubwc = g_mod >= 0 ? g_mod == 1 : v4l2 != V4L2_PIX_FMT_NV12;
    return ubwc ? DRM_FORMAT_MOD_QCOM_COMPRESSED : DRM_FORMAT_MOD_LINEAR;
}

// SteamVR compositor frame timing, sampled a few times a second.
struct CompStats {
    bool ok = false;
    uint32_t lastIndex = 0;
    uint64_t frames = 0, dropped = 0, mispresented = 0, reprojected = 0;
    std::vector<double> gpuMs, cpuMs;
    std::vector<std::pair<double, uint32_t>> drops;  // (seconds since first counted frame, frames dropped)
    double t0 = -1;
    float hz = 0;
};
void SampleComp(CompStats &s) {
    if (!vr::VRCompositor()) return;
    static vr::Compositor_FrameTiming t[128];
    t[0].m_nSize = sizeof(vr::Compositor_FrameTiming);
    const uint32_t n = vr::VRCompositor()->GetFrameTimings(t, 128);
    for (uint32_t i = 0; i < n; ++i) {  // oldest first
        const auto &f = t[i];
        if (s.ok && f.m_nFrameIndex <= s.lastIndex) continue;
        if (!s.ok) { s.ok = true, s.lastIndex = f.m_nFrameIndex; continue; }  // only count frames after start
        s.lastIndex = f.m_nFrameIndex;
        if (s.t0 < 0) s.t0 = f.m_flSystemTimeInSeconds;
        if (f.m_nNumDroppedFrames) s.drops.push_back({f.m_flSystemTimeInSeconds - s.t0, f.m_nNumDroppedFrames});
        ++s.frames;
        s.dropped += f.m_nNumDroppedFrames;
        s.mispresented += f.m_nNumMisPresented;
        if (f.m_nReprojectionFlags) ++s.reprojected;
        s.gpuMs.push_back(f.m_flCompositorRenderGpuMs);
        s.cpuMs.push_back(f.m_flCompositorRenderCpuMs);
    }
}
void PrintComp(const CompStats &s, double wall) {
    if (!s.ok) { printf("  compositor: frame timing unavailable\n"); return; }
    printf("  compositor: %llu frames in %.1f s (%.1f Hz, display %.0f Hz); dropped %llu, mispresented %llu, "
           "reprojected %llu\n", (unsigned long long)s.frames, wall, s.frames / wall, s.hz,
           (unsigned long long)s.dropped, (unsigned long long)s.mispresented, (unsigned long long)s.reprojected);
    printf("  compositor GPU ms: median %.2f p99 %.2f; CPU ms: median %.2f p99 %.2f\n", Pct(s.gpuMs, 50),
           Pct(s.gpuMs, 99), Pct(s.cpuMs, 50), Pct(s.cpuMs, 99));
    if (!s.drops.empty()) {
        printf("  compositor drops at (s since start: frames):");
        for (size_t i = 0; i < s.drops.size() && i < 40; ++i) printf(" %.1f:%u", s.drops[i].first, s.drops[i].second);
        printf(s.drops.size() > 40 ? " ...\n" : "\n");
    }
}
CompStats g_comp;

void ListMods(uint32_t fmt, const char *name) {
    uint64_t mods[64];
    uint32_t n = 64;
    if (!vr::VRIPCResourceManager()->GetDmabufModifiers(vr::VRApplication_Overlay, fmt, &n, mods)) {
        printf("vr: GetDmabufModifiers(%s) failed\n", name);
        return;
    }
    printf("vr: SteamVR takes %u modifiers for %s:", n, name);
    for (uint32_t i = 0; i < n && i < 64; ++i) printf(" 0x%llx", (unsigned long long)mods[i]);
    printf("\n");
}

uint64_t ImportCap(Decoder &D, CapBuf &c) {
    const auto &pm = D.capFmt.fmt.pix_mp;
    vr::DmabufAttributes_t a{};
    a.unWidth = D.visible.width;
    a.unHeight = D.visible.height;
    a.unDepth = a.unMipLevels = a.unArrayLayers = a.unSampleCount = 1;
    a.unFormat = DrmFormat(pm.pixelformat);
    a.ulModifier = DrmModifier(pm.pixelformat);
    if (pm.pixelformat == V4L2_PIX_FMT_NV12 && D.nCapPlanes == 1) {  // Y and UV in one buffer
        a.unPlaneCount = 2;
        a.plane[0].unOffset = 0, a.plane[0].unStride = pm.plane_fmt[0].bytesperline, a.plane[0].nFd = c.fd[0];
        a.plane[1].unOffset = pm.plane_fmt[0].bytesperline * pm.height;
        a.plane[1].unStride = pm.plane_fmt[0].bytesperline, a.plane[1].nFd = c.fd[0];
    } else {
        a.unPlaneCount = uint32_t(D.nCapPlanes);
        for (int p = 0; p < D.nCapPlanes; ++p)
            a.plane[p].unOffset = 0, a.plane[p].unStride = pm.plane_fmt[p].bytesperline, a.plane[p].nFd = c.fd[p];
    }
    vr::SharedTextureHandle_t h = 0;
    if (!vr::VRIPCResourceManager()->ImportDmabuf(vr::VRApplication_Overlay, &a, &h)) return 0;
    return h;
}
#endif

#ifdef FTRD_GL
// NV12 dmabuf (from the decoder) -> linear ABGR8888 dmabuf (for SteamVR), one GLES draw.
struct Rgb {
    int drm = -1;
    gbm_device *gbm = nullptr;
    EGLDisplay dpy = EGL_NO_DISPLAY;
    EGLContext ctx = EGL_NO_CONTEXT;
    PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC targetTex = nullptr;
    PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC targetRb = nullptr;
    GLuint prog = 0, vbo = 0;
    struct Out {
        gbm_bo *bo = nullptr;
        int fd = -1;
        uint32_t stride = 0;
        GLuint rb = 0, fbo = 0;
        uint64_t vr = 0;
    } out[3];
    int next = 0, w = 0, h = 0;
    bool bt709 = false;
    std::vector<GLuint> srcTex;  // per capture buffer index, 0 = not imported yet
};

GLuint Compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024] = "";
        glGetShaderInfoLog(s, sizeof log, nullptr, log);
        fprintf(stderr, "rgb: shader: %s\n", log);
    }
    return s;
}

bool RgbInit(Rgb &g, int w, int h) {
    g.w = w, g.h = h;
    g.drm = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (g.drm < 0) return perror("rgb: renderD128"), false;
    g.gbm = gbm_create_device(g.drm);
    auto getDpy = reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    g.createImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
    g.targetTex = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
    g.targetRb = reinterpret_cast<PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC>(
        eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES"));
    if (!g.gbm || !getDpy || !g.createImage || !g.targetTex || !g.targetRb)
        return fprintf(stderr, "rgb: GBM/EGL extensions missing\n"), false;
    g.dpy = getDpy(EGL_PLATFORM_GBM_KHR, g.gbm, nullptr);
    if (g.dpy == EGL_NO_DISPLAY || !eglInitialize(g.dpy, nullptr, nullptr))
        return fprintf(stderr, "rgb: no EGL display\n"), false;
    eglBindAPI(EGL_OPENGL_ES_API);
    const EGLint attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    g.ctx = eglCreateContext(g.dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, attrs);
    if (g.ctx == EGL_NO_CONTEXT || !eglMakeCurrent(g.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g.ctx))
        return fprintf(stderr, "rgb: no surfaceless GLES context\n"), false;
    printf("rgb: GL_RENDERER %s\n", (const char *)glGetString(GL_RENDERER));
    const char *vs = "attribute vec2 pos; varying vec2 uv;\n"
                     "void main() { uv = pos; gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0); }";
    const char *fs = "#extension GL_OES_EGL_image_external : require\n"
                     "precision highp float; uniform samplerExternalOES tex; varying vec2 uv;\n"
                     "void main() { gl_FragColor = vec4(texture2D(tex, uv).rgb, 1.0); }";
    g.prog = glCreateProgram();
    glAttachShader(g.prog, Compile(GL_VERTEX_SHADER, vs));
    glAttachShader(g.prog, Compile(GL_FRAGMENT_SHADER, fs));
    glBindAttribLocation(g.prog, 0, "pos");
    glLinkProgram(g.prog);
    GLint ok = 0;
    glGetProgramiv(g.prog, GL_LINK_STATUS, &ok);
    if (!ok) return fprintf(stderr, "rgb: link failed\n"), false;
    const float quad[] = {0, 0, 1, 0, 0, 1, 1, 1};
    glGenBuffers(1, &g.vbo);
    glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
    for (auto &o : g.out) {
        o.bo = gbm_bo_create(g.gbm, uint32_t(w), uint32_t(h), GBM_FORMAT_ABGR8888,
                             GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
        if (!o.bo) return fprintf(stderr, "rgb: gbm_bo_create failed\n"), false;
        o.fd = gbm_bo_get_fd(o.bo);
        o.stride = gbm_bo_get_stride(o.bo);
        const EGLint a[] = {EGL_WIDTH, w, EGL_HEIGHT, h, EGL_LINUX_DRM_FOURCC_EXT, EGLint(DRM_FORMAT_ABGR8888),
                            EGL_DMA_BUF_PLANE0_FD_EXT, o.fd, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
                            EGL_DMA_BUF_PLANE0_PITCH_EXT, EGLint(o.stride), EGL_NONE};
        EGLImageKHR img = g.createImage(g.dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, a);
        if (img == EGL_NO_IMAGE_KHR) return fprintf(stderr, "rgb: can't render to the output\n"), false;
        glGenRenderbuffers(1, &o.rb);
        glBindRenderbuffer(GL_RENDERBUFFER, o.rb);
        g.targetRb(GL_RENDERBUFFER, img);
        glGenFramebuffers(1, &o.fbo);
        glBindFramebuffer(GL_FRAMEBUFFER, o.fbo);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, o.rb);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            return fprintf(stderr, "rgb: framebuffer incomplete\n"), false;
    }
    printf("rgb: 3 x %dx%d ABGR8888 linear outputs, stride %u, %s limited range\n", w, h, g.out[0].stride,
           g.bt709 ? "BT.709" : "BT.601");
    return true;
}

// Import capture buffer i (NV12, Y and UV in one dmabuf) as an external texture, once.
GLuint RgbSource(Rgb &g, const Decoder &D, int i) {
    if (int(g.srcTex.size()) <= i) g.srcTex.resize(size_t(i) + 1, 0);
    if (g.srcTex[size_t(i)]) return g.srcTex[size_t(i)];
    const auto &pm = D.capFmt.fmt.pix_mp;
    const EGLint stride = EGLint(pm.plane_fmt[0].bytesperline), fd = D.cap[size_t(i)].fd[0];
    const EGLint a[] = {EGL_WIDTH, EGLint(D.visible.width), EGL_HEIGHT, EGLint(D.visible.height),
                        EGL_LINUX_DRM_FOURCC_EXT, EGLint(DRM_FORMAT_NV12),
                        EGL_DMA_BUF_PLANE0_FD_EXT, fd, EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
                        EGL_DMA_BUF_PLANE0_PITCH_EXT, stride,
                        EGL_DMA_BUF_PLANE1_FD_EXT, fd, EGL_DMA_BUF_PLANE1_OFFSET_EXT, EGLint(stride * EGLint(pm.height)),
                        EGL_DMA_BUF_PLANE1_PITCH_EXT, stride,
                        EGL_YUV_COLOR_SPACE_HINT_EXT, g.bt709 ? EGL_ITU_REC709_EXT : EGL_ITU_REC601_EXT,
                        EGL_SAMPLE_RANGE_HINT_EXT, EGL_YUV_NARROW_RANGE_EXT, EGL_NONE};
    EGLImageKHR img = g.createImage(g.dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, nullptr, a);
    if (img == EGL_NO_IMAGE_KHR) {
        fprintf(stderr, "rgb: EGL can't import decoder buffer %d (0x%x)\n", i, eglGetError());
        return 0;
    }
    GLuint t;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, t);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    g.targetTex(GL_TEXTURE_EXTERNAL_OES, img);
    g.srcTex[size_t(i)] = t;
    return t;
}

// Draw capture buffer i into the next output; returns it, or nullptr. Finished (glFinish) on return,
// so the decoder buffer can go straight back to the decoder.
Rgb::Out *RgbConvert(Rgb &g, const Decoder &D, int i) {
    GLuint t = RgbSource(g, D, i);
    if (!t) return nullptr;
    Rgb::Out &o = g.out[g.next];
    g.next = (g.next + 1) % 3;
    glBindFramebuffer(GL_FRAMEBUFFER, o.fbo);
    glViewport(0, 0, g.w, g.h);
    glUseProgram(g.prog);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, t);
    glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glFinish();
    return &o;
}
#endif

}  // namespace
