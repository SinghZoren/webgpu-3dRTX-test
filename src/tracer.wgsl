struct Uniforms {
  resolution : vec2<f32>,
  frameIndex : u32,
  preset     : u32,
  camPos     : vec4<f32>,
  camU       : vec4<f32>,
  camV       : vec4<f32>,
  camW       : vec4<f32>,
  blobColor  : vec4<f32>, 
  settings   : vec4<f32>, 
};

@group(0) @binding(0) var<uniform> uni : Uniforms;
@group(0) @binding(1) var radianceTex : texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var gbufAlbedo : texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var gbufNormalDepth : texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var motionTex : texture_storage_2d<rgba16float, write>;
@group(0) @binding(5) var idDepthTex : texture_storage_2d<rg32float, write>;

fn splitmix32(x0: u32) -> u32 {
  var x = x0 + 0x9E3779B9u;
  var z = x;
  z = (z ^ (z >> 16u)) * 0x85EBCA6Bu;
  z = (z ^ (z >> 13u)) * 0xC2B2AE35u;
  z = z ^ (z >> 16u);
  return z;
}

fn make_seed(px: u32, py: u32, frame: u32, sample: u32) -> u32 {
  let s = (px * 0x1f123bb5u) ^ (py * 0x5f7a0e1du) ^ (frame * 0x9e3779b9u) ^ (sample * 0x68bc21ebu);
  return splitmix32(s);
}

struct PCG {
  state: u32,
};

fn pcg_step(state: u32) -> u32 {
  let mul: u32 = 747796405u;
  let inc: u32 = 2891336453u;
  var x = state * mul + inc;
  let rot = ((x >> 28u) + 4u) & 31u;
  var word = ((x >> rot) ^ x) * 277803737u;
  return word;
}

fn pcg_init(px: u32, py: u32, frame: u32, sample: u32) -> PCG {
  return PCG(make_seed(px, py, frame, sample));
}

fn rng_u32(r: ptr<function, PCG>) -> u32 {
  let v = pcg_step((*r).state);
  (*r).state = v;
  return v;
}

fn rng_f32(r: ptr<function, PCG>) -> f32 {
  let u = rng_u32(r) >> 8u;
  return f32(u) * (1.0 / 16777216.0);
}

fn radicalInverseVdC(bits: u32) -> f32 {
  var b = bits;
  b = (b << 16u) | (b >> 16u);
  b = ((b & 0x55555555u) << 1u) | ((b & 0xAAAAAAAAu) >> 1u);
  b = ((b & 0x33333333u) << 2u) | ((b & 0xCCCCCCCCu) >> 2u);
  b = ((b & 0x0F0F0F0Fu) << 4u) | ((b & 0xF0F0F0F0u) >> 4u);
  b = ((b & 0x00FF00FFu) << 8u) | ((b & 0xFF00FF00u) >> 8u);
  return f32(b) * 2.3283064365386963e-10;
}

fn halton(i0: u32, base: u32) -> f32 {
  var i = i0;
  var f = 1.0;
  var r = 0.0;
  let inv = 1.0 / f32(base);
  loop {
    if (i == 0u) { break; }
    f = f * inv;
    r = r + f * f32(i % base);
    i = i / base;
  }
  return r;
}

fn pixel_jitter(frame: u32) -> vec2<f32> {
  let jx = halton(frame + 1u, 2u);
  let jy = halton(frame + 1u, 3u);
  return vec2<f32>(jx, jy) - vec2<f32>(0.5, 0.5);
}

struct Material {
  base: vec3<f32>,
  rough: f32,
  metal: f32,
  emit: vec3<f32>,
};

struct Hit {
  p: vec3<f32>,
  n: vec3<f32>,
  t: f32,
  mat: Material,
  hit: bool,
  id: f32,
};

struct BoxHit {
  p: vec3<f32>,
  n: vec3<f32>,
  t: f32,
  hit: bool,
};

fn schlickF0(base: vec3<f32>, metal: f32) -> vec3<f32> {
  return mix(vec3(0.04), base, metal);
}

