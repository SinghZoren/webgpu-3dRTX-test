/// <reference types="@webgpu/types" />

declare global {
  interface Navigator {
    readonly gpu?: GPU;
  }
  
  interface HTMLCanvasElement {
    getContext(contextId: 'webgpu'): GPUCanvasContext | null;
  }
}

declare module '*.wgsl?raw' {
  const content: string;
  export default content;
}

export {};

