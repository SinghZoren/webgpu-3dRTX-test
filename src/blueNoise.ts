
export function generateBlueNoiseTexture(device: GPUDevice, size = 128) {
  const data = new Uint8Array(size * size * 4);
  for (let i = 0; i < data.length; ++i) data[i] = Math.floor(Math.random() * 256);
  const tex = device.createTexture({
    size: { width: size, height: size },
    format: 'rgba8unorm',
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
  });
  device.queue.writeTexture(
    { texture: tex },
    data,
    { offset: 0, bytesPerRow: size * 4, rowsPerImage: size },
    { width: size, height: size }
  );
  return tex;
}








