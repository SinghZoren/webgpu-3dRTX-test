import { vec3 } from 'gl-matrix';

export const camPos = vec3.fromValues(0.0, 1.0, 1.9);
export const camTarget = vec3.fromValues(0.0, 0.6, -2.3);
export const camUp = vec3.fromValues(0, 1, 0);
export const fovY = 45 * Math.PI / 180;

export function buildBasis(aspect: number) {
  const w = vec3.normalize(vec3.create(), vec3.sub(vec3.create(), camTarget, camPos));
  const u = vec3.normalize(vec3.create(), vec3.cross(vec3.create(), w, camUp));
  const v = vec3.cross(vec3.create(), u, w);
  
  let halfH = Math.tan(fovY * 0.5);
  let halfW = halfH * aspect;

  if (aspect < 1.0) {
    halfW = Math.tan(fovY * 0.5);
    halfH = halfW / aspect;
  }

  vec3.scale(u, u, halfW);
  vec3.scale(v, v, halfH);
  return { camPos, camU: u, camV: v, camW: w };
}

export function lookAt(pos: Float32Array, target: Float32Array, up: Float32Array) {
  const w = vec3.normalize(vec3.create(), vec3.sub(vec3.create(), target, pos));
  const u = vec3.normalize(vec3.create(), vec3.cross(vec3.create(), w, up));
  const v = vec3.cross(vec3.create(), u, w);
  return { u, v, w, pos };
}

export function makeCameraBasis(
  aspect: number,
  pos: Float32Array,
  dir: Float32Array,
  fovDeg = 45
) {
  const up = vec3.fromValues(0, 1, 0) as Float32Array;
  const target = vec3.add(vec3.create(), pos, dir) as Float32Array;
  const { u, v, w, pos: p } = lookAt(pos, target, up);
  const fov = (fovDeg * Math.PI) / 180;
  
  let halfH = Math.tan(fov * 0.5);
  let halfW = halfH * aspect;


  if (aspect < 1.0) {
    halfW = Math.tan(fov * 0.5);
    halfH = halfW / aspect;
  }

  vec3.scale(u, u, halfW);
  vec3.scale(v, v, halfH);
  return { camPos: p, camU: u, camV: v, camW: w };
}

