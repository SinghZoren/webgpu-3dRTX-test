import { initWebGPU, createTex } from './gpu';
import { makeCameraBasis } from './camera';
import { vec3 } from 'gl-matrix';
import { generateBlueNoiseTexture } from './blueNoise';
import { buildScene } from './scene';

const canvas = document.getElementById('c') as HTMLCanvasElement;
const { device, context, format } = await initWebGPU(canvas);

const WIDTH = 1920;
const HEIGHT = 1080;
canvas.width = WIDTH;
canvas.height = HEIGHT;

const blueNoise = generateBlueNoiseTexture(device);
const sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear', addressModeU: 'repeat', addressModeV: 'repeat' });

let colorRaw = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC, 'rgba16float');
let gbufAlbedo = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING, 'rgba16float');
let gbufNormalDepth = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING, 'rgba16float');
let historyColor = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_DST, 'rgba16float');
let momentsA = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_DST, 'rgba16float');
let momentsB = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_DST, 'rgba16float');
let temporalOut = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST, 'rgba16float');
let spatialOut  = createTex(device, WIDTH, HEIGHT, GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.COPY_DST, 'rgba16float');

const uniTracer = device.createBuffer({ size: 96, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
const uniTemporal = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
const uniSpatial = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });

const tracerURL = new URL('./tracer.wgsl', import.meta.url);
const temporalURL = new URL('./svgf_temporal.wgsl', import.meta.url);
const spatialURL = new URL('./svgf_spatial.wgsl', import.meta.url);
const presentURL = new URL('./present.wgsl', import.meta.url);

const tracerMod = device.createShaderModule({ code: await (await fetch(tracerURL)).text() });
const temporalMod = device.createShaderModule({ code: await (await fetch(temporalURL)).text() });
const spatialMod = device.createShaderModule({ code: await (await fetch(spatialURL)).text() });
const presentMod = device.createShaderModule({ code: await (await fetch(presentURL)).text() });

const tracerBind = device.createBindGroupLayout({
  entries: [
    { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
    { binding: 1, visibility: GPUShaderStage.COMPUTE, storageTexture: { access: 'write-only', format: 'rgba16float' } },
    { binding: 2, visibility: GPUShaderStage.COMPUTE, storageTexture: { access: 'write-only', format: 'rgba16float' } },
    { binding: 3, visibility: GPUShaderStage.COMPUTE, storageTexture: { access: 'write-only', format: 'rgba16float' } },
    { binding: 4, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } },
    { binding: 5, visibility: GPUShaderStage.COMPUTE, sampler: { type: 'filtering' } },
  ]
});
const tracerPipeline = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [tracerBind] }),
  compute: { module: tracerMod, entryPoint: 'main' },
});

const temporalBind = device.createBindGroupLayout({
  entries: [
    { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
    { binding: 1, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } }, // colorIn
    { binding: 2, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } }, // albedo (unused)
    { binding: 3, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } }, // normalDepth (unused)
    { binding: 4, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } }, // prevColor
    { binding: 5, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } }, // prevMoments
    { binding: 6, visibility: GPUShaderStage.COMPUTE, storageTexture: { access: 'write-only', format: 'rgba16float' } }, // out color
    { binding: 7, visibility: GPUShaderStage.COMPUTE, storageTexture: { access: 'write-only', format: 'rgba16float' } }, // out moments
  ]
});
const temporalPipeline = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [temporalBind] }),
  compute: { module: temporalMod, entryPoint: 'main' },
});

const spatialBind = device.createBindGroupLayout({
  entries: [
    { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: 'uniform' } },
    { binding: 1, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } },
    { binding: 2, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } },
    { binding: 3, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } },
    { binding: 4, visibility: GPUShaderStage.COMPUTE, texture: { sampleType: 'float' } },
    { binding: 5, visibility: GPUShaderStage.COMPUTE, storageTexture: { access: 'write-only', format: 'rgba16float' } },
  ]
});
const spatialPipeline = device.createComputePipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [spatialBind] }),
  compute: { module: spatialMod, entryPoint: 'main' },
});

const presentBind = device.createBindGroupLayout({
  entries: [
    { binding: 0, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: 'float' } },
    { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: { type: 'filtering' } },
  ]
});
const presentPipeline = device.createRenderPipeline({
  layout: device.createPipelineLayout({ bindGroupLayouts: [presentBind] }),
  vertex: { module: presentMod, entryPoint: 'vsMain' },
  fragment: {
    module: presentMod,
    entryPoint: 'fsMain',
    targets: [{ format }],
  },
  primitive: { topology: 'triangle-list' },
});

buildScene();
let frameIndex = 1;
const preset: 'performance' | 'ultra' = 'ultra';

