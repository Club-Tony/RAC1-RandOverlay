#pragma once
/*
 * Vulkan layer dispatch table management.
 * Stores per-instance and per-device dispatch tables so our layer can
 * call the next layer's functions in the chain.
 */
#include <vulkan/vulkan.h>
#include <unordered_map>
#include <mutex>

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

// Helper to load device dispatch table
static void InitDeviceDispatch(VkDevice device, PFN_vkGetDeviceProcAddr gdpa) {
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
}

static InstanceDispatch& GetInstanceDispatch(void* handle) {
    std::lock_guard<std::mutex> lock(g_dispatchMutex);
    return g_instanceDispatch[GetDispatchKey(handle)];
}

static DeviceDispatch& GetDeviceDispatch(void* handle) {
    std::lock_guard<std::mutex> lock(g_dispatchMutex);
    return g_deviceDispatch[GetDispatchKey(handle)];
}
