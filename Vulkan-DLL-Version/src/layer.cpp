/*
 * RandOverlay Vulkan Implicit Layer
 * Intercepts vkQueuePresentKHR to render Archipelago text notifications.
 *
 * Step 1: Skeleton — log + pass through, verify layer loads in RPCS3.
 */
#include <windows.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

// MinGW doesn't define VK_LAYER_EXPORT
#ifndef VK_LAYER_EXPORT
#define VK_LAYER_EXPORT extern "C" __declspec(dllexport)
#endif
#include <stdio.h>
#include <string.h>
#include <string>
#include <vector>
#include "layer_dispatch.h"
#include "log_reader.h"

// ── Debug logging ─────────────────────────────────────────────────────────────
static FILE* g_log = nullptr;

static void LayerLog(const char* fmt, ...) {
    if (!g_log) {
        // Log next to the DLL
        char path[MAX_PATH];
        HMODULE hm = nullptr;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)&LayerLog, &hm);
        GetModuleFileNameA(hm, path, MAX_PATH);
        std::string logPath(path);
        logPath = logPath.substr(0, logPath.find_last_of("\\/") + 1) + "layer_debug.log";
        g_log = fopen(logPath.c_str(), "w");
        if (!g_log) return;
    }
    va_list args;
    va_start(args, fmt);
    vfprintf(g_log, fmt, args);
    fprintf(g_log, "\n");
    fflush(g_log);
    va_end(args);
}

// ── Overlay state ─────────────────────────────────────────────────────────────
static LogReader* g_logReader = nullptr;
static std::string g_currentMessage;
static DWORD g_messageTimestamp = 0;
static DWORD g_displayDurationMs = 5000;
static bool g_disabled = false;

// Swapchain state
static VkDevice g_device = VK_NULL_HANDLE;
static VkSwapchainKHR g_swapchain = VK_NULL_HANDLE;
static VkFormat g_swapFormat = VK_FORMAT_B8G8R8A8_UNORM;
static VkExtent2D g_swapExtent = {0, 0};
static uint32_t g_queueFamily = 0;
static bool g_renderReady = false;

// Render resources
static VkRenderPass g_renderPass = VK_NULL_HANDLE;
static VkCommandPool g_cmdPool = VK_NULL_HANDLE;
static std::vector<VkImage> g_swapImages;
static std::vector<VkImageView> g_swapViews;
static std::vector<VkFramebuffer> g_framebuffers;
static std::vector<VkCommandBuffer> g_cmdBuffers;
static VkSemaphore g_overlaySem = VK_NULL_HANDLE;

// ── Cleanup render resources ──────────────────────────────────────────────────
static void CleanupRender(VkDevice device) {
    auto& d = GetDeviceDispatch(device);
    d.DeviceWaitIdle(device);

    if (g_cmdPool && !g_cmdBuffers.empty()) {
        d.FreeCommandBuffers(device, g_cmdPool, (uint32_t)g_cmdBuffers.size(), g_cmdBuffers.data());
        g_cmdBuffers.clear();
    }
    for (auto fb : g_framebuffers) d.DestroyFramebuffer(device, fb, nullptr);
    g_framebuffers.clear();
    for (auto iv : g_swapViews) d.DestroyImageView(device, iv, nullptr);
    g_swapViews.clear();
    if (g_renderPass) { d.DestroyRenderPass(device, g_renderPass, nullptr); g_renderPass = VK_NULL_HANDLE; }
    if (g_cmdPool) { d.DestroyCommandPool(device, g_cmdPool, nullptr); g_cmdPool = VK_NULL_HANDLE; }
    if (g_overlaySem) { d.DestroySemaphore(device, g_overlaySem, nullptr); g_overlaySem = VK_NULL_HANDLE; }
    g_renderReady = false;
}

