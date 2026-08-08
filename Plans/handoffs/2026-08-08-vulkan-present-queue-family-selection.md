# Handoff: track the Vulkan presentation queue family explicitly

**Status:** Planned — non-blocking portability hardening
**Created:** 2026-08-08
**Type:** Handoff
**Parent plan:** [vulkan-overlay-works-no-matter-what.md](../vulkan-overlay-works-no-matter-what.md)

## Mission

RandOverlay currently builds its command pool from the first queue family in
`VkDeviceCreateInfo`. The tested NVIDIA/RPCS3/PCSX2 path presents on family 0, and Khronos
validation is clean, but Vulkan permits presentation on another requested family.

Intercept `vkGetDeviceQueue` and `vkGetDeviceQueue2`, map returned queues to their family,
and ensure overlay command resources are created for the family of the queue passed to
`vkQueuePresentKHR`. Add a mock-host case with distinct graphics/present families when a
test adapter exposes them; otherwise add a unit seam for the mapping and rebuild decision.

This is not a prerequisite for the current live emulator certification.
