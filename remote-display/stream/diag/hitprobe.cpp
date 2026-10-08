// hitprobe: which overlay does SteamVR's intersection test pick near a Frametop floating
// panel's bottom edge? Casts rays (as a laser from below/in front would) at points on the
// vertical centre line of the panel and of its bar, and reports every overlay hit.
// Usage: hitprobe N   (N = frametop.float.N)
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "openvr.h"

int main(int argc, char **argv) {
    const int n = argc > 1 ? atoi(argv[1]) : 1;
    vr::EVRInitError err;
    vr::VR_Init(&err, vr::VRApplication_Background);
    if (err) return printf("VR_Init: %d\n", err), 1;
    auto *ov = vr::VROverlay();
    const char *parts[] = {"", ".bar", ".curve", ".roll", ".resize", ".dock", ".close"};
    struct O { std::string key; vr::VROverlayHandle_t h; };
    std::vector<O> os;
    for (const char *p : parts) {
        std::string k = "frametop.float." + std::to_string(n) + p;
        vr::VROverlayHandle_t h = 0;
        if (ov->FindOverlay(k.c_str(), &h) == vr::VROverlayError_None && h) os.push_back({k, h});
        else printf("not found: %s\n", k.c_str());
    }
    if (os.empty()) return 1;
    vr::HmdMatrix34_t m;
    vr::ETrackingUniverseOrigin origin;
    ov->GetOverlayTransformAbsolute(os[0].h, &origin, &m);
    float w = 0; ov->GetOverlayWidthInMeters(os[0].h, &w);
    float curv = 0; ov->GetOverlayCurvature(os[0].h, &curv);
    uint32_t tw = 0, th = 0; ov->GetOverlayTextureSize(os[0].h, &tw, &th);
    vr::VRTextureBounds_t b{}; ov->GetOverlayTextureBounds(os[0].h, &b);
    const double aspect = (double(th) * (b.vMax - b.vMin)) / (double(tw) * (b.uMax - b.uMin));
    double h = w * aspect;
    if (!(h > 0) && os.size() > 1) {  // dmabuf texture: size unknown; from the bar (vr.cpp BarY)
        vr::HmdMatrix34_t mb; ov->GetOverlayTransformAbsolute(os[1].h, &origin, &mb);
        float bw = 0; ov->GetOverlayWidthInMeters(os[1].h, &bw);
        double d[3] = {mb.m[0][3] - m.m[0][3], mb.m[1][3] - m.m[1][3], mb.m[2][3] - m.m[2][3]}, ly = 0;
        for (int k = 0; k < 3; ++k) ly += d[k] * m.m[k][1];
        h = 2 * (-ly - bw * (0.06 + 12.0 / 256));
    }
    printf("panel %s: width %.3f m, tex %ux%u, bounds u %.3f-%.3f v %.3f-%.3f -> height %.3f m, curvature %.3f\n",
           os[0].key.c_str(), w, tw, th, b.uMin, b.uMax, b.vMin, b.vMax, h, curv);
    for (size_t i = 1; i < os.size(); ++i) {
        vr::HmdMatrix34_t mi; ov->GetOverlayTransformAbsolute(os[i].h, &origin, &mi);
        float wi = 0; ov->GetOverlayWidthInMeters(os[i].h, &wi);
        uint32_t a = 0, c = 0; ov->GetOverlayTextureSize(os[i].h, &a, &c);
        // offset in the panel's frame
        double d[3] = {mi.m[0][3] - m.m[0][3], mi.m[1][3] - m.m[1][3], mi.m[2][3] - m.m[2][3]};
        double lx = 0, ly = 0, lz = 0;
        for (int k = 0; k < 3; ++k) lx += d[k] * m.m[k][0], ly += d[k] * m.m[k][1], lz += d[k] * m.m[k][2];
        printf("  %-26s width %.3f m, tex %ux%u (height %.3f m), centre at x %+.3f y %+.3f z %+.4f (panel frame)\n",
               os[i].key.c_str(), wi, a, c, a ? wi * c / a : 0, lx, ly, lz);
    }
    // Rays from a "hand": 2 m in front of the panel centre (+z), 0.9 m below its bottom edge.
    auto P = [&](double x, double y, double z, double out[3]) {
        for (int k = 0; k < 3; ++k) out[k] = m.m[k][3] + x * m.m[k][0] + y * m.m[k][1] + z * m.m[k][2];
    };
    for (double hx : {0.0, -1.5}) {  // aim at the centre column, and 1.5 m left of it
        printf("\naim column x=%+.1f m (rays from 2 m in front, 0.9 m below the bottom edge):\n", hx);
        double src[3]; P(hx, -h / 2 - 0.9, 2.0, src);
        for (double off = 0.10; off >= -0.12; off -= 0.01) {
            double tgt[3]; P(hx, -h / 2 + off, 0, tgt);
            vr::VROverlayIntersectionParams_t ip{};
            ip.eOrigin = vr::TrackingUniverseStanding;
            double len = 0;
            for (int k = 0; k < 3; ++k) ip.vSource.v[k] = float(src[k]), ip.vDirection.v[k] = float(tgt[k] - src[k]), len += (tgt[k] - src[k]) * (tgt[k] - src[k]);
            len = std::sqrt(len);
            for (int k = 0; k < 3; ++k) ip.vDirection.v[k] = float(ip.vDirection.v[k] / len);
            printf("  aim %+.2f m from bottom edge:", off);
            for (auto &o : os) {
                vr::VROverlayIntersectionResults_t r;
                if (ov->ComputeOverlayIntersection(o.h, &ip, &r))
                    printf("  %s uv(%.3f,%.3f) d=%.3f", o.key.c_str() + 15, r.vUVs.v[0], r.vUVs.v[1], r.fDistance);
            }
            printf("\n");
        }
    }
    vr::VR_Shutdown();
}