// ── Setup render resources ────────────────────────────────────────────────────
static bool SetupRender(VkDevice device) {
    auto& d = GetDeviceDispatch(device);

    uint32_t count = 0;
    d.GetSwapchainImagesKHR(device, g_swapchain, &count, nullptr);
    if (count == 0) return false;
    g_swapImages.resize(count);
    d.GetSwapchainImagesKHR(device, g_swapchain, &count, g_swapImages.data());
    LayerLog("Swapchain: %u images, %ux%u, format=%d", count, g_swapExtent.width, g_swapExtent.height, g_swapFormat);

    // Render pass
    VkAttachmentDescription att = {};
    att.format = g_swapFormat;
    att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    att.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &ref;

    VkSubpassDependency dep = {};
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.srcAccessMask = 0;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo rpci = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    rpci.attachmentCount = 1;
    rpci.pAttachments = &att;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &sub;
    rpci.dependencyCount = 1;
    rpci.pDependencies = &dep;

    if (d.CreateRenderPass(device, &rpci, nullptr, &g_renderPass) != VK_SUCCESS) {
        LayerLog("CreateRenderPass FAILED");
        return false;
    }

    // Image views + framebuffers
    g_swapViews.resize(count);
    g_framebuffers.resize(count);
    for (uint32_t i = 0; i < count; i++) {
        VkImageViewCreateInfo ivci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        ivci.image = g_swapImages[i];
        ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        ivci.format = g_swapFormat;
        ivci.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        d.CreateImageView(device, &ivci, nullptr, &g_swapViews[i]);

        VkFramebufferCreateInfo fbci = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        fbci.renderPass = g_renderPass;
        fbci.attachmentCount = 1;
        fbci.pAttachments = &g_swapViews[i];
        fbci.width = g_swapExtent.width;
        fbci.height = g_swapExtent.height;
        fbci.layers = 1;
        d.CreateFramebuffer(device, &fbci, nullptr, &g_framebuffers[i]);
    }

    // Command pool + buffers
    VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = g_queueFamily;
    d.CreateCommandPool(device, &cpci, nullptr, &g_cmdPool);

    g_cmdBuffers.resize(count);
    VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cbai.commandPool = g_cmdPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = count;
    d.AllocateCommandBuffers(device, &cbai, g_cmdBuffers.data());

    // Semaphore
    VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    d.CreateSemaphore_(device, &sci, nullptr, &g_overlaySem);

    g_renderReady = true;
    LayerLog("Render resources ready (%u framebuffers)", count);
    return true;
}

// ── Hooked: vkCreateInstance ──────────────────────────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_CreateInstance(
    const VkInstanceCreateInfo* pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkInstance* pInstance)
{
    // Check if disabled via environment variable
    const char* disabled = getenv("DISABLE_RANDOVERLAY");
    if (disabled && strcmp(disabled, "1") == 0) {
        g_disabled = true;
    }

    // Get the layer chain info
    auto* layerInfo = (VkLayerInstanceCreateInfo*)pCreateInfo->pNext;
    while (layerInfo && !(layerInfo->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
                          layerInfo->function == VK_LAYER_LINK_INFO)) {
        layerInfo = (VkLayerInstanceCreateInfo*)layerInfo->pNext;
    }
    if (!layerInfo) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr gipa = layerInfo->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    // Advance the chain for the next layer
    layerInfo->u.pLayerInfo = layerInfo->u.pLayerInfo->pNext;

    // Call the real vkCreateInstance
    auto createInstance = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    VkResult result = createInstance(pCreateInfo, pAllocator, pInstance);
    if (result != VK_SUCCESS) return result;

    // Store dispatch table
    InitInstanceDispatch(*pInstance, gipa);
    LayerLog("=== RandOverlay Layer loaded ===");
    LayerLog("vkCreateInstance OK, instance=0x%p, disabled=%d", *pInstance, g_disabled);

    // Init log reader
    if (!g_disabled && !g_logReader) {
        g_logReader = new LogReader();
        LayerLog("Log reader initialized");
    }

    return VK_SUCCESS;
}

// ── Hooked: vkCreateDevice ────────────────────────────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_CreateDevice(
    VkPhysicalDevice physDevice,
    const VkDeviceCreateInfo* pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkDevice* pDevice)
{
    // Get the layer chain info
    auto* layerInfo = (VkLayerDeviceCreateInfo*)pCreateInfo->pNext;
    while (layerInfo && !(layerInfo->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                          layerInfo->function == VK_LAYER_LINK_INFO)) {
        layerInfo = (VkLayerDeviceCreateInfo*)layerInfo->pNext;
    }
    if (!layerInfo) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr gipa = layerInfo->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = layerInfo->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    // Advance the chain
    layerInfo->u.pLayerInfo = layerInfo->u.pLayerInfo->pNext;

    auto createDevice = (PFN_vkCreateDevice)gipa(VK_NULL_HANDLE, "vkCreateDevice");
    VkResult result = createDevice(physDevice, pCreateInfo, pAllocator, pDevice);
    if (result != VK_SUCCESS) return result;

    // Store device dispatch table
    InitDeviceDispatch(*pDevice, gdpa);
    g_device = *pDevice;

    // Get queue family from create info
    if (pCreateInfo->queueCreateInfoCount > 0) {
        g_queueFamily = pCreateInfo->pQueueCreateInfos[0].queueFamilyIndex;
    }

    LayerLog("vkCreateDevice OK, device=0x%p, queueFamily=%u", *pDevice, g_queueFamily);
    return VK_SUCCESS;
}

