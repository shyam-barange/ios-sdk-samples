/*
Copyright (c) 2026 MultiSet AI. All rights reserved.
Licensed under the MultiSet License. You may not use this file except in compliance with the License. and you can't re-distribute this file without a prior notice
For license details, visit www.multiset.ai.
Redistribution in source or binary forms must retain this notice.
*/

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

// The adapter's outlineGeometry: push every vertex out along its normal.
// custom_parameter.x = outline width in model units.
[[visible]]
void edgeOutlineGeometry(realitykit::geometry_parameters params) {
    float width = params.uniforms().custom_parameter().x;
    params.geometry().set_model_position_offset(params.geometry().normal() * width);
}

// Held still: a moving glow hides how well the outline fits.
// custom_parameter.yzw = the line's colour; opaque, so a thin line reads on dark and light.
[[visible]]
void edgeOutlineSurface(realitykit::surface_parameters params) {
    half3 color = half3(params.uniforms().custom_parameter().yzw);
    params.surface().set_base_color(color);
    params.surface().set_emissive_color(color);
    params.surface().set_opacity(1.0h);
}
