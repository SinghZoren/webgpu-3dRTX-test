fn splitmix32(mut x: u32) -> u32 {
  x = x + 0x9E3779B9u;
  var z = x;
  z = (z ^ (z >> 16u)) * 0x85EBCA6Bu;
  z = (z ^ (z >> 13u)) * 0xC2B2AE35u;
  z = z ^ (z >> 16u);
  return z;
}

fn make_seed(px: u32, py: u32, frame: u32, sample: u32) -> u32 {
  var s = px * 0x1f123bb5u ^ py * 0x5f7a0e1du ^ frame * 0x9e3779b9u ^ sample * 0x68bc21ebu;
  return splitmix32(s);
}

struct PCG { state: u32; }

fn pcg_step(state: u32) -> u32 {
  let mul: u32 = 747796405u;
  let inc: u32 = 2891336453u;
  var x = state * mul + inc;
  let rot = ((x >> 28u) + 4u) & 31u;
  var word = ((x >> rot) ^ x) * 277803737u;
  return word;
}

fn pcg_init(px: u32, py: u32, frame: u32, sample: u32) -> PCG {
  return PCG(state: make_seed(px, py, frame, sample));
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

fn halton(mut i: u32, base: u32) -> f32 {
  var f = 1.0;
  var r = 0.0;
  var b = base;
  var inv = 1.0 / f32(b);
  loop {
    if (i == 0u) { break; }
    f = f * inv;
    r = r + f * f32(i % b);
    i = i / b;
  }
  return r;
}

fn pixel_jitter(frame: u32) -> vec2<f32> {
  let jx = halton(frame + 1u, 2u);
  let jy = halton(frame + 1u, 3u);
  return vec2<f32>(jx, jy) - vec2<f32>(0.5, 0.5);
}








