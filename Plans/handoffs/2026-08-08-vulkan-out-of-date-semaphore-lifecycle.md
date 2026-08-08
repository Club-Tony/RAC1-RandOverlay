# Handoff: exercise overlay semaphore lifecycle across swapchain out-of-date results

**Status:** Planned — non-blocking swapchain hardening
**Created:** 2026-08-08
**Type:** Handoff
**Parent plan:** [vulkan-overlay-works-no-matter-what.md](../vulkan-overlay-works-no-matter-what.md)

## Mission

RandOverlay returns `VK_ERROR_OUT_OF_DATE_KHR` unchanged and rebuilds overlay resources when
the application creates the replacement swapchain. Cleanup performs `vkDeviceWaitIdle`, so
the normal recreation path is safe. What is not covered deterministically is an application
that calls present again before recreating the swapchain, after an overlay submit signalled
its per-image semaphore.

Extend the mock host with a forced out-of-date/recreate sequence. Confirm the layer never
reuses a still-signalled binary semaphore, returns the application's present result, idles
before destruction, and renders again after recreation. Keep this separate from real-emulator
certification unless live logs expose an actual failure.
