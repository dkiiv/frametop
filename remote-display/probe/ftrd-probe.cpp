// ftrd-probe: M0 decoder probe for the remote-display POC (docs/handoff/04-milestones.md).
//
// Feeds an Annex-B H.264/HEVC elementary stream (what a Moonlight client receives) to the
// Frame's V4L2 stateful decoder (qcom-iris, /dev/video22) one access unit at a time, paced
// like a live stream, and measures what M0 asks:
//   - does it hold the frame rate, and at what per-frame latency (AU queued -> frame out)
//   - CPU cost (this process, and the whole SoC from /proc/stat)
//   - do decoded frames leave the decoder as DMA-BUFs (VIDIOC_EXPBUF)
//   - (--vr) does SteamVR's ImportDmabuf accept them; (--show) put them on an overlay
//
// Usage: ftrd-probe FILE [--codec h264|hevc] [--fmt nv12|ab24|q08c] [--fps 60 | --fps 0]
//                        [--loops N] [--vr] [--show] [--dump OUT.raw --dump-frame N]
//   --fps 0   feed as fast as the decoder takes it (throughput)
//   --vr      VR_Init as an overlay app and try ImportDmabuf on the decoded buffers
//   --show    also show the decoded video on an overlay 1.2 m ahead (implies --vr)
//   --mod linear|ubwc   DRM modifier to hand SteamVR (default: linear for nv12, ubwc otherwise)
//   --rgb     convert each decoded NV12 frame on the GPU (EGL dmabuf import) into a linear
//             ABGR8888 buffer, the format every Frametop panel uses, and hand THAT to SteamVR;
//             --dump then writes the converted RGBA. --csc 601|709 picks the YUV matrix.
//   --idle S  no decoding: just sample SteamVR compositor timing + CPU for S seconds (baseline)
// With --vr, the compositor's own frame timing (dropped / mispresented frames, compositor GPU
// ms) is sampled during the run, so "did decoding hurt the headset" is a number.
//
// Build: remote-display/probe/build.sh (runs in the dev container on the Frame).
#include "../common/rdcore.h"

namespace {

struct Opts {
    const char *file = nullptr, *dump = nullptr;
    bool hevc = false, codecSet = false, vr = false, show = false, rgb = false, bt709 = false;
    uint32_t fmt = V4L2_PIX_FMT_NV12;
    double fps = 60, idle = 0;
    int loops = 1, dumpFrame = 120;
};

}  // namespace

int main(int argc, char **argv) {
    Opts o;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> const char * { return i + 1 < argc ? argv[++i] : ""; };
        if (a == "--codec") o.hevc = std::string(next()) == "hevc", o.codecSet = true;
        else if (a == "--fmt") {
            std::string f = next();
            o.fmt = f == "ab24" ? V4L2_PIX_FMT_RGBA32 : f == "q08c" ? V4L2_PIX_FMT_QC08C : V4L2_PIX_FMT_NV12;
        } else if (a == "--fps") o.fps = atof(next());
        else if (a == "--loops") o.loops = std::max(1, atoi(next()));
        else if (a == "--vr") o.vr = true;
        else if (a == "--show") o.vr = o.show = true;
        else if (a == "--rgb") o.rgb = true;
        else if (a == "--csc") o.bt709 = std::string(next()) == "709";
        else if (a == "--idle") o.idle = atof(next()), o.vr = true;
        else if (a == "--mod") {
#ifdef FTRD_VR
            g_mod = std::string(next()) == "ubwc";
#else
            next();
#endif
        }
        else if (a == "--dump") o.dump = next();
        else if (a == "--dump-frame") o.dumpFrame = atoi(next());
        else if (a[0] != '-') o.file = argv[i];
        else return fprintf(stderr, "unknown option %s\n", a.c_str()), 2;
    }
    if (!o.file && o.idle <= 0) return fprintf(stderr, "usage: ftrd-probe FILE [--codec h264|hevc] [--fmt nv12|ab24|q08c] "
                                        "[--fps N] [--loops N] [--vr] [--show] [--dump F --dump-frame N]\n"), 2;
    if (o.file && !o.codecSet && (strstr(o.file, ".hevc") || strstr(o.file, ".265"))) o.hevc = true;
