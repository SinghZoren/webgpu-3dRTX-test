struct Uniforms {
  resolution : vec2<f32>,
  frameIndex : u32,
  enabled    : u32,
  _pad       : u32,
};

@group(0) @binding(0) var<uniform> uni : Uniforms;
@group(0) @binding(1) var colorIn : texture_2d<f32>;
@group(0) @binding(4) var prevColor : texture_2d<f32>;
@group(0) @binding(5) var prevMoments : texture_2d<f32>;
@group(0) @binding(6) var colorOut : texture_storage_2d<rgba16float, write>;
@group(0) @binding(7) var momentsOut : texture_storage_2d<rgba16float, write>;

@group(0) @binding(8) var motionIn : texture_2d<f32>;
@group(0) @binding(9) var prevIdDepth : texture_2d<f32>;
@group(0) @binding(11) var historyOut : texture_storage_2d<r32float, write>;
@group(0) @binding(12) var curIdDepth : texture_2d<f32>;

fn luma(c: vec3<f32>) -> f32 { return dot(c, vec3(0.299,0.587,0.114)); }

struct MinMax {
  mn: vec3<f32>,
  mx: vec3<f32>,
};

fn neighborhoodMinMax(img: texture_2d<f32>, p: vec2<i32>) -> MinMax {
  var mn = vec3<f32>(1e9);
  var mx = vec3<f32>(-1e9);
  for (var dy = -1; dy <= 1; dy = dy + 1) {
    for (var dx = -1; dx <= 1; dx = dx + 1) {
      let q = p + vec2<i32>(dx, dy);
      let c = textureLoad(img, q, 0).xyz;
      mn = min(mn, c);
      mx = max(mx, c);
    }
  }
  return MinMax(mn, mx);
}

@compute @workgroup_size(8,8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let res = uni.resolution;
  if (gid.x >= u32(res.x) || gid.y >= u32(res.y)) { return; }
  let p = vec2<i32>(i32(gid.x), i32(gid.y));

  let cur = textureLoad(colorIn, p, 0).xyz;
  let nb = neighborhoodMinMax(colorIn, p);

  if (uni.enabled == 0u) {
    textureStore(colorOut, p, vec4<f32>(cur, 1.0));
    textureStore(historyOut, p, vec4<f32>(0.0));
    return;
  }

  let prev = textureLoad(prevColor, p, 0).xyz;
  let prevMom = textureLoad(prevMoments, p, 0).xy;
  
  let val = luma(cur);
  let n = f32(uni.frameIndex);
  let alpha = 1.0 / n;

  let prevClamped = clamp(prev, nb.mn, nb.mx);
  
  var mean = prevMom.x;
  var m2 = prevMom.y;
  let delta = val - mean;
  mean += delta * alpha;
  m2 += delta * (val - mean);

  let accum = mix(prevClamped, cur, alpha);

  textureStore(colorOut, p, vec4<f32>(accum, 1.0));
  textureStore(momentsOut, p, vec4<f32>(mean, m2, 0.0, 0.0));
  

  let mot = textureLoad(motionIn, p, 0).xy;
  let idD1 = textureLoad(curIdDepth, p, 0).xy;
  let idD2 = textureLoad(prevIdDepth, p, 0).xy;
  let valid = f32(abs(idD1.x - idD2.x) < 0.01 && length(mot) < 1.0);
  textureStore(historyOut, p, vec4<f32>(valid, 0.0, 0.0, 1.0));
}
