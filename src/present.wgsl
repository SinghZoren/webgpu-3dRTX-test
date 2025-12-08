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
  let c = textureSampleLevel(texIn, samp, uv, 0.0).xyz;
  let o = tonemapACES(c);
  return vec4<f32>(o, 1.0);
}
