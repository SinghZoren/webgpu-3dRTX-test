export type Plane = { n: [number, number, number]; d: number; mat: number };
export type Sphere = { c: [number, number, number]; r: number; mat: number };
export type YCyl = { c: [number, number, number]; r: number; h: number; mat: number };
export type RectLight = { c: [number, number, number]; ux: [number, number, number]; uy: [number, number, number]; ex: [number, number, number] };
export type Material = { base: [number, number, number]; rough: number; metal: number; emit: [number, number, number] };

export function buildScene() {
  const materials: Material[] = [
    { base: [0.02, 0.02, 0.02], rough: 0.6, metal: 0.0, emit: [0, 0, 0] },  
    { base: [0.08, 0.08, 0.08], rough: 0.25, metal: 0.0, emit: [0, 0, 0] },  
    { base: [0.1, 0.1, 0.1], rough: 0.3, metal: 1.0, emit: [0, 0, 0] },      
    { base: [0, 0, 0], rough: 0.0, metal: 0.0, emit: [25, 25, 25] },        
  ];

  const planes: Plane[] = [
    { n: [0, 1, 0], d: 0.0, mat: 0 },            
    { n: [0, 0, 1], d: 3.0, mat: 0 },          
  ];

  const spheres: Sphere[] = [
    { c: [-0.45, 1.05, -2.2], r: 0.12, mat: 1 },  
    { c: [-0.45, 0.12, -2.2], r: 0.03, mat: 3 }, 
  ];

  const ycyl: YCyl[] = [
    { c: [-0.45, 0.5, -2.2], r: 0.12, h: 1.0, mat: 1 },  
    { c: [-0.45, 0.06, -2.2], r: 0.14, h: 0.12, mat: 2 }, 
  ];

  const rectLights: RectLight[] = [
    {
      c: [0.0, 2.4, -1.6],
      ux: [0.8, 0, 0],    
      uy: [0, 0, -0.3],   
      ex: [3.0, 3.0, 3.0],
    },
  ];

  return { materials, planes, spheres, ycyl, rectLights };
}








