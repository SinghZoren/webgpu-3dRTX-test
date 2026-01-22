struct Uniforms {
  resolution : vec2<f32>,
  stepWidth : u32,
  enabled : u32,
};

@group(0) @binding(0) var<uniform> uni : Uniforms;
@group(0) @binding(1) var colorIn : texture_2d<f32>;
@group(0) @binding(3) var normalDepthIn : texture_2d<f32>;
@group(0) @binding(4) var momentsIn : texture_2d<f32>;
@group(0) @binding(5) var colorOut : texture_storage_2d<rgba16float, write>;

fn wNorm(a: vec3<f32>, b: vec3<f32>) -> f32 {
  return exp(-max(0.0, 1.0 - dot(a, b)) * 150.0);
}
fn wDepth(a: f32, b: f32) -> f32 {
  return exp(-abs(a - b) * 80.0);
}

@compute @workgroup_size(8,8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let res = uni.resolution;
  if (gid.x >= u32(res.x) || gid.y >= u32(res.y)) { return; }
  let p = vec2<i32>(i32(gid.x), i32(gid.y));
  let step = i32(uni.stepWidth);

  let c0 = textureLoad(colorIn, p, 0).xyz;
  if (uni.enabled == 0u) {
    textureStore(colorOut, p, vec4<f32>(c0, 1.0));
    return;
  }
  let n0 = textureLoad(normalDepthIn, p, 0).xyz * 2.0 - 1.0;
  let d0 = textureLoad(normalDepthIn, p, 0).w;
  let varMean = textureLoad(momentsIn, p, 0).xy;
  let sigma = sqrt(max(1e-4, varMean.y / max(1.0, varMean.x * varMean.x)));


  if (sigma > 0.15) {
    textureStore(colorOut, p, vec4<f32>(c0, 1.0));
    return;
  }

  var sum = vec3<f32>(0.0);
  var wsum = 0.0;

  for (var dy = -2; dy <= 2; dy = dy + 1) {
    for (var dx = -2; dx <= 2; dx = dx + 1) {
      let q = p + vec2<i32>(dx * step, dy * step);
      if (q.x < 0 || q.y < 0 || q.x >= i32(res.x) || q.y >= i32(res.y)) { continue; }
      let c = textureLoad(colorIn, q, 0).xyz;
      let n = textureLoad(normalDepthIn, q, 0).xyz * 2.0 - 1.0;
      let d = textureLoad(normalDepthIn, q, 0).w;
      let lumDiff = abs(dot(c, vec3(0.299,0.587,0.114)) - dot(c0, vec3(0.299,0.587,0.114)));
      let w = wNorm(n0, n) * wDepth(d0, d) * exp(-length(c - c0) / (0.01 + sigma * 0.5)) * exp(-lumDiff / (0.02 + sigma));
      sum += c * w;
      wsum += w;
    }
  }

  let outColor = select(c0, sum / max(1e-4, wsum), wsum > 0.0);
  textureStore(colorOut, p, vec4<f32>(outColor, 1.0));
}

