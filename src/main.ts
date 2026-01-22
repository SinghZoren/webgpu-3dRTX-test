import { vec3 } from 'gl-matrix';
import { initWebGPU, createTex } from './gpu';
import { makeCameraBasis } from './camera';

import tracerSource from './tracer.wgsl?raw';
import presentSource from './present.wgsl?raw';
import temporalSource from './svgf_temporal.wgsl?raw';
import spatialSource from './svgf_spatial.wgsl?raw';

class CommandSystem {
  commands: Map<string, (args: string[]) => string> = new Map();

  register(name: string, callback: (args: string[]) => string) {
    this.commands.set(name, callback);
  }

  execute(input: string): { output: string; success: boolean } {
    const parts = input.trim().split(/\s+/);
    const cmd = parts[0].toLowerCase();
    const args = parts.slice(1);

    const callback = this.commands.get(cmd);
    if (callback) {
      try {
        return { output: callback(args), success: true };
      } catch (e: any) {
        return { output: `Error: ${e.message}`, success: false };
      }
    }
    return { output: `Unknown command: ${cmd}`, success: false };
  }

  getSuggestions(input: string): string[] {
    const cmd = input.split(/\s+/)[0].toLowerCase();
    return Array.from(this.commands.keys()).filter(c => c.startsWith(cmd));
  }
}

class ConsoleManager {
  element: HTMLElement;
  output: HTMLElement;
  input: HTMLInputElement;
  active: boolean = false;
  debugSequence: string = "";
  onCommand: (input: string) => void;

  constructor(onCommand: (input: string) => void) {
    this.element = document.getElementById('dev-console')!;
    this.output = document.getElementById('console-output')!;
    this.input = document.getElementById('console-input')! as HTMLInputElement;
    this.onCommand = onCommand;

    window.addEventListener('keydown', (e) => {
      if (!this.active) {
        this.debugSequence += e.key.toLowerCase();
        if (this.debugSequence.endsWith("debug")) {
          this.toggle();
          this.debugSequence = "";
        }
        return;
      }

      if (e.key === 'Enter') {
        const val = this.input.value;
        if (val) {
          this.log(`> ${val}`);
          this.onCommand(val);
          this.input.value = "";
        }
      } else if (e.key === 'Escape') {
        this.toggle();
      }
    });
  }

  toggle() {
    this.active = !this.active;
    this.element.classList.toggle('active', this.active);
    if (this.active) {
      setTimeout(() => this.input.focus(), 100);
    }
  }

  log(msg: string, type: 'info' | 'error' = 'info') {
    const line = document.createElement('div');
    line.className = `console-line console-${type}`;
    line.innerText = msg;
    this.output.appendChild(line);
    this.output.scrollTop = this.output.scrollHeight;
  }
}