const camPos = vec3.fromValues(0.0, 1.0, 1.9);
let yaw = -Math.PI / 2;  
let pitch = -0.1;        
const keys: Record<string, boolean> = {};
let pointerLocked = false;
let camMoved = false;
const lastCamPos = vec3.clone(camPos);
let lastYaw = yaw;
let lastPitch = pitch;

document.addEventListener('keydown', (e) => { keys[e.key.toLowerCase()] = true; });
document.addEventListener('keyup',   (e) => { keys[e.key.toLowerCase()] = false; });

canvas.addEventListener('click', () => {
  if (!pointerLocked) canvas.requestPointerLock();
});
document.addEventListener('pointerlockchange', () => {
  pointerLocked = document.pointerLockElement === canvas;
});
document.addEventListener('mousemove', (e) => {
  if (!pointerLocked) return;
  const sens = 0.002;
  yaw   -= e.movementX * sens;
  pitch -= e.movementY * sens;
  const limit = Math.PI/2 - 0.01;
  pitch = Math.max(-limit, Math.min(limit, pitch));
});

function updateCamera(dt: number) {
  const forward = vec3.fromValues(Math.cos(pitch)*Math.cos(yaw), Math.sin(pitch), Math.cos(pitch)*Math.sin(yaw));
  const right = vec3.fromValues(Math.sin(yaw), 0, -Math.cos(yaw));
  const up = vec3.fromValues(0,1,0);
  const speed = 2.0; 
  if (keys['w']) vec3.scaleAndAdd(camPos, camPos, forward, speed*dt);
  if (keys['s']) vec3.scaleAndAdd(camPos, camPos, forward, -speed*dt);
  if (keys['a']) vec3.scaleAndAdd(camPos, camPos, right, -speed*dt);
  if (keys['d']) vec3.scaleAndAdd(camPos, camPos, right, speed*dt);
  if (keys[' ']) vec3.scaleAndAdd(camPos, camPos, up, speed*dt);
  if (keys['shift']) vec3.scaleAndAdd(camPos, camPos, up, -speed*dt);
}

let lastTime = performance.now();

function updateUniforms() {
  const now = performance.now();
  const dt = Math.max(0.0, (now - lastTime) * 0.001);
  lastTime = now;

  updateCamera(dt);

  const aspect = WIDTH / HEIGHT;
  const lookDir = vec3.fromValues(Math.cos(pitch)*Math.cos(yaw), Math.sin(pitch), Math.cos(pitch)*Math.sin(yaw));
  const target = vec3.create();
  vec3.add(target, camPos, lookDir);
  const camBasis = makeCameraBasis(aspect, camPos as Float32Array, lookDir as Float32Array, 45);
  camMoved = false;
  if (vec3.distance(camPos, lastCamPos) > 1e-5 || Math.abs(yaw - lastYaw) > 1e-5 || Math.abs(pitch - lastPitch) > 1e-5) {
    camMoved = true;
    vec3.copy(lastCamPos, camPos);
    lastYaw = yaw;
    lastPitch = pitch;
  }

  const presetFlag = preset === 'ultra' ? 1 : 0;
  const buf = new ArrayBuffer(96);
  const dv = new DataView(buf);
  const f32 = new Float32Array(buf);

  f32[0] = WIDTH;
  f32[1] = HEIGHT;

  dv.setUint32(8, frameIndex, true);

  dv.setUint32(12, presetFlag, true);

  f32[4] = camBasis.camPos[0];
  f32[5] = camBasis.camPos[1];
  f32[6] = camBasis.camPos[2];
  f32[7] = 0;

  f32[8] = camBasis.camU[0];
  f32[9] = camBasis.camU[1];
  f32[10] = camBasis.camU[2];
  f32[11] = 0;

  f32[12] = camBasis.camV[0];
  f32[13] = camBasis.camV[1];
  f32[14] = camBasis.camV[2];
  f32[15] = 0;

  f32[16] = camBasis.camW[0];
  f32[17] = camBasis.camW[1];
  f32[18] = camBasis.camW[2];
  f32[19] = 0;

  dv.setUint32(80, 0, true);
  dv.setUint32(84, 0, true);
  dv.setUint32(88, 0, true);
  dv.setUint32(92, 0, true);
  device.queue.writeBuffer(uniTracer, 0, buf);
  const temporal = new Float32Array([WIDTH, HEIGHT, frameIndex, 0]);
  device.queue.writeBuffer(uniTemporal, 0, temporal.buffer);
  const spatial = new Float32Array([WIDTH, HEIGHT, 1, 0]);
  device.queue.writeBuffer(uniSpatial, 0, spatial.buffer);
}

