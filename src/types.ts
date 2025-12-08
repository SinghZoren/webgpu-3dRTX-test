export type QualityPreset = 'performance' | 'ultra';

export type Uniforms = {
  resolution: Float32Array; 
  frameIndex: Uint32Array;  
  camPos: Float32Array;     
  camU:   Float32Array;
  camV:   Float32Array;
  camW:   Float32Array;
  counts: Uint32Array;      
  preset: Uint32Array;      
};