#ifndef FTRD_VR
    if (o.vr) return fprintf(stderr, "built without OpenVR\n"), 2;
#endif
#ifndef FTRD_GL
    if (o.rgb) return fprintf(stderr, "built without EGL/GLES\n"), 2;
#endif
    if (o.rgb && o.fmt != V4L2_PIX_FMT_NV12) return fprintf(stderr, "--rgb needs --fmt nv12\n"), 2;
    signal(SIGINT, Stop);
    signal(SIGTERM, Stop);

    std::vector<uint8_t> data;
    if (o.file) {
        FILE *f = fopen(o.file, "rb");
        if (!f) return perror(o.file), 1;
        struct stat st;
        fstat(fileno(f), &st);
        data.resize(size_t(st.st_size));
        if (fread(data.data(), 1, data.size(), f) != data.size()) return perror("read"), 1;
        fclose(f);
    }
    const std::vector<Au> aus = SplitAus(data, o.hevc);
    size_t maxAu = 0;
    for (auto &a : aus) maxAu = std::max(maxAu, a.len);
    if (o.file) {
        printf("stream: %s, %s, %zu access units, largest %zu bytes\n", o.file, o.hevc ? "HEVC" : "H.264",
               aus.size(), maxAu);
        if (aus.empty()) return 1;
    }

#ifdef FTRD_VR
    vr::VROverlayHandle_t ov = vr::k_ulOverlayHandleInvalid;
    if (o.vr) {
        vr::EVRInitError err = vr::VRInitError_None;
        vr::VR_Init(&err, vr::VRApplication_Overlay);
        if (err != vr::VRInitError_None)
            return fprintf(stderr, "openvr: %s\n", vr::VR_GetVRInitErrorAsEnglishDescription(err)), 1;
        ListMods(DRM_FORMAT_ABGR8888, "ABGR8888");
        ListMods(DRM_FORMAT_NV12, "NV12");
        vr::ETrackedPropertyError pe;
        g_comp.hz = vr::VRSystem()->GetFloatTrackedDeviceProperty(vr::k_unTrackedDeviceIndex_Hmd,
                                                                  vr::Prop_DisplayFrequency_Float, &pe);
        SampleComp(g_comp);
        if (o.show) {
            if (vr::VROverlay()->CreateOverlay("frametop.ftrdprobe", "Remote display probe", &ov) !=
                vr::VROverlayError_None)
                return fprintf(stderr, "can't create the overlay (already running?)\n"), 1;
            vr::VROverlay()->SetOverlayWidthInMeters(ov, 1.2f);
            vr::TrackedDevicePose_t poses[vr::k_unMaxTrackedDeviceCount];
            vr::VRSystem()->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0, poses,
                                                            vr::k_unMaxTrackedDeviceCount);
            const auto &hm = poses[vr::k_unTrackedDeviceIndex_Hmd].mDeviceToAbsoluteTracking;
            const double yaw = std::atan2(hm.m[0][2], hm.m[2][2]), dist = 1.2;
            vr::HmdMatrix34_t P{};
            P.m[0][0] = float(std::cos(yaw)), P.m[0][2] = float(std::sin(yaw));
            P.m[1][1] = 1;
            P.m[2][0] = float(-std::sin(yaw)), P.m[2][2] = float(std::cos(yaw));
            P.m[0][3] = float(hm.m[0][3] - std::sin(yaw) * dist);
            P.m[1][3] = float(hm.m[1][3]);
            P.m[2][3] = float(hm.m[2][3] - std::cos(yaw) * dist);
            vr::VROverlay()->SetOverlayTransformAbsolute(ov, vr::TrackingUniverseStanding, &P);
            vr::VROverlay()->SetOverlayFlag(ov, vr::VROverlayFlags_IgnoreTextureAlpha, true);
        }
    }
    int shownIdx = -1, importsOk = 0, importsFailed = 0;
    if (o.idle > 0) {  // baseline: no decoder at all
        rusage r0, r1;
        getrusage(RUSAGE_SELF, &r0);
        const CpuStat c0 = ReadCpu();
        const double tv = ThermalC("video-thermal"), tc = ThermalC("cpuss0-thermal");
        const int64_t s0 = MonoNs();
        while (!g_stop && (MonoNs() - s0) / 1e9 < o.idle) {
            usleep(250000);
            SampleComp(g_comp);
        }
        const double w = (MonoNs() - s0) / 1e9;
        getrusage(RUSAGE_SELF, &r1);
        const CpuStat c1 = ReadCpu();
        printf("\nRESULT idle baseline (no decoding)\n");
        printf("  cpu: whole SoC busy %.1f%% of 8 cores\n",
               c1.total > c0.total ? 100.0 * double(c1.busy - c0.busy) / double(c1.total - c0.total) : NAN);
        printf("  thermal: video %.1f -> %.1f C, cpuss0 %.1f -> %.1f C\n", tv, ThermalC("video-thermal"), tc,
               ThermalC("cpuss0-thermal"));
        PrintComp(g_comp, w);
        vr::VR_Shutdown();
        return 0;
    }
