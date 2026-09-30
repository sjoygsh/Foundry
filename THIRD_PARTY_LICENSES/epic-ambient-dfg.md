# Epic Games Analytic Environment BRDF Fit

- **Version:** Physically Based Shading on Mobile, 2014-09-10
- **Upstream:** https://www.unrealengine.com/blog/physically-based-shading-on-mobile?lang=en-US
- **License:** LicenseRef-Epic-Blog-Code-Samples
- **Distribution:** distributed
- **Location in tree:** engine/src/render3d/lighting.zig and engine/src/render3d/shaders/lit.*
- **Why we depend on it:** light.md §7.3 requires a split-sum approximation for constant ambient radiance.
- **Modifications:** The published analytic DFG fit is adapted to Zig, MSL and GLSL,
  with glTF's dielectric diffuse and mixed metallic Fresnel. No Unreal Engine source is used.

## License text

Epic Games, Inc. gives you permission to use, copy, modify, and distribute the code samples in this article as you see fit with no attribution required.
