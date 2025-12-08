struct Uniforms {
  resolution : vec2<f32>,
  frameIndex : u32,
  _pad       : u32,
};

@group(0) @binding(0) var<uniform> uni : Uniforms;
@group(0) @binding(1) var colorIn : texture_2d<f32>;
@group(0) @binding(2) var albedoIn : texture_2d<f32>;
@group(0) @binding(3) var normalDepthIn : texture_2d<f32>;
@group(0) @binding(4) var prevColor : texture_2d<f32>;
@group(0) @binding(5) var prevMoments : texture_2d<f32>;
@group(0) @binding(6) var prevColorOut : texture_storage_2d<rgba16float, write>;
@group(0) @binding(7) var momentsOut : texture_storage_2d<rgba16float, write>;

fn luma(c: vec3<f32>) -> f32 { return dot(c, vec3(0.299,0.587,0.114)); }

@compute @workgroup_size(8,8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let res = uni.resolution;
  if (gid.x >= u32(res.x) || gid.y >= u32(res.y)) { return; }
  let p = vec2<i32>(i32(gid.x), i32(gid.y));

  let cur = textureLoad(colorIn, p, 0).xyz;
  let prev = textureLoad(prevColor, p, 0).xyz;
  let prevMom = textureLoad(prevMoments, p, 0).xy;

  var mean = prevMom.x;
  var m2 = prevMom.y;
  let val = luma(cur);
  let n = f32(uni.frameIndex);
  let delta = val - mean;
  mean += delta / n;
  m2 += delta * (val - mean);

  let alpha = 1.0 / n;
  let accum = mix(prev, cur, alpha);

  textureStore(prevColorOut, p, vec4<f32>(accum, 1.0));
  textureStore(momentsOut, p, vec4<f32>(mean, m2, 0.0, 0.0));
}