#endif

    Decoder D;
    D.codec = o.hevc ? V4L2_PIX_FMT_HEVC : V4L2_PIX_FMT_H264;
    D.wantFmt = o.fmt;
    D.fd = open("/dev/video-dec0", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (D.fd < 0) D.fd = open("/dev/video22", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (D.fd < 0) return perror("open decoder"), 1;
    if (!SetupOutput(D, maxAu)) return 1;

    const size_t total = aus.size() * size_t(o.loops);
    std::vector<int64_t> tIn(total, 0);
    std::vector<double> lat, gaps;
    lat.reserve(total);
    const int64_t period = o.fps > 0 ? int64_t(1e9 / o.fps) : 0;
    size_t fed = 0, decoded = 0, lateFeeds = 0, stalls = 0, unmatched = 0;
    bool stopSent = false, done = false;
    int64_t lastOut = 0;

#ifdef FTRD_GL
    Rgb rgb;
    rgb.bt709 = o.bt709;
    bool rgbReady = false;
#endif
    std::vector<double> convMs;
    rusage ru0;
    getrusage(RUSAGE_SELF, &ru0);
    const CpuStat cpu0 = ReadCpu();
    const double tv0 = ThermalC("video-thermal"), tc0 = ThermalC("cpuss0-thermal");
    const int64_t t0 = MonoNs();
    int64_t nextFeed = t0, stallMark = -1, lastSample = t0;
    uint64_t bufsSeen = 0;  // bitmask of capture buffer indices that carried frames

    while (!done && !g_stop) {
        int64_t now = MonoNs();
#ifdef FTRD_VR
        if (o.vr && now - lastSample > 250000000) SampleComp(g_comp), lastSample = now;
#endif
        // Feed.
        while (fed < total && !D.freeOut.empty() && (period == 0 || now >= nextFeed)) {
            const Au &a = aus[fed % aus.size()];
            const int i = D.freeOut.back();
            D.freeOut.pop_back();
            memcpy(D.out[i].map, data.data() + a.off, a.len);
            v4l2_plane pl[VIDEO_MAX_PLANES]{};
            v4l2_buffer b{};
            b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, b.memory = V4L2_MEMORY_MMAP, b.index = uint32_t(i);
            b.length = 1, b.m.planes = pl;
            pl[0].bytesused = uint32_t(a.len);
            b.timestamp.tv_sec = time_t(fed / 1000000), b.timestamp.tv_usec = suseconds_t(fed % 1000000);
            if (Xioctl(D.fd, VIDIOC_QBUF, &b) < 0) { perror("QBUF output"); g_stop = 1; break; }
            tIn[fed] = now;
            if (period && now - nextFeed > period) ++lateFeeds;
            ++fed;
            if (period) nextFeed += period;
            now = MonoNs();
        }
        if (fed < total && D.freeOut.empty() && period && now >= nextFeed && stallMark != int64_t(fed)) {
            ++stalls;
            stallMark = int64_t(fed);
        }
        if (fed == total && !stopSent) {
            v4l2_decoder_cmd cmd{};
            cmd.cmd = V4L2_DEC_CMD_STOP;
            if (Xioctl(D.fd, VIDIOC_DECODER_CMD, &cmd) < 0) perror("DECODER_CMD stop");
            stopSent = true;
        }
        int timeoutMs = 100;
        if (period && fed < total) timeoutMs = int(std::max<int64_t>(0, (nextFeed - MonoNs()) / 1000000));
        pollfd p{D.fd, short(POLLIN | POLLOUT | POLLPRI), 0};
        int r = poll(&p, 1, timeoutMs);
        if (r < 0 && errno != EINTR) { perror("poll"); break; }
        if (r <= 0) {
            if (stopSent && MonoNs() - lastOut > 3000000000LL && lastOut) break;  // drain timeout
            continue;
        }
        if (p.revents & POLLPRI) {
            v4l2_event ev{};
            while (Xioctl(D.fd, VIDIOC_DQEVENT, &ev) == 0) {
                if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
                    ++D.sourceChanges;
                    if (!SetupCapture(D)) { g_stop = 1; break; }
                } else if (ev.type == V4L2_EVENT_EOS) {
                    // the LAST capture buffer ends the run
                }
            }
        }
        if (p.revents & POLLERR && !D.capOn) usleep(500);  // capture queue not set up yet
        // Reclaim bitstream buffers.
        for (;;) {
            v4l2_plane pl[VIDEO_MAX_PLANES]{};
            v4l2_buffer b{};
            b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, b.memory = V4L2_MEMORY_MMAP, b.length = 1, b.m.planes = pl;
            if (Xioctl(D.fd, VIDIOC_DQBUF, &b) < 0) break;
            D.freeOut.push_back(int(b.index));
        }
        // Decoded frames.
        while (D.capOn) {
            v4l2_plane pl[VIDEO_MAX_PLANES]{};
            v4l2_buffer b{};
            b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, b.memory = V4L2_MEMORY_MMAP;
            b.length = uint32_t(D.nCapPlanes), b.m.planes = pl;
            if (Xioctl(D.fd, VIDIOC_DQBUF, &b) < 0) break;
            const int64_t t = MonoNs();
            const bool last = b.flags & V4L2_BUF_FLAG_LAST;
            bool keep = false;
            if (pl[0].bytesused > 0 && !(b.flags & V4L2_BUF_FLAG_ERROR)) {
                const size_t idx = size_t(b.timestamp.tv_sec) * 1000000 + size_t(b.timestamp.tv_usec);
                if (idx < total && tIn[idx]) lat.push_back((t - tIn[idx]) / 1e6);
                else ++unmatched;
                if (lastOut) gaps.push_back((t - lastOut) / 1e6);
                if (b.index < 64) bufsSeen |= 1ull << b.index;
                lastOut = t;
                bool dumped = false;
#ifdef FTRD_GL
                Rgb::Out *ro = nullptr;
                if (o.rgb) {
                    if (!rgbReady) {
                        if (!RgbInit(rgb, int(D.visible.width), int(D.visible.height))) { g_stop = 1; break; }
                        rgbReady = true;
                    }
                    const int64_t c0 = MonoNs();
                    ro = RgbConvert(rgb, D, int(b.index));
                    convMs.push_back((MonoNs() - c0) / 1e6);
                    if (ro && o.dump && int(decoded) == o.dumpFrame) {
                        std::vector<uint8_t> px(size_t(rgb.w) * size_t(rgb.h) * 4);
                        glReadPixels(0, 0, rgb.w, rgb.h, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
                        FILE *f = fopen(o.dump, "wb");
                        if (f) fwrite(px.data(), 1, px.size(), f), fclose(f);
                        printf("dump: frame %zu -> %s (converted RGBA %dx%d)\n", decoded, o.dump, rgb.w, rgb.h);
                        dumped = true;
                    }
                }
#endif
                if (o.dump && !dumped && int(decoded) == o.dumpFrame) {
                    FILE *f = fopen(o.dump, "wb");
                    if (f) {
                        for (int q = 0; q < D.nCapPlanes; ++q) fwrite(D.cap[b.index].map[q], 1, pl[q].bytesused, f);
                        fclose(f);
                        const auto &pm = D.capFmt.fmt.pix_mp;
                        printf("dump: frame %zu -> %s (%s, stride %u, coded %ux%u, visible %ux%u)\n", decoded, o.dump,
                               Fourcc(pm.pixelformat).c_str(), pm.plane_fmt[0].bytesperline, pm.width, pm.height,
                               D.visible.width, D.visible.height);
                    }
                }
                ++decoded;
#ifdef FTRD_VR
#ifdef FTRD_GL
                if (o.vr && o.rgb && ro) {
                    if (!ro->vr) {
                        vr::DmabufAttributes_t a{};
                        a.unWidth = uint32_t(rgb.w), a.unHeight = uint32_t(rgb.h);
                        a.unDepth = a.unMipLevels = a.unArrayLayers = a.unSampleCount = 1;
                        a.unFormat = DRM_FORMAT_ABGR8888, a.ulModifier = DRM_FORMAT_MOD_LINEAR, a.unPlaneCount = 1;
                        a.plane[0].unOffset = 0, a.plane[0].unStride = ro->stride, a.plane[0].nFd = ro->fd;
                        vr::SharedTextureHandle_t h = 0;
                        if (vr::VRIPCResourceManager()->ImportDmabuf(vr::VRApplication_Overlay, &a, &h) && h) {
                            ro->vr = h;
                            if (!importsOk++) printf("vr: ImportDmabuf OK (converted ABGR8888 linear)\n");
                        } else {
                            ++importsFailed;
                            printf("vr: ImportDmabuf FAILED for converted ABGR8888; stopping\n");
                            g_stop = 1;
                        }
                    }
                    if (o.show && ro->vr) {
                        vr::SharedTextureHandle_t h = ro->vr;
                        vr::Texture_t tex = {&h, vr::TextureType_SharedTextureHandle, vr::ColorSpace_Gamma};
                        vr::VROverlay()->SetOverlayTexture(ov, &tex);
                        if (shownIdx < 0) vr::VROverlay()->ShowOverlay(ov), shownIdx = 0;
                    }
                } else
#endif
                if (o.vr) {
                    CapBuf &c = D.cap[b.index];
                    if (!c.vrHandle) {
                        c.vrHandle = ImportCap(D, c);
                        if (!c.vrHandle) c.vrHandle = ~0ull;  // failed: never retry (each retry blocks)
                        if (c.vrHandle != ~0ull) {
                            if (!importsOk++) printf("vr: ImportDmabuf OK (%s straight from the decoder)\n",
                                                     Fourcc(D.capFmt.fmt.pix_mp.pixelformat).c_str());
                        } else if (!importsFailed++) {
                            printf("vr: ImportDmabuf FAILED for %s\n", Fourcc(D.capFmt.fmt.pix_mp.pixelformat).c_str());
                        }
                    }
                    if (o.show && c.vrHandle && c.vrHandle != ~0ull) {
                        vr::SharedTextureHandle_t h = c.vrHandle;
                        vr::Texture_t tex = {&h, vr::TextureType_SharedTextureHandle, vr::ColorSpace_Gamma};
                        vr::VROverlay()->SetOverlayTexture(ov, &tex);
                        if (shownIdx < 0) vr::VROverlay()->ShowOverlay(ov);
                        // Keep the shown buffer out of the decoder; give back the previous one.
                        if (shownIdx >= 0) QueueCap(D, shownIdx);
                        shownIdx = int(b.index);
                        keep = true;
                    }
                }
#endif
            }
            if (last) { done = true; break; }
            if (!keep) QueueCap(D, int(b.index));
        }
    }
    const int64_t t1 = MonoNs();
    rusage ru1;
    getrusage(RUSAGE_SELF, &ru1);
    const CpuStat cpu1 = ReadCpu();
    const double wall = (t1 - t0) / 1e9;
    const double cpuSelf = ((ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec) + (ru1.ru_stime.tv_sec - ru0.ru_stime.tv_sec) +
                            (ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec) / 1e6 +
                            (ru1.ru_stime.tv_usec - ru0.ru_stime.tv_usec) / 1e6) / wall * 100;
    const double socBusy = cpu1.total > cpu0.total ? 100.0 * double(cpu1.busy - cpu0.busy) /
                                                         double(cpu1.total - cpu0.total) : NAN;
    int lateOut = 0;
    for (double g : gaps) if (period && g > 1.5 * period / 1e6) ++lateOut;

    printf("\nRESULT file=%s codec=%s fmt=%s mode=%s\n", o.file, o.hevc ? "hevc" : "h264",
           Fourcc(D.capFmt.fmt.pix_mp.pixelformat).c_str(), period ? "paced" : "flat-out");
    printf("  frames: fed %zu, decoded %zu, missing %zd, unmatched %zu, source-changes %d\n", fed, decoded,
           ssize_t(fed) - ssize_t(decoded), unmatched, D.sourceChanges);
    printf("  rate: %.2f fps over %.2f s (target %s)\n", decoded / wall, wall,
           period ? (std::to_string(int(o.fps)) + " fps").c_str() : "none");
    printf("  latency AU-in -> frame-out (ms): median %.2f  p95 %.2f  p99 %.2f  max %.2f\n", Pct(lat, 50),
           Pct(lat, 95), Pct(lat, 99), lat.empty() ? NAN : *std::max_element(lat.begin(), lat.end()));
    printf("  output gaps (ms): median %.2f  p99 %.2f  max %.2f; gaps > 1.5 frame: %d\n", Pct(gaps, 50),
           Pct(gaps, 99), gaps.empty() ? NAN : *std::max_element(gaps.begin(), gaps.end()), lateOut);
    printf("  feeding: late feeds %zu, input stalls (no free bitstream buffer) %zu; capture buffers used %d/%zu\n",
           lateFeeds, stalls, __builtin_popcountll(bufsSeen), D.cap.size());
    if (!convMs.empty())
        printf("  rgb convert (draw + glFinish, ms): median %.2f  p99 %.2f  max %.2f\n", Pct(convMs, 50),
               Pct(convMs, 99), *std::max_element(convMs.begin(), convMs.end()));
    printf("  cpu: this process %.1f%% of one core; whole SoC busy %.1f%% of 8 cores\n", cpuSelf, socBusy);
    printf("  thermal: video %.1f -> %.1f C, cpuss0 %.1f -> %.1f C\n", tv0, ThermalC("video-thermal"), tc0,
           ThermalC("cpuss0-thermal"));
#ifdef FTRD_VR
    if (o.vr) {
        printf("  vr: imports ok %d, failed %d (modifier 0x%llx)\n", importsOk, importsFailed,
               (unsigned long long)DrmModifier(D.capFmt.fmt.pix_mp.pixelformat));
        SampleComp(g_comp);
        PrintComp(g_comp, wall);
        if (ov != vr::k_ulOverlayHandleInvalid) vr::VROverlay()->DestroyOverlay(ov);
        for (auto &c : D.cap)
            if (c.vrHandle && c.vrHandle != ~0ull) vr::VRIPCResourceManager()->UnrefResource(c.vrHandle);
#ifdef FTRD_GL
        for (auto &ro : rgb.out)
            if (ro.vr) vr::VRIPCResourceManager()->UnrefResource(ro.vr);
#endif
        vr::VR_Shutdown();
    }
#endif
    FreeCapture(D);
    close(D.fd);
    return decoded > 0 ? 0 : 1;
}