fn fresnelSchlick(cosTheta: f32, F0: vec3<f32>) -> vec3<f32> {
  return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

fn smithG1(a: f32, cosTheta: f32) -> f32 {
  let a2 = a*a;
  let b = abs(cosTheta);
  return 2.0 * b / (b + sqrt(a2 + (1.0 - a2)*b*b));
}

fn ggx_eval(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, rough: f32, F0: vec3<f32>) -> vec3<f32> {
  let h = normalize(v + l);
  let NoV = max(1e-4, dot(n, v));
  let NoL = max(1e-4, dot(n, l));
  let NoH = max(1e-4, dot(n, h));
  let VoH = max(1e-4, dot(v, h));
  let a = max(0.02, rough*rough);
  let a2 = a*a;
  let D = a2 / (3.14159265 * pow((NoH*NoH*(a2 - 1.0) + 1.0), 2.0));
  let G = smithG1(a, NoV) * smithG1(a, NoL);
  let F = fresnelSchlick(VoH, F0);
  return (D * G * F) / max(1e-4, 4.0 * NoV * NoL);
}

fn reflect(i: vec3<f32>, n: vec3<f32>) -> vec3<f32> {
  return i - 2.0 * dot(i, n) * n;
}

fn refractDir(i: vec3<f32>, n: vec3<f32>, eta: f32) -> vec3<f32> {
  let cosi = clamp(dot(-i, n), -1.0, 1.0);
  let k = 1.0 - eta * eta * (1.0 - cosi * cosi);
  if (k < 0.0) {
    return reflect(i, n); 
  }
  return eta * i + (eta * cosi - sqrt(k)) * n;
}

const boxMin = vec3(-1.75, 0.0, -2.8);
const boxMax = vec3(1.75, 1.3, -1.4);

fn simTime() -> f32 {
  let base = f32(uni.frameIndex) * 0.016;
  return base * (uni.settings.x / max(0.25, uni.settings.y));
}

fn lavaBlobCenter(i: u32, t: f32) -> vec3<f32> {
  let lavaPhase = array<f32, 24u>(0.0, 1.5, 3.1, 0.8, 2.4, 4.2, 5.7, 1.1, 2.9, 3.8, 0.3, 5.1, 0.6, 1.9, 3.5, 4.8, 0.2, 1.4, 2.7, 4.0, 5.3, 0.9, 2.2, 3.6);
  let lavaXSeed = array<f32, 24u>(-0.8, 0.4, -0.2, 0.7, -0.5, 0.1, -0.9, 0.3, 0.6, -0.4, 0.0, -0.1, -0.6, 0.2, -0.3, 0.5, -0.7, 0.1, -0.4, 0.8, -0.2, 0.3, -0.5, 0.0);
  let lavaZSeed = array<f32, 24u>(-2.1, -2.2, -2.05, -2.15, -2.25, -2.1, -2.2, -2.0, -2.1, -2.2, -2.15, -2.05, -2.1, -2.2, -2.0, -2.1, -2.2, -2.15, -2.05, -2.1, -2.2, -2.0, -2.1, -2.2);
  let ph = lavaPhase[i];
  let yCycle = (t * 0.4 + ph) % 6.283185;
  let yNorm = 0.5 + 0.5 * sin(yCycle - 1.5707);
  let xAmp = 0.4 + 0.2 * sin(t * 0.2 + ph * 1.3);
  let zAmp = 0.1 + 0.05 * cos(t * 0.3 + ph * 0.7);
  let xOffset = xAmp * sin(t * 0.5 + ph * 2.1) + lavaXSeed[i];
  let zOffset = zAmp * cos(t * 0.4 + ph * 1.5) + lavaZSeed[i];
  let wallT = 0.12;
  let ymin = boxMin.y + wallT + 0.15;
  let ymax = boxMax.y - 0.2;
  return vec3(clamp(xOffset, boxMin.x + wallT, boxMax.x - wallT), mix(ymin, ymax, yNorm), clamp(zOffset, boxMin.z + wallT, boxMax.z - wallT));
}

fn lavaBlobRadius(i: u32, t: f32) -> f32 {
  let lavaPhase = array<f32, 24u>(0.0, 1.5, 3.1, 0.8, 2.4, 4.2, 5.7, 1.1, 2.9, 3.8, 0.3, 5.1, 0.6, 1.9, 3.5, 4.8, 0.2, 1.4, 2.7, 4.0, 5.3, 0.9, 2.2, 3.6);
  let ph = lavaPhase[i];
  let yCycle = (t * 0.4 + ph) % 6.283185;
  let yNorm = 0.5 + 0.5 * sin(yCycle - 1.5707); 
  let heatExpansion = mix(1.2, 0.8, yNorm);
  let wobble = 0.1 * sin(t * 1.5 + ph);
  return (0.08 + 0.04 * wobble) * heatExpansion;
}

fn smin(a: f32, b: f32, k: f32) -> f32 {
    let h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

fn lavaSDF(p: vec3<f32>, t: f32) -> f32 {
    var d = 1e9;
    let count = u32(uni.settings.w);
    for (var i: u32 = 0u; i < count; i = i + 1u) {
        let c = lavaBlobCenter(i, t);
        let r = lavaBlobRadius(i, t);
        let dist = length(p - c) - r;
        if (i == 0u) { d = dist; } else { d = smin(d, dist, 0.28); }
    }
    return d;
}
fn intersectScene(ro: vec3<f32>, rd: vec3<f32>) -> Hit {
  var best = Hit(vec3(0.0), vec3(0.0), 1e9, Material(vec3(0.0),0.0,0.0,vec3(0.0)), false, -1.0);
  if (abs(rd.y) > 1e-5) {
    let t = -ro.y / rd.y; if (t > 1e-4 && t < best.t) {
      let p = ro + t*rd; if (p.z >= -100.0 && p.z <= 100.0) { best = Hit(p, vec3(0.0,1.0,0.0), t, Material(vec3(0.002), 0.1, 0.8, vec3(0.0)), true, 1.0); }
    }
  }
  if (abs(rd.z) > 1e-5) {
    let t = (-3.0 - ro.z) / rd.z; if (t > 1e-4 && t < best.t) {
      let p = ro + t*rd; if (p.y >= -100.0 && p.y <= 100.0) { best = Hit(p, vec3(0.0,0.0,1.0), t, Material(vec3(0.002), 0.8, 1.0, vec3(0.0)), true, 2.0); }
    }
  }
  { 
    let glassMat = Material(vec3(1.0), 0.02, 2.0, vec3(0.0));
    if (abs(rd.x) > 1e-5) {
      let t = (boxMin.x - ro.x) / rd.x; if (t > 1e-4 && t < best.t) {
        let p = ro + t*rd; if (p.y >= boxMin.y && p.y <= boxMax.y && p.z >= boxMin.z && p.z <= boxMax.z) { best = Hit(p, vec3(1.0, 0.0, 0.0), t, glassMat, true, 3.0); }
      }
      let t2 = (boxMax.x - ro.x) / rd.x; if (t2 > 1e-4 && t2 < best.t) {
        let p = ro + t2*rd; if (p.y >= boxMin.y && p.y <= boxMax.y && p.z >= boxMin.z && p.z <= boxMax.z) { best = Hit(p, vec3(-1.0, 0.0, 0.0), t2, glassMat, true, 4.0); }
      }
    }
    if (abs(rd.z) > 1e-5) {
      let t = (boxMin.z - ro.z) / rd.z; if (t > 1e-4 && t < best.t) {
        let p = ro + t*rd; if (p.y >= boxMin.y && p.y <= boxMax.y && p.x >= boxMin.x && p.x <= boxMax.x) { best = Hit(p, vec3(0.0, 0.0, 1.0), t, glassMat, true, 5.0); }
      }
      let t2 = (boxMax.z - ro.z) / rd.z; if (t2 > 1e-4 && t2 < best.t) {
        let p = ro + t2*rd; if (p.y >= boxMin.y && p.y <= boxMax.y && p.x >= boxMin.x && p.x <= boxMax.x) { best = Hit(p, vec3(0.0, 0.0, -1.0), t2, glassMat, true, 6.0); }
      }
    }
    if (abs(rd.y) > 1e-5) {
      let t = (boxMin.y - ro.y) / rd.y; if (t > 1e-4 && t < best.t) {
        let p = ro + t*rd; if (p.x >= boxMin.x && p.x <= boxMax.x && p.z >= boxMin.z && p.z <= boxMax.z) { best = Hit(p, vec3(0.0, 1.0, 0.0), t, glassMat, true, 7.0); }
      }
    }
  }
  let t_sim = simTime();
  var t_enter = 0.0; var t_exit = best.t;
  {
    let invDir = 1.0 / rd; let t0 = (boxMin - ro) * invDir; let t1 = (boxMax - ro) * invDir;
    let tmin = min(t0, t1); let tmax = max(t0, t1);
    t_enter = max(t_enter, max(tmin.x, max(tmin.y, tmin.z))); t_exit = min(t_exit, min(tmax.x, min(tmax.y, tmax.z)));
  }
  if (t_enter < t_exit && t_enter < best.t) {
    var t_march = max(t_enter, 1e-3); let t_end = min(t_exit, best.t);
    for (var i = 0; i < 40; i = i + 1) { 
      let p = ro + rd * t_march; let d = lavaSDF(p, t_sim);
      if (d < 0.0015) { 
        if (t_march < best.t) {
          let eps = 0.003; let d0 = lavaSDF(p, t_sim);
          let nx = lavaSDF(p + vec3(eps, 0.0, 0.0), t_sim) - d0;
          let ny = lavaSDF(p + vec3(0.0, eps, 0.0), t_sim) - d0;
          let nz = lavaSDF(p + vec3(0.0, 0.0, eps), t_sim) - d0;
          let n = normalize(vec3(nx, ny, nz));
          let heatHeight = (p.y - boxMin.y) / (boxMax.y - boxMin.y);
          let userColor = uni.blobColor.xyz; let userIntensity = uni.blobColor.w;
          let baseCol = mix(userColor * 0.5, userColor * 0.2, heatHeight);
          let emitCol = mix(userColor * userIntensity, userColor * (userIntensity * 0.2), heatHeight);
          best = Hit(p, n, t_march, Material(baseCol, uni.settings.z, 0.0, emitCol), true, 10.0 + f32(i));
        }
        break;
      }
      t_march += d * 0.98; if (t_march > t_end) { break; }
    }
  }
  return best;
}

struct RectLight { c: vec3<f32>, ux: vec3<f32>, uy: vec3<f32>, emit: vec3<f32>, };
fn sampleRectLight(light: RectLight, xi: vec2<f32>) -> vec3<f32> { return light.c + (xi.x - 0.5) * 2.0 * light.ux + (xi.y - 0.5) * 2.0 * light.uy; }
fn rectLightPdf(light: RectLight, pos: vec3<f32>, dir: vec3<f32>) -> f32 {
  let area = length(cross(light.ux * 2.0, light.uy * 2.0));
  let cosL = max(0.0, dot(normalize(cross(light.ux, light.uy)), -dir));
  let dist2 = dot(pos - light.c, pos - light.c);
  return dist2 / max(1e-4, area * cosL);
}
fn traceShadow(ro: vec3<f32>, rd: vec3<f32>, maxT: f32) -> bool {
  let h = intersectScene(ro, rd); 
  if (!h.hit) { return true; } 
  if (h.mat.metal > 1.5) { return true; } 
  if (any(h.mat.emit > vec3(0.01))) { return true; } 
  return h.t > maxT - 1e-3;
}

@compute @workgroup_size(8,8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let res = uni.resolution; if (gid.x >= u32(res.x) || gid.y >= u32(res.y)) { return; }
  let pix = vec2<u32>(gid.xy); let fi = uni.frameIndex;
  var spp: u32 = 2u; var maxB: u32 = 4u;
  switch (uni.preset) {
    case 0u: { spp = 2u; maxB = 4u; }
    case 1u: { spp = 8u; maxB = 4u; }
    case 2u: { spp = 16u; maxB = 5u; }
    case 3u: { spp = 32u; maxB = 5u; }
    default: { spp = 64u; maxB = 6u; }
  }
  var accumColor = vec3<f32>(0.0); var accumAlbedo = vec3<f32>(0.0); var accumNormal = vec3<f32>(0.0); var accumDepth = 0.0; var accumId = 0.0;
  for (var s = 0u; s < spp; s = s + 1u) {
    var rng = pcg_init(pix.x, pix.y, fi, s); let jitterFrame = pixel_jitter(fi); let xi = vec2<f32>(rng_f32(&rng), rng_f32(&rng));
    let uv = ((vec2<f32>(pix) + xi + jitterFrame) / res) * 2.0 - 1.0;
    let ro = uni.camPos.xyz; let rd = normalize(uv.x * uni.camU.xyz + uv.y * uni.camV.xyz + uni.camW.xyz);
    var throughput = vec3(1.0); var radiance = vec3(0.0); var rayO = ro; var rayD = rd;
    var firstNormal = vec3(0.0); var firstAlbedo = vec3(0.0); var firstDepth = 0.0; var firstId = -1.0; var stored = false;
    let rect = RectLight(vec3(0.0, 2.4, -1.6), vec3(0.8,0,0), vec3(0,0,-0.3), vec3(30.0));
    for (var bounce = 0u; bounce < maxB; bounce = bounce + 1u) {
      let h = intersectScene(rayO, rayD); if (!h.hit) { break; }
      let isGlass = h.mat.metal > 1.5;
      if (isGlass) {
        let n = h.n; let vd = rayD; let entering = dot(vd, n) < 0.0; let eta = select(1.5, 1.0 / 1.5, entering);
        let nl = select(-n, n, entering); let cosi = max(0.0, dot(-vd, nl)); let fres = fresnelSchlick(cosi, vec3(0.04)).x;
        radiance += throughput * fres * vec3(0.05); let xiG = rng_f32(&rng);
        if (xiG < fres) { rayO = h.p + nl * 1e-3; rayD = reflect(vd, nl); } else { rayO = h.p - nl * 1e-3; rayD = refractDir(vd, nl, eta); throughput *= vec3(0.98, 0.98, 1.0); }
        continue;
      }
      if (!stored) { firstNormal = h.n; firstAlbedo = h.mat.base; firstDepth = h.t; firstId = h.id; stored = true; }
      if (length(h.mat.emit) > 0.0) { radiance += throughput * h.mat.emit; break; }
      let xiL = vec2<f32>(rng_f32(&rng), rng_f32(&rng)); let lp = sampleRectLight(rect, xiL); let ldir = normalize(lp - h.p); let dist = length(lp - h.p);
      if (traceShadow(h.p + h.n * 1e-3, ldir, dist)) {
        let cosL = max(0.0, dot(h.n, ldir)); let F0 = schlickF0(h.mat.base, h.mat.metal);
        let spec = ggx_eval(h.n, -rayD, ldir, h.mat.rough, F0); let bsdf = (1.0 - h.mat.metal) * h.mat.base / 3.14159265 + spec;
        radiance += throughput * rect.emit * bsdf * cosL / max(1e-4, rectLightPdf(rect, lp, -ldir));
      }
      let xiD = vec2<f32>(rng_f32(&rng), rng_f32(&rng)); let phi = 6.2831853 * xiD.x; let r = sqrt(xiD.y);
      let x = r * cos(phi); let z = r * sin(phi); let y = sqrt(max(0.0, 1.0 - r*r));
      let up = select(vec3(0.0,1.0,0.0), vec3(1.0,0.0,0.0), abs(h.n.y) > 0.999);
      let t = normalize(cross(up, h.n)); let b = cross(h.n, t); let ndir = normalize(t*x + b*z + h.n*y);
      throughput *= ((1.0 - h.mat.metal) * h.mat.base / 3.14159265) * max(0.0, dot(h.n, ndir)) / 0.5;
      rayO = h.p + h.n * 1e-3; rayD = ndir;
      if (bounce >= 2u) { let p = clamp(max(throughput.x, max(throughput.y, throughput.z)), 0.2, 0.95); if (rng_f32(&rng) > p) { break; } throughput /= p; }
    }
    radiance = min(radiance, vec3(8.0)); accumColor += radiance;
    if (stored) { accumAlbedo += firstAlbedo; accumNormal += firstNormal; accumDepth += firstDepth; accumId += firstId; }
  }
  let invSpp = 1.0 / f32(spp);
  textureStore(radianceTex, vec2<i32>(gid.xy), vec4<f32>(accumColor * invSpp, 1.0));
  textureStore(gbufAlbedo, vec2<i32>(gid.xy), vec4<f32>(accumAlbedo * invSpp, 1.0));
  textureStore(gbufNormalDepth, vec2<i32>(gid.xy), vec4<f32>(accumNormal * invSpp * 0.5 + 0.5, accumDepth * invSpp));
  textureStore(idDepthTex, vec2<i32>(gid.xy), vec4<f32>(accumId * invSpp, accumDepth * invSpp, 0.0, 1.0));
  textureStore(motionTex, vec2<i32>(gid.xy), vec4<f32>(0.0, 0.0, 0.0, 1.0));
}