// ── Hooked: vkCreateSwapchainKHR ──────────────────────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_CreateSwapchainKHR(
    VkDevice device,
    const VkSwapchainCreateInfoKHR* pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkSwapchainKHR* pSwapchain)
{
    // Clean up old resources
    if (g_renderReady) CleanupRender(device);

    auto& d = GetDeviceDispatch(device);
    VkResult result = d.CreateSwapchainKHR(device, pCreateInfo, pAllocator, pSwapchain);
    if (result != VK_SUCCESS) return result;

    g_swapchain = *pSwapchain;
    g_swapFormat = pCreateInfo->imageFormat;
    g_swapExtent = pCreateInfo->imageExtent;
    g_device = device;

    LayerLog("vkCreateSwapchainKHR: %ux%u format=%d", g_swapExtent.width, g_swapExtent.height, g_swapFormat);

    if (!g_disabled) {
        SetupRender(device);
    }

    return VK_SUCCESS;
}

// ── Hooked: vkQueuePresentKHR ─────────────────────────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_QueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR* pPresentInfo)
{
    auto& d = GetDeviceDispatch(queue);

    if (g_disabled || !g_renderReady) {
        return d.QueuePresentKHR(queue, pPresentInfo);
    }

    // Poll for new messages
    if (g_logReader) {
        auto msgs = g_logReader->poll();
        if (!msgs.empty()) {
            g_currentMessage = msgs.back().text;
            g_messageTimestamp = GetTickCount();
            LayerLog("Message: %s", g_currentMessage.c_str());
        }
    }
    if (!g_currentMessage.empty() && (GetTickCount() - g_messageTimestamp) > g_displayDurationMs) {
        g_currentMessage.clear();
    }

    bool hasMsg = !g_currentMessage.empty();

    // Submit empty overlay pass (Step 3 — proves pipeline works)
    if (hasMsg && pPresentInfo->swapchainCount > 0) {
        uint32_t idx = pPresentInfo->pImageIndices[0];
        if (idx < g_cmdBuffers.size()) {
            VkCommandBuffer cmd = g_cmdBuffers[idx];
            d.ResetCommandBuffer(cmd, 0);

            VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            d.BeginCommandBuffer(cmd, &bi);

            VkRenderPassBeginInfo rpbi = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
            rpbi.renderPass = g_renderPass;
            rpbi.framebuffer = g_framebuffers[idx];
            rpbi.renderArea.extent = g_swapExtent;
            d.CmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);

            // Step 4a: Draw a colored rectangle as proof-of-concept
            // Uses vkCmdClearAttachments — no pipeline/shaders needed
            {
                // Dark background bar (centered, 35% from top)
                float barY = g_swapExtent.height * 0.35f;
                float barH = 40.0f;
                float barW = g_swapExtent.width * 0.5f;
                float barX = (g_swapExtent.width - barW) / 2.0f;

                VkClearAttachment clearAtt = {};
                clearAtt.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
                clearAtt.colorAttachment = 0;
                // Dark semi-transparent bar (RGB ~30,30,30)
                clearAtt.clearValue.color.float32[0] = 0.12f;
                clearAtt.clearValue.color.float32[1] = 0.12f;
                clearAtt.clearValue.color.float32[2] = 0.12f;
                clearAtt.clearValue.color.float32[3] = 0.85f;

                VkClearRect clearRect = {};
                clearRect.rect.offset = {(int32_t)barX, (int32_t)barY};
                clearRect.rect.extent = {(uint32_t)barW, (uint32_t)barH};
                clearRect.baseArrayLayer = 0;
                clearRect.layerCount = 1;

                d.CmdClearAttachments(cmd, 1, &clearAtt, 1, &clearRect);
            }

            d.CmdEndRenderPass(cmd);
            d.EndCommandBuffer(cmd);

            // Submit before present
            VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
            si.waitSemaphoreCount = pPresentInfo->waitSemaphoreCount;
            si.pWaitSemaphores = pPresentInfo->pWaitSemaphores;
            VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            si.pWaitDstStageMask = &waitStage;
            si.commandBufferCount = 1;
            si.pCommandBuffers = &cmd;
            si.signalSemaphoreCount = 1;
            si.pSignalSemaphores = &g_overlaySem;
            d.QueueSubmit(queue, 1, &si, VK_NULL_HANDLE);

            // Present waits on our semaphore
            VkPresentInfoKHR mod = *pPresentInfo;
            mod.waitSemaphoreCount = 1;
            mod.pWaitSemaphores = &g_overlaySem;
            return d.QueuePresentKHR(queue, &mod);
        }
    }

    return d.QueuePresentKHR(queue, pPresentInfo);
}

