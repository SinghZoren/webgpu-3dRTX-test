struct Uniforms {
  resolution : vec2<f32>,
  frameIndex : u32,
  preset     : u32,
  camPos     : vec4<f32>,
  camU       : vec4<f32>,
  camV       : vec4<f32>,
  camW       : vec4<f32>,
  counts     : vec4<u32>,
};

@group(0) @binding(0) var<uniform> uni : Uniforms;
@group(0) @binding(1) var radianceTex : texture_storage_2d<rgba16float, write>;
@group(0) @binding(2) var gbufAlbedo : texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var gbufNormalDepth : texture_storage_2d<rgba16float, write>;
@group(0) @binding(4) var blueNoiseTex : texture_2d<f32>;
@group(0) @binding(5) var blueNoiseSamp : sampler;

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

fn hammersley(i: u32, n: u32, pix: vec2<u32>, frame: u32) -> vec2<f32> {
  var rng = pcg_init(pix.x, pix.y, frame, i);
  var rng2 = pcg_init(pix.x ^ 123u, pix.y ^ 321u, frame, i);
  let jitter = vec2<f32>(rng_f32(&rng), rng_f32(&rng2));
  return vec2<f32>((f32(i) + jitter.x) / f32(n), radicalInverseVdC(i));
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

fn intersectScene(ro: vec3<f32>, rd: vec3<f32>) -> Hit {
  var best = Hit(vec3(0.0), vec3(0.0), 1e9, Material(vec3(0.0),0.0,0.0,vec3(0.0)), false);

  if (abs(rd.y) > 1e-5) {
    let t = -ro.y / rd.y;
    if (t > 1e-4 && t < best.t) {
      let p = ro + t*rd;
      if (p.z >= -100.0 && p.z <= 100.0) {
        best = Hit(p, vec3(0.0,1.0,0.0), t, Material(vec3(0.02), 0.6, 0.0, vec3(0.0)), true);
      }
    }
  }

  if (abs(rd.z) > 1e-5) {
    let t = (-3.0 - ro.z) / rd.z;
    if (t > 1e-4 && t < best.t) {
      let p = ro + t*rd;
      if (p.y >= -100.0 && p.y <= 100.0) {
        best = Hit(p, vec3(0.0,0.0,1.0), t, Material(vec3(0.02), 0.6, 0.0, vec3(0.0)), true);
      }
    }
  }

  {
    let c = vec3(-0.45, 0.5, -2.2);
    let r = 0.12;
    let h = 1.0;
    let roL = ro - c;
    let a = dot(rd.xz, rd.xz);
    let b = dot(roL.xz, rd.xz);
    let cc = dot(roL.xz, roL.xz) - r*r;
    let d = b*b - a*cc;
    if (d > 0.0) {
      let t = (-b - sqrt(d)) / a;
      let y = roL.y + t*rd.y;
      if (t > 1e-4 && t < best.t && y >= -h*0.5 && y <= h*0.5) {
        let p = ro + t*rd;
        let n = normalize(vec3(p.x - c.x, 0.0, p.z - c.z));
        best = Hit(p, n, t, Material(vec3(0.08), 0.25, 0.0, vec3(0.0)), true);
      }
    }
  }

  {
    let c = vec3(-0.45, 0.06, -2.2);
    let r = 0.14;
    let h = 0.12;
    let roL = ro - c;
    let a = dot(rd.xz, rd.xz);
    let b = dot(roL.xz, rd.xz);
    let cc = dot(roL.xz, roL.xz) - r*r;
    let d = b*b - a*cc;
    if (d > 0.0) {
      let t = (-b - sqrt(d)) / a;
      let y = roL.y + t*rd.y;
      if (t > 1e-4 && t < best.t && y >= -h*0.5 && y <= h*0.5) {
        let p = ro + t*rd;
        let n = normalize(vec3(p.x - c.x, 0.0, p.z - c.z));
        best = Hit(p, n, t, Material(vec3(0.1), 0.3, 1.0, vec3(0.0)), true);
      }
    }
  }

  {
    let c = vec3(-0.45, 0.12, -2.2);
    let r = 0.03;
    let oc = ro - c;
    let b = dot(oc, rd);
    let cc = dot(oc, oc) - r*r;
    let d = b*b - cc;
    if (d > 0.0) {
      let t = -b - sqrt(d);
      if (t > 1e-4 && t < best.t) {
        let p = ro + t*rd;
        let n = normalize(p - c);
        best = Hit(p, n, t, Material(vec3(0.0), 0.0, 0.0, vec3(25.0)), true);
      }
    }
  }

  return best;
}

struct RectLight {
  c: vec3<f32>,
  ux: vec3<f32>,
  uy: vec3<f32>,
  emit: vec3<f32>,
};

fn sampleRectLight(light: RectLight, xi: vec2<f32>) -> vec3<f32> {
  return light.c + (xi.x - 0.5) * 2.0 * light.ux + (xi.y - 0.5) * 2.0 * light.uy;
}

fn rectLightPdf(light: RectLight, pos: vec3<f32>, dir: vec3<f32>) -> f32 {
  let area = length(cross(light.ux * 2.0, light.uy * 2.0));
  let cosL = max(0.0, dot(normalize(cross(light.ux, light.uy)), -dir));
  let dist2 = dot(pos - light.c, pos - light.c);
  return dist2 / max(1e-4, area * cosL);
}

fn traceShadow(ro: vec3<f32>, rd: vec3<f32>, maxT: f32) -> bool {
  let h = intersectScene(ro, rd);
  if (!h.hit) { return true; }
  return h.t > maxT - 1e-3;
}

@compute @workgroup_size(8,8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let res = uni.resolution;
  if (gid.x >= u32(res.x) || gid.y >= u32(res.y)) { return; }
  let pix = vec2<u32>(gid.xy);
  let fi = uni.frameIndex;

  var accumColor = vec3<f32>(0.0);
  var accumAlbedo = vec3<f32>(0.0);
  var accumNormal = vec3<f32>(0.0);
  var accumDepth = 0.0;

  let spp = 4u; 

  for (var s = 0u; s < spp; s = s + 1u) {
    var rng = pcg_init(pix.x, pix.y, fi, s);
    let jitterFrame = pixel_jitter(fi);
    let xi = vec2<f32>(rng_f32(&rng), rng_f32(&rng));
    var uv = ((vec2<f32>(pix) + xi + jitterFrame) / res) * 2.0 - 1.0;
    uv.x *= res.x / res.y;

    let ro = uni.camPos.xyz;
    let rd = normalize(uv.x * uni.camU.xyz + uv.y * uni.camV.xyz + uni.camW.xyz);

    var throughput = vec3(1.0);
    var radiance = vec3(0.0);
    var rayO = ro;
    var rayD = rd;

    var firstNormal = vec3(0.0);
    var firstAlbedo = vec3(0.0);
    var firstDepth = 0.0;
    var stored = false;

    let rect = RectLight(vec3(0.0, 2.4, -1.6), vec3(0.8,0,0), vec3(0,0,-0.3), vec3(3.0));

    let maxB = select(4u, 3u, uni.preset == 0u);

    for (var bounce = 0u; bounce < maxB; bounce = bounce + 1u) {
      let h = intersectScene(rayO, rayD);
      if (!h.hit) { break; }

      if (!stored) {
        firstNormal = h.n;
        firstAlbedo = h.mat.base;
        firstDepth = h.t;
        stored = true;
      }

      if (length(h.mat.emit) > 0.0) {
        radiance += throughput * h.mat.emit;
        break;
      }

      let xiL = vec2<f32>(rng_f32(&rng), rng_f32(&rng));
      let lp = sampleRectLight(rect, xiL);
      let ldir = normalize(lp - h.p);
      let dist = length(lp - h.p);
      let vis = traceShadow(h.p + h.n * 1e-3, ldir, dist);
      if (vis) {
        let cosL = max(0.0, dot(h.n, ldir));
        let F0 = schlickF0(h.mat.base, h.mat.metal);
        let spec = ggx_eval(h.n, -rayD, ldir, h.mat.rough, F0);
        let diff = h.mat.base / 3.14159265;
        let bsdf = mix(diff, spec, 0.5);
        let pdfL = rectLightPdf(rect, lp, -ldir);
        radiance += throughput * rect.emit * bsdf * cosL / max(1e-4, pdfL);
      }

      let xiD = vec2<f32>(rng_f32(&rng), rng_f32(&rng));
      let phi = 6.2831853 * xiD.x;
      let r = sqrt(xiD.y);
      let x = r * cos(phi);
      let z = r * sin(phi);
      let y = sqrt(max(0.0, 1.0 - r*r));
      let up = select(vec3(0.0,1.0,0.0), vec3(1.0,0.0,0.0), abs(h.n.y) > 0.999);
      let t = normalize(cross(up, h.n));
      let b = cross(h.n, t);
      let ndir = normalize(t*x + b*z + h.n*y);

      let cosOn = max(0.0, dot(h.n, ndir));
      throughput *= (h.mat.base / 3.14159265) * cosOn / 0.5;

      rayO = h.p + h.n * 1e-3;
      rayD = ndir;

      if (bounce >= 2u) {
        let p = clamp(max(throughput.x, max(throughput.y, throughput.z)), 0.2, 0.95);
        let rrr = rng_f32(&rng);
        if (rrr > p) { break; }
        throughput /= p;
      }
    }

    radiance = min(radiance, vec3(8.0)); 

    accumColor += radiance;
    if (stored) {
      accumAlbedo += firstAlbedo;
      accumNormal += firstNormal;
      accumDepth += firstDepth;
    }
  }

  let invSpp = 1.0 / f32(spp);
  let outColor = accumColor * invSpp;
  let outAlbedo = accumAlbedo * invSpp;
  let outNormal = accumNormal * invSpp;
  let outDepth = accumDepth * invSpp;

  textureStore(radianceTex, vec2<i32>(i32(gid.x), i32(gid.y)), vec4<f32>(outColor, 1.0));
  textureStore(gbufAlbedo, vec2<i32>(i32(gid.x), i32(gid.y)), vec4<f32>(outAlbedo, 1.0));
  textureStore(gbufNormalDepth, vec2<i32>(i32(gid.x), i32(gid.y)), vec4<f32>(outNormal * 0.5 + 0.5, outDepth));
}
