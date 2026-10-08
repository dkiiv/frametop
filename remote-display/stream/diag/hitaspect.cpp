// hitaspect: does SteamVR hit-test a 256x24 overlay by its texture's shape, or by its mouse
// scale? Makes a throwaway overlay 0.4 m wide 1 m in front of the room origin, sweeps rays down
// its centre line, and reports the hit extent, with the default mouse scale and with 256x24.
#include <cmath>
#include <cstdio>
#include <vector>
#include <unistd.h>

#include "openvr.h"

static void Sweep(vr::VROverlayHandle_t o, const char *label) {
    double top = -1, bot = 1;
    for (double y = 0.5; y >= -0.5; y -= 0.0025) {
        vr::VROverlayIntersectionParams_t ip{};
        ip.eOrigin = vr::TrackingUniverseStanding;
        ip.vSource = {{0.f, float(1.0 + y), 0.f}};
        ip.vDirection = {{0.f, 0.f, -1.f}};
        vr::VROverlayIntersectionResults_t r;
        if (vr::VROverlay()->ComputeOverlayIntersection(o, &ip, &r)) top = std::max(top, y), bot = std::min(bot, y);
    }
    if (top < bot) printf("%-34s no hits\n", label);
    else printf("%-34s hit from %+.4f to %+.4f m -> %.4f m tall\n", label, bot, top, top - bot);
}

int main() {
    vr::EVRInitError err;
    vr::VR_Init(&err, vr::VRApplication_Overlay);
    if (err) return printf("VR_Init: %d\n", err), 1;
    auto *ov = vr::VROverlay();
    vr::VROverlayHandle_t o;
    if (ov->CreateOverlay("ftrd.hitaspect", "hit aspect probe", &o)) return printf("CreateOverlay failed\n"), 1;
    std::vector<uint8_t> px(256 * 24 * 4, 255);
    ov->SetOverlayRaw(o, px.data(), 256, 24, 4);
    ov->SetOverlayWidthInMeters(o, 0.4f);
    ov->SetOverlayInputMethod(o, vr::VROverlayInputMethod_Mouse);
    vr::HmdMatrix34_t m = {{{1, 0, 0, 0}, {0, 1, 0, 1}, {0, 0, 1, -1}}};
    ov->SetOverlayTransformAbsolute(o, vr::TrackingUniverseStanding, &m);
    ov->SetOverlayAlpha(o, 0.02f);  // nearly invisible; alpha 0 might not be hit-tested
    ov->ShowOverlay(o);
    usleep(1000000);
    uint32_t tw = 0, th = 0;
    ov->GetOverlayTextureSize(o, &tw, &th);
    printf("visible %d, texture %ux%u\n", ov->IsOverlayVisible(o), tw, th);
    {   // one straight ray at the centre, and one from the probe's own frame
        vr::VROverlayIntersectionParams_t ip{};
        ip.eOrigin = vr::TrackingUniverseStanding;
        ip.vSource = {{0.f, 1.f, 0.f}};
        ip.vDirection = {{0.f, 0.f, -1.f}};
        vr::VROverlayIntersectionResults_t r{};
        bool hit = ov->ComputeOverlayIntersection(o, &ip, &r);
        printf("centre ray: hit %d uv %.3f %.3f d %.3f\n", hit, r.vUVs.v[0], r.vUVs.v[1], r.fDistance);
        ip.vSource = {{0.f, 1.f, -2.f}};
        ip.vDirection = {{0.f, 0.f, 1.f}};
        hit = ov->ComputeOverlayIntersection(o, &ip, &r);
        printf("from behind: hit %d uv %.3f %.3f d %.3f\n", hit, r.vUVs.v[0], r.vUVs.v[1], r.fDistance);
    }
    printf("drawn: 0.4 m wide x %.4f m tall (256x24)\n", 0.4 * 24 / 256);
    vr::HmdVector2_t def{};
    ov->GetOverlayMouseScale(o, &def);
    char l[64];
    snprintf(l, sizeof l, "default mouse scale (%.0fx%.0f):", def.v[0], def.v[1]);
    Sweep(o, l);
    vr::HmdVector2_t s = {{256.f, 24.f}};
    ov->SetOverlayMouseScale(o, &s);
    usleep(100000);
    Sweep(o, "mouse scale 256x24:");
    s = {{1.f, 24.f / 256.f}};
    ov->SetOverlayMouseScale(o, &s);
    usleep(100000);
    Sweep(o, "mouse scale 1x0.094:");
    ov->DestroyOverlay(o);
    vr::VR_Shutdown();
}
