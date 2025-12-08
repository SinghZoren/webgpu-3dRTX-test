export async function initWebGPU(canvas: HTMLCanvasElement) {
  console.log('[WebGPU] Checking WebGPU support...');
  
  if (!navigator.gpu) {
    console.error('[WebGPU] WebGPU not supported in this browser');
    throw new Error('WebGPU not supported');
  }
  console.log('[WebGPU] WebGPU API available');
  
  console.log('[WebGPU] Requesting adapter...');
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) {
    console.error('[WebGPU] No adapter available');
    throw new Error('No adapter');
  }
  

  if (adapter.info) {
    console.log('[WebGPU] Adapter:', {
      vendor: adapter.info.vendor,
      architecture: adapter.info.architecture,
      device: adapter.info.device,
      description: adapter.info.description
    });
  } else {
    console.log('[WebGPU] Adapter obtained (info not available)');
  }
  

  const features = Array.from(adapter.features);
  console.log('[WebGPU] Adapter features:', features.length > 0 ? features : 'none');
  

  console.log('[WebGPU] Adapter limits:', {
    maxTextureDimension2D: adapter.limits.maxTextureDimension2D,
    maxComputeWorkgroupStorageSize: adapter.limits.maxComputeWorkgroupStorageSize,
    maxComputeInvocationsPerWorkgroup: adapter.limits.maxComputeInvocationsPerWorkgroup,
    maxComputeWorkgroupSizeX: adapter.limits.maxComputeWorkgroupSizeX,
    maxComputeWorkgroupSizeY: adapter.limits.maxComputeWorkgroupSizeY,
  });
  
  console.log('[WebGPU] Requesting device...');
  const device = await adapter.requestDevice({
    requiredLimits: {
      maxStorageTexturesPerShaderStage: 8,
    }
  });
  console.log('[WebGPU] Device created successfully');
  

  const deviceFeatures = Array.from(device.features);
  console.log('[WebGPU] Device features:', deviceFeatures.length > 0 ? deviceFeatures : 'none');
  
  const context = canvas.getContext('webgpu') as GPUCanvasContext;
  if (!context) {
    console.error('[WebGPU] Failed to get WebGPU context from canvas');
    throw new Error('Failed to get WebGPU context');
  }
  
  const format = navigator.gpu.getPreferredCanvasFormat();
  console.log('[WebGPU] Preferred canvas format:', format);
  
  context.configure({ device, format, alphaMode: 'opaque' });
  console.log('[WebGPU] Canvas configured successfully');
  console.log('[WebGPU] Initialization complete');
  
  return { device, context, format };
}

export function createTex(device: GPUDevice, w: number, h: number, usage: GPUTextureUsageFlags, fmt: GPUTextureFormat = 'rgba16float') {
  return device.createTexture({ size: { width: w, height: h }, format: fmt, usage });
}

