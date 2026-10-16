#pragma once
/*
 * Vulkan layer dispatch table management.
 * Stores per-instance and per-device dispatch tables so our layer can
 * call the next layer's functions in the chain.
 */
#include <unordered_map>
#include <mutex>

namespace rodispatch {

// Lookup-only access to a dispatch map: copies the table out under the lock
// and reports a miss instead of inserting. operator[] would value-initialise
// an all-null table for a handle the layer never recorded, and a reference
// into the map dangles as soon as another thread inserts (rehash) or erases.
// Free of Vulkan types so the headless unit tests can exercise it.
template <typename Table>
inline bool tryGet(std::mutex& mutex, const std::unordered_map<void*, Table>& map,
                   void* key, Table& out) {
    std::lock_guard<std::mutex> lock(mutex);
    auto it = map.find(key);
    if (it == map.end()) return false;
    out = it->second;
    return true;
}

} // namespace rodispatch

// The unit tests define this to take only the lookup above.
#ifndef RANDOVERLAY_DISPATCH_LOOKUP_ONLY
#include <vulkan/vulkan.h>

// Instance-level dispatch table (functions resolved via vkGetInstanceProcAddr)
struct InstanceDispatch {
    PFN_vkGetInstanceProcAddr GetInstanceProcAddr;
    PFN_vkDestroyInstance DestroyInstance;
    PFN_vkEnumerateDeviceExtensionProperties EnumerateDeviceExtensionProperties;
    PFN_vkCreateDevice CreateDevice;
};

// Device-level dispatch table (functions resolved via vkGetDeviceProcAddr)
struct DeviceDispatch {
    PFN_vkGetDeviceProcAddr GetDeviceProcAddr;
    PFN_vkDestroyDevice DestroyDevice;
    PFN_vkGetDeviceQueue GetDeviceQueue;
    PFN_vkQueuePresentKHR QueuePresentKHR;
    PFN_vkCreateSwapchainKHR CreateSwapchainKHR;
    PFN_vkDestroySwapchainKHR DestroySwapchainKHR;
    PFN_vkGetSwapchainImagesKHR GetSwapchainImagesKHR;
    PFN_vkCreateImageView CreateImageView;
    PFN_vkDestroyImageView DestroyImageView;
    PFN_vkCreateRenderPass CreateRenderPass;
    PFN_vkDestroyRenderPass DestroyRenderPass;
    PFN_vkCreateFramebuffer CreateFramebuffer;
    PFN_vkDestroyFramebuffer DestroyFramebuffer;
    PFN_vkCreateCommandPool CreateCommandPool;
    PFN_vkDestroyCommandPool DestroyCommandPool;
    PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
    PFN_vkFreeCommandBuffers FreeCommandBuffers;
    PFN_vkBeginCommandBuffer BeginCommandBuffer;
    PFN_vkEndCommandBuffer EndCommandBuffer;
    PFN_vkCmdBeginRenderPass CmdBeginRenderPass;
    PFN_vkCmdEndRenderPass CmdEndRenderPass;
    PFN_vkQueueSubmit QueueSubmit;
    PFN_vkDeviceWaitIdle DeviceWaitIdle;
    PFN_vkCreateSemaphore CreateSemaphore_;  // Avoid Windows macro conflict
    PFN_vkDestroySemaphore DestroySemaphore;
    PFN_vkResetCommandBuffer ResetCommandBuffer;
    PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
    PFN_vkCmdClearAttachments CmdClearAttachments;
};

// Global dispatch table maps (keyed by dispatch key)
// The dispatch key is the first sizeof(void*) bytes of VkInstance/VkDevice/VkQueue
inline void* GetDispatchKey(void* handle) {
    return *(void**)handle;
}

static std::mutex g_dispatchMutex;
static std::unordered_map<void*, InstanceDispatch> g_instanceDispatch;
static std::unordered_map<void*, DeviceDispatch> g_deviceDispatch;

// Helper to load instance dispatch table
static void InitInstanceDispatch(VkInstance instance, PFN_vkGetInstanceProcAddr gipa) {
    InstanceDispatch d = {};
    d.GetInstanceProcAddr = gipa;
    #define LOAD_I(name) d.name = (PFN_vk##name)gipa(instance, "vk" #name)
    LOAD_I(DestroyInstance);
    LOAD_I(EnumerateDeviceExtensionProperties);
    LOAD_I(CreateDevice);
    #undef LOAD_I

    std::lock_guard<std::mutex> lock(g_dispatchMutex);
    g_instanceDispatch[GetDispatchKey(instance)] = d;
}

// Helper to load device dispatch table. Returns the table it recorded so the
// caller never has to look it straight back up.
static DeviceDispatch InitDeviceDispatch(VkDevice device, PFN_vkGetDeviceProcAddr gdpa) {
    DeviceDispatch d = {};
    d.GetDeviceProcAddr = gdpa;
    #define LOAD_D(name) d.name = (PFN_vk##name)gdpa(device, "vk" #name)
    LOAD_D(DestroyDevice);
    LOAD_D(GetDeviceQueue);
    LOAD_D(QueuePresentKHR);
    LOAD_D(CreateSwapchainKHR);
    LOAD_D(DestroySwapchainKHR);
    LOAD_D(GetSwapchainImagesKHR);
    LOAD_D(CreateImageView);
    LOAD_D(DestroyImageView);
    LOAD_D(CreateRenderPass);
    LOAD_D(DestroyRenderPass);
    LOAD_D(CreateFramebuffer);
    LOAD_D(DestroyFramebuffer);
    LOAD_D(CreateCommandPool);
    LOAD_D(DestroyCommandPool);
    LOAD_D(AllocateCommandBuffers);
    LOAD_D(FreeCommandBuffers);
    LOAD_D(BeginCommandBuffer);
    LOAD_D(EndCommandBuffer);
    LOAD_D(CmdBeginRenderPass);
    LOAD_D(CmdEndRenderPass);
    LOAD_D(QueueSubmit);
    LOAD_D(DeviceWaitIdle);
    LOAD_D(ResetCommandBuffer);
    LOAD_D(CmdPipelineBarrier);
    LOAD_D(CmdClearAttachments);
    #undef LOAD_D
    // CreateSemaphore conflicts with Windows macro
    d.CreateSemaphore_ = (PFN_vkCreateSemaphore)gdpa(device, "vkCreateSemaphore");
    d.DestroySemaphore = (PFN_vkDestroySemaphore)gdpa(device, "vkDestroySemaphore");

    std::lock_guard<std::mutex> lock(g_dispatchMutex);
    g_deviceDispatch[GetDispatchKey(device)] = d;
    return d;
}

// Init*Dispatch above are the only writers that may insert. Everything else
// goes through these, which return false for a handle with no recorded table
// (never seen, or already destroyed) and otherwise fill `out` with a copy.
static bool TryGetInstanceDispatch(void* handle, InstanceDispatch& out) {
    if (!handle) return false;
    return rodispatch::tryGet(g_dispatchMutex, g_instanceDispatch, GetDispatchKey(handle), out);
}

static bool TryGetDeviceDispatch(void* handle, DeviceDispatch& out) {
    if (!handle) return false;
    return rodispatch::tryGet(g_dispatchMutex, g_deviceDispatch, GetDispatchKey(handle), out);
}

#endif // RANDOVERLAY_DISPATCH_LOOKUP_ONLY