// ── Hooked: vkDestroyDevice ───────────────────────────────────────────────────
VK_LAYER_EXPORT void VKAPI_CALL RandOverlay_DestroyDevice(
    VkDevice device,
    const VkAllocationCallbacks* pAllocator)
{
    LayerLog("vkDestroyDevice");
    if (g_renderReady) CleanupRender(device);
    auto& d = GetDeviceDispatch(device);
    d.DestroyDevice(device, pAllocator);

    std::lock_guard<std::mutex> lock(g_dispatchMutex);
    g_deviceDispatch.erase(GetDispatchKey(device));
}

// ── Hooked: vkDestroyInstance ─────────────────────────────────────────────────
VK_LAYER_EXPORT void VKAPI_CALL RandOverlay_DestroyInstance(
    VkInstance instance,
    const VkAllocationCallbacks* pAllocator)
{
    LayerLog("vkDestroyInstance");
    delete g_logReader;
    g_logReader = nullptr;

    auto& d = GetInstanceDispatch(instance);
    d.DestroyInstance(instance, pAllocator);

    std::lock_guard<std::mutex> lock(g_dispatchMutex);
    g_instanceDispatch.erase(GetDispatchKey(instance));

    if (g_log) { fclose(g_log); g_log = nullptr; }
}

// ── Layer entry points ────────────────────────────────────────────────────────
#define GETPROCADDR(name) if (strcmp(pName, "vk" #name) == 0) return (PFN_vkVoidFunction)&RandOverlay_##name

VK_LAYER_EXPORT PFN_vkVoidFunction VKAPI_CALL RandOverlay_GetDeviceProcAddr(
    VkDevice device, const char* pName)
{
    GETPROCADDR(QueuePresentKHR);
    GETPROCADDR(CreateSwapchainKHR);
    GETPROCADDR(DestroyDevice);

    auto& d = GetDeviceDispatch(device);
    return d.GetDeviceProcAddr(device, pName);
}

VK_LAYER_EXPORT PFN_vkVoidFunction VKAPI_CALL RandOverlay_GetInstanceProcAddr(
    VkInstance instance, const char* pName)
{
    GETPROCADDR(CreateInstance);
    GETPROCADDR(CreateDevice);
    GETPROCADDR(DestroyInstance);

    // Device-level functions can also be queried through instance
    GETPROCADDR(QueuePresentKHR);
    GETPROCADDR(CreateSwapchainKHR);
    GETPROCADDR(DestroyDevice);

    if (instance == VK_NULL_HANDLE) return nullptr;
    auto& d = GetInstanceDispatch(instance);
    return d.GetInstanceProcAddr(instance, pName);
}

// ── Negotiate layer version (required by loader) ──────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_NegotiateLoaderLayerInterfaceVersion(
    VkNegotiateLayerInterface* pVersionStruct)
{
    if (pVersionStruct->loaderLayerInterfaceVersion >= 2) {
        pVersionStruct->pfnGetInstanceProcAddr = RandOverlay_GetInstanceProcAddr;
        pVersionStruct->pfnGetDeviceProcAddr = RandOverlay_GetDeviceProcAddr;
        pVersionStruct->pfnGetPhysicalDeviceProcAddr = nullptr;
    }
    pVersionStruct->loaderLayerInterfaceVersion = 2;
    return VK_SUCCESS;
}