async function main() {
  const canvas = document.getElementById('c') as HTMLCanvasElement;
  const fpsElem = document.getElementById('fps');
  const samplesElem = document.getElementById('samples');
  const startBtn = document.getElementById('start-btn') as HTMLButtonElement;
  const overlay = document.getElementById('warning-overlay');


  let timeLeft = 10;
  const timer = setInterval(() => {
    timeLeft--;
    if (timeLeft > 0) {
      startBtn.innerText = `Wait (${timeLeft}s)`;
    } else {
      clearInterval(timer);
      startBtn.innerText = "I Have a Dedicated GPU - Continue";
      startBtn.disabled = false;
    }
  }, 1000);


  await new Promise<void>((resolve) => {
    startBtn.onclick = () => {
      overlay?.remove();
      resolve();
    };
  });

  const { device, context, format } = await initWebGPU(canvas);


  const tracerShader = device.createShaderModule({ code: tracerSource });
  const presentShader = device.createShaderModule({ code: presentSource });
  const temporalShader = device.createShaderModule({ code: temporalSource });
  const spatialShader = device.createShaderModule({ code: spatialSource });


  const tracerUniformBuffer = device.createBuffer({
    size: 256,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  const temporalUniformBuffer = device.createBuffer({
    size: 64,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  const spatialUniformBuffer = device.createBuffer({
    size: 64,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const linearSampler = device.createSampler({
    magFilter: 'linear',
    minFilter: 'linear',
  });


  const tracerPipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: tracerShader, entryPoint: 'main' },
  });

  const temporalPipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: temporalShader, entryPoint: 'main' },
  });

  const spatialPipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module: spatialShader, entryPoint: 'main' },
  });

  const presentPipeline = device.createRenderPipeline({
    layout: 'auto',
    vertex: { module: presentShader, entryPoint: 'vsMain' },
    fragment: {
      module: presentShader,
      entryPoint: 'fsMain',
      targets: [{ format }],
    },
    primitive: { topology: 'triangle-list' },
  });


  let frameIndex = 1;
  let camPos = vec3.fromValues(0, 1.0, 1.5);
  let camDir = vec3.fromValues(0, 0, -1);


  let width = 0, height = 0;
  let radianceTex: GPUTexture, albedoTex: GPUTexture, normalDepthTex: GPUTexture;
  let prevColorTex: GPUTexture, prevMomentsTex: GPUTexture;
  let nextColorTex: GPUTexture, nextMomentsTex: GPUTexture;
  let spatialTex: GPUTexture;

  // Debug/SVGF Textures
  let motionTex: GPUTexture;
  let idDepthTex: GPUTexture, prevIdDepthTex: GPUTexture;
  let historyTex: GPUTexture, nextHistoryTex: GPUTexture;

  let debugSettings = {
    temporal: true,
    spatial: true,
    viewMode: 0, // 0:Final, 1:Raw, 2:Motion, 3:History, 4:Mask
  };

  const commands = new CommandSystem();
  const console = new ConsoleManager((input) => {
    const res = commands.execute(input);
    console.log(res.output, res.success ? 'info' : 'error');
  });

  commands.register('help', () => "Commands: temporal <true/false>, spatial <true/false>, view <default/raw/motion/history/mask>, reset, close, exit");
  commands.register('temporal', (args) => {
    debugSettings.temporal = args[0] === 'true';
    return `Temporal accumulation ${debugSettings.temporal ? 'enabled' : 'disabled'}`;
  });
  commands.register('spatial', (args) => {
    debugSettings.spatial = args[0] === 'true';
    return `Spatial filter ${debugSettings.spatial ? 'enabled' : 'disabled'}`;
  });
  commands.register('view', (args) => {
    const modes: Record<string, number> = { default: 0, raw: 1, motion: 2, history: 3, mask: 4 };
    if (modes[args[0]] !== undefined) {
      debugSettings.viewMode = modes[args[0]];
      return `View mode set to ${args[0]}`;
    }
    return `Invalid mode. Use: ${Object.keys(modes).join(', ')}`;
  });
  commands.register('reset', () => { frameIndex = 1; return "Frame counter reset."; });
  commands.register('close', () => { console.toggle(); return "Closing..."; });
  commands.register('exit', () => { console.toggle(); return "Closing..."; });

  let bindGroups: any = {};

  function onResize() {
    width = canvas.clientWidth;
    height = canvas.clientHeight;
    canvas.width = width;
    canvas.height = height;

    radianceTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING);
    albedoTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING);
    normalDepthTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING);

    prevColorTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST);
    prevMomentsTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST);
    nextColorTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC);
    nextMomentsTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC);
    spatialTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING);

    motionTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING, 'rgba16float');
    idDepthTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC, 'rg32float');
    prevIdDepthTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST, 'rg32float');
    historyTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST, 'r32float');
    nextHistoryTex = createTex(device, width, height, GPUTextureUsage.STORAGE_BINDING | GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC, 'r32float');

    bindGroups.tracer = device.createBindGroup({
      layout: tracerPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: tracerUniformBuffer } },
        { binding: 1, resource: radianceTex.createView() },
        { binding: 2, resource: albedoTex.createView() },
        { binding: 3, resource: normalDepthTex.createView() },
        { binding: 4, resource: motionTex.createView() },
        { binding: 5, resource: idDepthTex.createView() },
      ],
    });

    bindGroups.temporal = device.createBindGroup({
      layout: temporalPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: temporalUniformBuffer } },
        { binding: 1, resource: radianceTex.createView() },
        { binding: 4, resource: prevColorTex.createView() },
        { binding: 5, resource: prevMomentsTex.createView() },
        { binding: 6, resource: nextColorTex.createView() },
        { binding: 7, resource: nextMomentsTex.createView() },
        { binding: 8, resource: motionTex.createView() },
        { binding: 9, resource: prevIdDepthTex.createView() },
        { binding: 11, resource: nextHistoryTex.createView() },
        { binding: 12, resource: idDepthTex.createView() },
      ],
    });

    bindGroups.spatial = device.createBindGroup({
      layout: spatialPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: { buffer: spatialUniformBuffer } },
        { binding: 1, resource: nextColorTex.createView() },
        { binding: 3, resource: normalDepthTex.createView() },
        { binding: 4, resource: nextMomentsTex.createView() },
        { binding: 5, resource: spatialTex.createView() },
      ],
    });

    bindGroups.present = device.createBindGroup({
      layout: presentPipeline.getBindGroupLayout(0),
      entries: [
        { binding: 0, resource: spatialTex.createView() },
        { binding: 1, resource: linearSampler },
        { binding: 2, resource: { buffer: temporalUniformBuffer } }, // Reuse for debug flags
        { binding: 3, resource: radianceTex.createView() },
        { binding: 4, resource: motionTex.createView() },
        { binding: 5, resource: nextHistoryTex.createView() },
      ],
    });

    frameIndex = 1;
  }

  window.addEventListener('resize', onResize);
  onResize();

  let lastTime = performance.now();
  let frameCount = 0;


  const tempInput = document.getElementById('temp') as HTMLInputElement;
  const viscInput = document.getElementById('visc') as HTMLInputElement;
  const countInput = document.getElementById('blob-count') as HTMLInputElement;
  const colorInput = document.getElementById('blob-color') as HTMLInputElement;
  const intensityInput = document.getElementById('intensity') as HTMLInputElement;
  const presetSelect = document.getElementById('preset') as HTMLSelectElement;

  function hexToLinear(hex: string) {
    const r = Math.pow(parseInt(hex.slice(1, 3), 16) / 255, 2.2);
    const g = Math.pow(parseInt(hex.slice(3, 5), 16) / 255, 2.2);
    const b = Math.pow(parseInt(hex.slice(5, 7), 16) / 255, 2.2);
    return [r, g, b];
  }

  function updateUniforms() {
    const aspect = width / height;
    const basis = makeCameraBasis(aspect, camPos as Float32Array, camDir as Float32Array);

    const tData = new ArrayBuffer(256);
    const tf32 = new Float32Array(tData);
    const tu32 = new Uint32Array(tData);

    tf32[0] = width; tf32[1] = height; tu32[2] = frameIndex; tu32[3] = parseInt(presetSelect.value);


    tf32[4] = basis.camPos[0]; tf32[5] = basis.camPos[1]; tf32[6] = basis.camPos[2]; tf32[7] = 0;


    tf32[8] = basis.camU[0]; tf32[9] = basis.camU[1]; tf32[10] = basis.camU[2]; tf32[11] = 0;


    tf32[12] = basis.camV[0]; tf32[13] = basis.camV[1]; tf32[14] = basis.camV[2]; tf32[15] = 0;


    tf32[16] = basis.camW[0]; tf32[17] = basis.camW[1]; tf32[18] = basis.camW[2]; tf32[19] = 0;


    const rgb = hexToLinear(colorInput.value);
    tf32[20] = rgb[0]; tf32[21] = rgb[1]; tf32[22] = rgb[2]; tf32[23] = parseFloat(intensityInput.value);

    tf32[24] = parseFloat(tempInput.value);
    tf32[25] = parseFloat(viscInput.value);
    tf32[26] = 0.15;
    tf32[27] = parseFloat(countInput.value);

    device.queue.writeBuffer(tracerUniformBuffer, 0, tData);

    const tempData = new ArrayBuffer(64);
    const tempf32 = new Float32Array(tempData);
    const tempu32 = new Uint32Array(tempData);
    tempf32[0] = width; tempf32[1] = height; tempu32[2] = frameIndex;
    tempu32[3] = debugSettings.temporal ? 1 : 0;
    tempu32[4] = debugSettings.viewMode;
    device.queue.writeBuffer(temporalUniformBuffer, 0, tempData);

    const spatData = new ArrayBuffer(64);
    const spatf32 = new Float32Array(spatData);
    const spatu32 = new Uint32Array(spatData);
    spatf32[0] = width; spatf32[1] = height; spatu32[2] = 1; // Default stepWidth
    spatu32[3] = debugSettings.spatial ? 1 : 0;
    device.queue.writeBuffer(spatialUniformBuffer, 0, spatData);
  }

  const resetFrame = () => { frameIndex = 1; };
  [tempInput, viscInput, countInput, colorInput, intensityInput, presetSelect].forEach(el => {
    el.addEventListener('input', resetFrame);
  });

  function frame() {
    const now = performance.now();
    const dt = now - lastTime;
    frameCount++;
    if (dt > 1000) {
      if (fpsElem) fpsElem.innerText = frameCount.toString();
      frameCount = 0;
      lastTime = now;
    }

    updateUniforms();

    const commandEncoder = device.createCommandEncoder();

    const tracerPass = commandEncoder.beginComputePass();
    tracerPass.setPipeline(tracerPipeline);
    tracerPass.setBindGroup(0, bindGroups.tracer);
    tracerPass.dispatchWorkgroups(Math.ceil(width / 8), Math.ceil(height / 8));
    tracerPass.end();

    const temporalPass = commandEncoder.beginComputePass();
    temporalPass.setPipeline(temporalPipeline);
    temporalPass.setBindGroup(0, bindGroups.temporal);
    temporalPass.dispatchWorkgroups(Math.ceil(width / 8), Math.ceil(height / 8));
    temporalPass.end();

    const spatialPass = commandEncoder.beginComputePass();
    spatialPass.setPipeline(spatialPipeline);
    spatialPass.setBindGroup(0, bindGroups.spatial);
    spatialPass.dispatchWorkgroups(Math.ceil(width / 8), Math.ceil(height / 8));
    spatialPass.end();

    commandEncoder.copyTextureToTexture({ texture: nextColorTex }, { texture: prevColorTex }, [width, height, 1]);
    commandEncoder.copyTextureToTexture({ texture: nextMomentsTex }, { texture: prevMomentsTex }, [width, height, 1]);
    commandEncoder.copyTextureToTexture({ texture: nextHistoryTex }, { texture: historyTex }, [width, height, 1]);
    commandEncoder.copyTextureToTexture({ texture: idDepthTex }, { texture: prevIdDepthTex }, [width, height, 1]);

    const presentPass = commandEncoder.beginRenderPass({
      colorAttachments: [{
        view: context.getCurrentTexture().createView(),
        clearValue: { r: 0, g: 0, b: 0, a: 1 },
        loadOp: 'clear',
        storeOp: 'store',
      }],
    });
    presentPass.setPipeline(presentPipeline);
    presentPass.setBindGroup(0, bindGroups.present);
    presentPass.draw(3);
    presentPass.end();

    device.queue.submit([commandEncoder.finish()]);

    if (samplesElem) samplesElem.innerText = frameIndex.toString();
    frameIndex++;
    requestAnimationFrame(frame);
  }

  requestAnimationFrame(frame);
}

main();
