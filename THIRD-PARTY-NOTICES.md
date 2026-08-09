# Third-Party Notices

RandOverlay's Vulkan layer uses Dear ImGui, including its Vulkan renderer backend.

- Dear ImGui: <https://github.com/ocornut/imgui>
- License: MIT
- Release build revision: `8314fc3e5a10f7c6b670225065fce1dc8cfd396b`

The source build also produces an experimental injected-DLL fallback using MinHook. That
fallback is not included in the Vulkan installer payload.

- MinHook: <https://github.com/TsudaKageyu/minhook>
- License: BSD 2-Clause
- Release build revision: `1e9ad1eb42db11bfcb65461f687c656612d1b555`

The release workflow uses the Vulkan SDK for headers and import libraries and MinGW-w64/GCC
as the compiler toolchain. Their licenses and runtime exceptions remain with their upstream
projects. No Vulkan SDK installer, compiler, or source checkout is redistributed in the
RandOverlay release package.
