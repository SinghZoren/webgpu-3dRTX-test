/// <reference types="@webgpu/types" />

declare global {
  interface Navigator {
    readonly gpu?: GPU;
  }
  
  interface HTMLCanvasElement {
    getContext(contextId: 'webgpu'): GPUCanvasContext | null;
  }
}

export {};

