struct VSOut {
  @builtin(position) pos: vec4<f32>,
  @location(0) uv: vec2<f32>,
};

@vertex
fn vsMain(@builtin(vertex_index) vi: u32) -> VSOut {
  var p = array<vec2<f32>,3>(vec2(-1.0,-3.0), vec2(-1.0,1.0), vec2(3.0,1.0));
  var o: VSOut;
  o.pos = vec4<f32>(p[vi], 0.0, 1.0);
  o.uv = (o.pos.xy * 0.5) + 0.5;
  return o;
}

@group(0) @binding(0) var texIn: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

struct DebugUni {
  res: vec2<f32>,
  frame: u32,
  temporal: u32,
  mode: u32,
};
@group(0) @binding(2) var<uniform> dbg: DebugUni;
@group(0) @binding(3) var rawIn: texture_2d<f32>;
@group(0) @binding(4) var motIn: texture_2d<f32>;
@group(0) @binding(5) var histIn: texture_2d<f32>;

fn tonemapACES(x: vec3<f32>) -> vec3<f32> {
  let a = 2.51;
  let b = 0.03;
  let c = 2.43;
  let d = 0.59;
  let e = 0.14;
  let y = (x * (a * x + b)) / (x * (c * x + d) + e);
  return pow(clamp(y, vec3(0.0), vec3(1.0)), vec3(1.0/2.2));
}

@fragment
fn fsMain(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
  let p = vec2<i32>(uv * dbg.res);
  var color = textureSampleLevel(texIn, samp, uv, 0.0).xyz;

  if (dbg.mode == 1u) {
    color = textureLoad(rawIn, p, 0).xyz;
  } else if (dbg.mode == 2u) {
    let mot = textureLoad(motIn, p, 0).xy;
    color = vec3(abs(mot) * 10.0, 0.0);
  } else if (dbg.mode == 3u) {
    let hist = textureLoad(histIn, p, 0).x;
    color = vec3(hist, hist * 0.5, 1.0 - hist);
  } else if (dbg.mode == 4u) {
    let hist = textureLoad(histIn, p, 0).x;
    if (hist < 0.01 && dbg.frame > 2u) {
      color = vec3(1.0, 0.0, 0.0);
    } else {
      color *= 0.2;
    }
  }

  let px = u32(uv.x * 65535.0);
  let py = u32(uv.y * 65535.0);
  var x = px ^ (py * 0x27d4eb2du) ^ 0x165667b1u;
  x ^= x >> 15u; x *= 0xd168aaadu; x ^= x >> 15u; x *= 0xaf723597u; x ^= x >> 15u;
  let dither = (f32(x >> 8u) * (1.0 / 16777216.0) - 0.5) / 255.0;
  
  return vec4<f32>(tonemapACES(color + dither), 1.0);
}
