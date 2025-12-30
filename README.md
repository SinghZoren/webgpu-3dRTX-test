# WebGPU Lava Lamp Path Tracer

A high-performance, real-time physically based path tracer built with WebGPU, featuring fluid-like metaball simulations, spatiotemporal denoising, and advanced Monte Carlo sampling.

## Technical Overview

This project implements a stochastic path tracing engine entirely within WebGPU compute shaders. It moves beyond traditional rasterization to achieve physically accurate lighting, reflections, and refractions.

### 1. Hybrid Path Tracing & Raymarching Engine
The core renderer (`tracer.wgsl`) utilizes a hybrid approach to scene intersection:
- **Analytic Ray-Scene Intersection**: Used for geometric primitives (walls, glass panels, light sources) to ensure infinite precision and high performance.
- **Signed Distance Function (SDF) Raymarching**: The lava blobs are simulated as implicit surfaces using metaballs.
    - **Smooth Blending**: Blobs are combined using a `smin` (exponential smooth minimum) function to create realistic fluid-like merging behaviors.
    - **Heat-Driven Dynamics**: Vertical movement and thermal expansion are procedurally calculated based on a heat-exchange model (rising when hot, sinking when cool).
    - **Adaptive Stepping**: The raymarcher uses distance-aided stepping with a safety multiplier (0.95) to prevent overshooting near grazing angles.

### 2. SVGF (Spatiotemporal Variance-Guided Filtering)
To achieve noise-free results at real-time frame rates with low samples per pixel (SPP), the engine implements a custom SVGF pipeline:
- **Temporal Accumulation**: Reprojects history buffers to accumulate samples over time, significantly reducing variance.
- **Variance Estimation**: Calculates per-pixel variance based on luminance history to adaptively control filter strength.
- **Edge-Avoiding À-Trous Wavelet Filter**: A multi-pass spatial filter that uses G-buffer data (normals and depth) as a bilateral guide to blur noise while preserving sharp geometric edges.

### 3. Physically Based Rendering (PBR)
The material system is based on the standard microfacet model:
- **Cook-Torrance Specular BRDF**: Uses the GGX/Trowbridge-Reitz distribution function for realistic highlights.
- **Fresnel Equations**: Implements the Schlick approximation for view-dependent reflectivity, critical for the glass-walled tank.
- **Refraction & Internal Reflection**: Handles light transmission through dielectric interfaces with correct Snell's law refraction and Total Internal Reflection (TIR).

### 4. Advanced Sampling & Noise Management
- **Blue Noise Integration**: Uses pre-computed blue noise textures to decorrelate error across pixels, transforming low-frequency clustering into high-frequency noise that is more easily filtered by the SVGF denoiser.
- **Low-Discrepancy Sequences**: Employs Hammersley and Halton sequences for sub-pixel jittering and light sampling, providing better convergence than pure pseudo-random numbers.
- **Next Event Estimation (NEE)**: Explicitly samples light sources at each bounce to reduce variance in the direct lighting calculation.

### 5. Performance Optimizations
- **AABB Acceleration**: The lava volume is enclosed in an Axis-Aligned Bounding Box (AABB) to early-exit raymarching for rays that do not intersect the simulation space.
- **Forward Difference Normals**: Normal vectors for the implicit metaball surfaces are calculated using a 3-tap forward difference method instead of the more expensive 6-tap central difference.
- **GPU Uniform Management**: Efficiently passes simulation parameters (temperature, viscosity, blob count) from the CPU via structured uniform buffers.

## Controls & Features
- **Dynamic Blob Count**: Real-time adjustment of simulated metaball count (up to 24 blobs).
- **Thermal Simulation**: Adjust "Tank Temperature" to control blob velocity and "Viscosity" to change their merging behavior.
- **Graphics Presets**: Scalable quality settings from "Low (Performance)" to "Ultra (Heavy)", adjusting SPP and max light bounces.
- **Color Customization**: Full control over blob emissive color and light intensity with correct sRGB-to-Linear color space conversion.

## Requirements
- A browser with **WebGPU** support (Chrome 113+, Edge 113+).
- A dedicated GPU is highly recommended for higher quality presets.
