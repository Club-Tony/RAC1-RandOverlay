#pragma once

/*
 * Resolution-aware sizing for the in-frame Vulkan overlay.
 *
 * The configured VulkanFontSize is the 1080p baseline. Scaling is deliberately
 * moderated so 4K remains readable without becoming twice as large as 1080p.
 * Values between the reference resolutions are linearly interpolated.
 */
namespace rolayout {

struct Metrics {
    float scale;
    float fontPx;
    float paddingX;
    float paddingY;
    float rounding;
};

inline float scaleForHeight(float height) {
    if (height <= 720.0f) return 0.75f;
    if (height <= 1080.0f)
        return 0.75f + ((height - 720.0f) / 360.0f) * 0.25f;
    if (height <= 1440.0f)
        return 1.00f + ((height - 1080.0f) / 360.0f) * 0.25f;
    if (height <= 2160.0f)
        return 1.25f + ((height - 1440.0f) / 720.0f) * 0.25f;
    return 1.50f;
}

inline Metrics metricsForHeight(float height, float baseFontPx) {
    const float scale = scaleForHeight(height);
    return {
        scale,
        baseFontPx * scale,
        12.0f * scale,
        8.0f * scale,
        7.0f * scale
    };
}

} // namespace rolayout