function frame() {
  updateUniforms();
  const encoder = device.createCommandEncoder();

  {
    const bg = device.createBindGroup({
      layout: tracerBind,
      entries: [
        { binding: 0, resource: { buffer: uniTracer } },
        { binding: 1, resource: colorRaw.createView() },
        { binding: 2, resource: gbufAlbedo.createView() },
        { binding: 3, resource: gbufNormalDepth.createView() },
        { binding: 4, resource: blueNoise.createView() },
        { binding: 5, resource: sampler },
      ]
    });
    const pass = encoder.beginComputePass();
    pass.setPipeline(tracerPipeline);
    pass.setBindGroup(0, bg);
    pass.dispatchWorkgroups(Math.ceil(WIDTH/8), Math.ceil(HEIGHT/8));
    pass.end();
  }

  const seedHistory = camMoved || frameIndex === 1;


  if (seedHistory) {
    encoder.copyTextureToTexture(
      { texture: colorRaw },
      { texture: historyColor },
      { width: WIDTH, height: HEIGHT }
    );

    const zero = new Uint8Array(WIDTH * HEIGHT * 8);
    device.queue.writeTexture(
      { texture: momentsA },
      zero,
      { offset: 0, bytesPerRow: WIDTH * 8, rowsPerImage: HEIGHT },
      { width: WIDTH, height: HEIGHT, depthOrArrayLayers: 1 }
    );
    device.queue.writeTexture(
      { texture: momentsB },
      zero,
      { offset: 0, bytesPerRow: WIDTH * 8, rowsPerImage: HEIGHT },
      { width: WIDTH, height: HEIGHT, depthOrArrayLayers: 1 }
    );
    frameIndex = 1;
  }


  {
    const momentsRead = (frameIndex % 2 === 0) ? momentsA : momentsB;
    const momentsWrite = (frameIndex % 2 === 0) ? momentsB : momentsA;
    const bg = device.createBindGroup({
      layout: temporalBind,
      entries: [
        { binding: 0, resource: { buffer: uniTemporal } },
        { binding: 1, resource: colorRaw.createView() },
        { binding: 2, resource: gbufAlbedo.createView() },
        { binding: 3, resource: gbufNormalDepth.createView() },
        { binding: 4, resource: historyColor.createView() },
        { binding: 5, resource: momentsRead.createView() },
        { binding: 6, resource: temporalOut.createView() },
        { binding: 7, resource: momentsWrite.createView() },
      ]
    });
    const pass = encoder.beginComputePass();
    pass.setPipeline(temporalPipeline);
    pass.setBindGroup(0, bg);
    pass.dispatchWorkgroups(Math.ceil(WIDTH/8), Math.ceil(HEIGHT/8));
    pass.end();
  }


  {
    const momentsLatest = (frameIndex % 2 === 0) ? momentsB : momentsA;
    const writeSpatial = (step: number, inputTex: GPUTexture, outputTex: GPUTexture) => {
      const resF32 = new Float32Array([WIDTH, HEIGHT]);
      const stepU32 = new Uint32Array([step, 0]);
      device.queue.writeBuffer(uniSpatial, 0, resF32);
      device.queue.writeBuffer(uniSpatial, 8, stepU32);
      const bg = device.createBindGroup({
        layout: spatialBind,
        entries: [
          { binding: 0, resource: { buffer: uniSpatial } },
          { binding: 1, resource: inputTex.createView() },
          { binding: 2, resource: gbufAlbedo.createView() },
          { binding: 3, resource: gbufNormalDepth.createView() },
          { binding: 4, resource: momentsLatest.createView() },
          { binding: 5, resource: outputTex.createView() },
        ]
      });
      const pass = encoder.beginComputePass();
      pass.setPipeline(spatialPipeline);
      pass.setBindGroup(0, bg);
      pass.dispatchWorkgroups(Math.ceil(WIDTH/8), Math.ceil(HEIGHT/8));
      pass.end();
    };

    writeSpatial(1, temporalOut, spatialOut);
    writeSpatial(2, spatialOut, temporalOut);
    writeSpatial(4, temporalOut, spatialOut);
  }


  {
    const view = context.getCurrentTexture().createView();
    const bg = device.createBindGroup({
      layout: presentBind,
      entries: [
        { binding: 0, resource: spatialOut.createView() },
        { binding: 1, resource: sampler },
      ]
    });
    const pass = encoder.beginRenderPass({
      colorAttachments: [{ view, loadOp: 'clear', storeOp: 'store', clearValue: {r:0,g:0,b:0,a:1} }]
    });
    pass.setPipeline(presentPipeline);
    pass.setBindGroup(0, bg);
    pass.draw(3,1,0,0);
    pass.end();
  }

  device.queue.submit([encoder.finish()]);


  [historyColor, temporalOut] = [temporalOut, historyColor];
  frameIndex++;
  requestAnimationFrame(frame);
}

frame();

