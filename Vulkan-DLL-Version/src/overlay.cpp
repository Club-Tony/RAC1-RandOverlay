/*
 * RandOverlay Vulkan DLL — hooks vkQueuePresentKHR to render text overlay
 * in RPCS3 exclusive fullscreen.
 *
 * Approach: Only hook vkQueuePresentKHR. Extract device/swapchain from the
 * present call's dispatch table on first invocation. This works for late
 * injection (RPCS3 already running).
 */
#include <windows.h>
#include <stdio.h>
#include <string>
#include <vector>
#include <vulkan/vulkan.h>
#include "MinHook.h"
#include "log_reader.h"

// ── Globals ───────────────────────────────────────────────────────────────────
static LogReader* g_logReader = nullptr;
static CRITICAL_SECTION g_cs;
static std::string g_currentMessage;
static DWORD g_messageTimestamp = 0;
static DWORD g_displayDurationMs = 5000;
static bool g_initialized = false;
static bool g_renderReady = false;
static bool g_firstPresent = true;
static FILE* g_logFile = nullptr;

// Vulkan state
static VkDevice g_device = VK_NULL_HANDLE;
static VkQueue g_queue = VK_NULL_HANDLE;
static uint32_t g_queueFamily = 0;
static VkSwapchainKHR g_swapchain = VK_NULL_HANDLE;
static VkRenderPass g_renderPass = VK_NULL_HANDLE;
static VkCommandPool g_commandPool = VK_NULL_HANDLE;
static std::vector<VkImage> g_swapImages;
static std::vector<VkImageView> g_swapViews;
static std::vector<VkFramebuffer> g_framebuffers;
static std::vector<VkCommandBuffer> g_cmdBuffers;
static VkFormat g_format = VK_FORMAT_B8G8R8A8_UNORM;
static VkExtent2D g_extent = {0, 0};
static VkSemaphore g_overlaySem = VK_NULL_HANDLE;

// Original function pointer
typedef VkResult (VKAPI_CALL *PFN_Present)(VkQueue, const VkPresentInfoKHR*);
static PFN_Present g_origPresent = nullptr;

// Dynamically loaded Vulkan functions
static PFN_vkGetDeviceProcAddr             g_GetDeviceProcAddr = nullptr;
static PFN_vkGetSwapchainImagesKHR         g_GetSwapImages = nullptr;
static PFN_vkCreateImageView               g_CreateImageView = nullptr;
static PFN_vkDestroyImageView              g_DestroyImageView = nullptr;
static PFN_vkCreateRenderPass              g_CreateRenderPass = nullptr;
static PFN_vkDestroyRenderPass             g_DestroyRenderPass = nullptr;
static PFN_vkCreateFramebuffer             g_CreateFramebuffer = nullptr;
static PFN_vkDestroyFramebuffer            g_DestroyFramebuffer = nullptr;
static PFN_vkCreateCommandPool             g_CreateCommandPool = nullptr;
static PFN_vkDestroyCommandPool            g_DestroyCommandPool = nullptr;
static PFN_vkAllocateCommandBuffers        g_AllocCmdBufs = nullptr;
static PFN_vkFreeCommandBuffers            g_FreeCmdBufs = nullptr;
static PFN_vkBeginCommandBuffer            g_BeginCmdBuf = nullptr;
static PFN_vkEndCommandBuffer              g_EndCmdBuf = nullptr;
static PFN_vkCmdBeginRenderPass            g_CmdBeginRP = nullptr;
static PFN_vkCmdEndRenderPass              g_CmdEndRP = nullptr;
static PFN_vkQueueSubmit                   g_QueueSubmit = nullptr;
static PFN_vkDeviceWaitIdle                g_DeviceWaitIdle = nullptr;
static PFN_vkCreateSemaphore               g_CreateSemaphore = nullptr;
static PFN_vkDestroySemaphore              g_DestroySemaphore = nullptr;
static PFN_vkResetCommandBuffer            g_ResetCmdBuf = nullptr;
static PFN_vkCmdPipelineBarrier            g_CmdPipelineBarrier = nullptr;

void OverlayLog(const char* fmt, ...) {
    if (!g_logFile) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(g_logFile, fmt, args);
    fprintf(g_logFile, "\n");
    fflush(g_logFile);
    va_end(args);
}

// ── Extract VkDevice from VkQueue using Vulkan dispatch table ─────────────────
// Vulkan dispatchable handles (VkDevice, VkQueue, VkCommandBuffer) all start
// with a pointer to the dispatch table. VkQueue and VkDevice share the same
// dispatch table, so we can cast the queue's dispatch pointer to a VkDevice.
static VkDevice DeviceFromQueue(VkQueue queue) {
    // The loader dispatch table pointer is the first sizeof(void*) bytes
    // of any dispatchable handle. Device and Queue share the same table.
    // We need to find the actual VkDevice handle though.
    // For our purposes, we'll use vkGetDeviceProcAddr via the DLL export
    // which works with any device handle from the same dispatch table.
    return VK_NULL_HANDLE; // Will use DLL-level functions instead
}

// ── Load Vulkan functions from the DLL ────────────────────────────────────────
static HMODULE g_vulkanDll = nullptr;

bool LoadFunctions() {
    g_vulkanDll = GetModuleHandleA("vulkan-1.dll");
    if (!g_vulkanDll) return false;

    #define LOADFN(name, type) g_##name = (type)GetProcAddress(g_vulkanDll, "vk" #name)
    // We use a different naming convention for GetProcAddress
    g_GetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)GetProcAddress(g_vulkanDll, "vkGetDeviceProcAddr");
    g_GetSwapImages = (PFN_vkGetSwapchainImagesKHR)GetProcAddress(g_vulkanDll, "vkGetSwapchainImagesKHR");
    g_CreateImageView = (PFN_vkCreateImageView)GetProcAddress(g_vulkanDll, "vkCreateImageView");
    g_DestroyImageView = (PFN_vkDestroyImageView)GetProcAddress(g_vulkanDll, "vkDestroyImageView");
    g_CreateRenderPass = (PFN_vkCreateRenderPass)GetProcAddress(g_vulkanDll, "vkCreateRenderPass");
    g_DestroyRenderPass = (PFN_vkDestroyRenderPass)GetProcAddress(g_vulkanDll, "vkDestroyRenderPass");
    g_CreateFramebuffer = (PFN_vkCreateFramebuffer)GetProcAddress(g_vulkanDll, "vkCreateFramebuffer");
    g_DestroyFramebuffer = (PFN_vkDestroyFramebuffer)GetProcAddress(g_vulkanDll, "vkDestroyFramebuffer");
    g_CreateCommandPool = (PFN_vkCreateCommandPool)GetProcAddress(g_vulkanDll, "vkCreateCommandPool");
    g_DestroyCommandPool = (PFN_vkDestroyCommandPool)GetProcAddress(g_vulkanDll, "vkDestroyCommandPool");
    g_AllocCmdBufs = (PFN_vkAllocateCommandBuffers)GetProcAddress(g_vulkanDll, "vkAllocateCommandBuffers");
    g_FreeCmdBufs = (PFN_vkFreeCommandBuffers)GetProcAddress(g_vulkanDll, "vkFreeCommandBuffers");
    g_BeginCmdBuf = (PFN_vkBeginCommandBuffer)GetProcAddress(g_vulkanDll, "vkBeginCommandBuffer");
    g_EndCmdBuf = (PFN_vkEndCommandBuffer)GetProcAddress(g_vulkanDll, "vkEndCommandBuffer");
    g_CmdBeginRP = (PFN_vkCmdBeginRenderPass)GetProcAddress(g_vulkanDll, "vkCmdBeginRenderPass");
    g_CmdEndRP = (PFN_vkCmdEndRenderPass)GetProcAddress(g_vulkanDll, "vkCmdEndRenderPass");
    g_QueueSubmit = (PFN_vkQueueSubmit)GetProcAddress(g_vulkanDll, "vkQueueSubmit");
    g_DeviceWaitIdle = (PFN_vkDeviceWaitIdle)GetProcAddress(g_vulkanDll, "vkDeviceWaitIdle");
    g_CreateSemaphore = (PFN_vkCreateSemaphore)GetProcAddress(g_vulkanDll, "vkCreateSemaphore");
    g_DestroySemaphore = (PFN_vkDestroySemaphore)GetProcAddress(g_vulkanDll, "vkDestroySemaphore");
    g_ResetCmdBuf = (PFN_vkResetCommandBuffer)GetProcAddress(g_vulkanDll, "vkResetCommandBuffer");
    g_CmdPipelineBarrier = (PFN_vkCmdPipelineBarrier)GetProcAddress(g_vulkanDll, "vkCmdPipelineBarrier");
    #undef LOADFN

    return g_GetSwapImages && g_CreateRenderPass && g_QueueSubmit;
}

// ── Discover device from queue's dispatch table ───────────────────────────────
// Vulkan ICDs store a dispatch table pointer as the first member of every
// dispatchable handle. We can use vkGetDeviceProcAddr through the loader to
// find the device. But the simplest approach: enumerate physical devices
// and find the one that matches.
//
// Actually — even simpler: vkGetSwapchainImagesKHR etc. in the Vulkan loader
// dispatch through the queue's dispatch table anyway. So we just need ANY valid
// VkDevice handle. We can get one by calling vkGetDeviceQueue in reverse —
// but that requires the device. Chicken-and-egg.
//
// The trick: the Vulkan loader's trampoline for vkQueuePresentKHR internally
// looks up the device from the queue. When we call g_GetSwapImages etc. through
// the loader DLL exports, the loader does the dispatch for us — we just need
// to pass a valid VkDevice. Since VkQueue's first bytes point to the same
// dispatch table as VkDevice, we can CAST VkQueue to VkDevice for loader calls.
// This is a known technique used by overlay tools.

// ── Cleanup ───────────────────────────────────────────────────────────────────
void Cleanup() {
    if (!g_device) return;
    g_DeviceWaitIdle(g_device);

    if (g_commandPool && !g_cmdBuffers.empty()) {
        g_FreeCmdBufs(g_device, g_commandPool, (uint32_t)g_cmdBuffers.size(), g_cmdBuffers.data());
        g_cmdBuffers.clear();
    }
    for (auto fb : g_framebuffers) g_DestroyFramebuffer(g_device, fb, nullptr);
    g_framebuffers.clear();
    for (auto iv : g_swapViews) g_DestroyImageView(g_device, iv, nullptr);
    g_swapViews.clear();
    if (g_renderPass) { g_DestroyRenderPass(g_device, g_renderPass, nullptr); g_renderPass = VK_NULL_HANDLE; }
    if (g_commandPool) { g_DestroyCommandPool(g_device, g_commandPool, nullptr); g_commandPool = VK_NULL_HANDLE; }
    if (g_overlaySem) { g_DestroySemaphore(g_device, g_overlaySem, nullptr); g_overlaySem = VK_NULL_HANDLE; }
    g_renderReady = false;
}

// ── Find RPCS3 window callback ────────────────────────────────────────────────
struct EnumData { HWND result; DWORD pid; };
static BOOL CALLBACK FindRpcs3Window(HWND h, LPARAM lp) {
    auto* d = (EnumData*)lp;
    DWORD pid;
    GetWindowThreadProcessId(h, &pid);
    if (pid == d->pid && IsWindowVisible(h)) {
        char title[256];
        GetWindowTextA(h, title, sizeof(title));
        if (strlen(title) > 0) { d->result = h; return FALSE; }
    }
    return TRUE;
}

// ── Setup render resources from existing swapchain ────────────────────────────
bool SetupFromSwapchain(VkDevice device, VkSwapchainKHR swapchain) {
    g_device = device;
    g_swapchain = swapchain;

    // Get swapchain images
    uint32_t count = 0;
    VkResult r = g_GetSwapImages(device, swapchain, &count, nullptr);
    if (r != VK_SUCCESS || count == 0) {
        OverlayLog("GetSwapchainImages count failed: %d", r);
        return false;
    }
    g_swapImages.resize(count);
    g_GetSwapImages(device, swapchain, &count, g_swapImages.data());
    OverlayLog("Swapchain has %u images", count);

    // We assume B8G8R8A8_UNORM — RPCS3 uses this format
    g_format = VK_FORMAT_B8G8R8A8_UNORM;

    // Get extent from RPCS3 window
    HWND hwnd = FindWindowA(nullptr, nullptr);
    // Try to find RPCS3 window
    EnumData ed = { nullptr, GetCurrentProcessId() };
    EnumWindows(FindRpcs3Window, (LPARAM)&ed);

    if (ed.result) {
        RECT r;
        GetClientRect(ed.result, &r);
        g_extent.width = r.right - r.left;
        g_extent.height = r.bottom - r.top;
        OverlayLog("Window extent: %ux%u", g_extent.width, g_extent.height);
    } else {
        // Fallback: assume 1920x1080
        g_extent = {1920, 1080};
        OverlayLog("No window found, using fallback 1920x1080");
    }

    // Create render pass (LOAD existing content, STORE after our draw)
    VkAttachmentDescription att = {};
    att.format = g_format;
    att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD;
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    att.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference ref = {};
    ref.attachment = 0;
    ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

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

    VkRenderPassCreateInfo rpci = {};
    rpci.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rpci.attachmentCount = 1;
    rpci.pAttachments = &att;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &sub;
    rpci.dependencyCount = 1;
    rpci.pDependencies = &dep;

    if (g_CreateRenderPass(device, &rpci, nullptr, &g_renderPass) != VK_SUCCESS) {
        OverlayLog("CreateRenderPass failed");
        return false;
    }

    // Create image views + framebuffers
    g_swapViews.resize(count);
    g_framebuffers.resize(count);
    for (uint32_t i = 0; i < count; i++) {
        VkImageViewCreateInfo ivci = {};
        ivci.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        ivci.image = g_swapImages[i];
        ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        ivci.format = g_format;
        ivci.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        ivci.subresourceRange.levelCount = 1;
        ivci.subresourceRange.layerCount = 1;
        if (g_CreateImageView(device, &ivci, nullptr, &g_swapViews[i]) != VK_SUCCESS) {
            OverlayLog("CreateImageView[%u] failed", i);
            return false;
        }

        VkFramebufferCreateInfo fbci = {};
        fbci.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fbci.renderPass = g_renderPass;
        fbci.attachmentCount = 1;
        fbci.pAttachments = &g_swapViews[i];
        fbci.width = g_extent.width;
        fbci.height = g_extent.height;
        fbci.layers = 1;
        if (g_CreateFramebuffer(device, &fbci, nullptr, &g_framebuffers[i]) != VK_SUCCESS) {
            OverlayLog("CreateFramebuffer[%u] failed", i);
            return false;
        }
    }

    // Command pool + buffers (use queue family 0 — RPCS3 uses a single graphics queue)
    VkCommandPoolCreateInfo cpci = {};
    cpci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = 0; // RPCS3 uses queue family 0 for graphics
    if (g_CreateCommandPool(device, &cpci, nullptr, &g_commandPool) != VK_SUCCESS) {
        OverlayLog("CreateCommandPool failed");
        return false;
    }

    g_cmdBuffers.resize(count);
    VkCommandBufferAllocateInfo cbai = {};
    cbai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cbai.commandPool = g_commandPool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = count;
    g_AllocCmdBufs(device, &cbai, g_cmdBuffers.data());

    // Semaphore for sync
    VkSemaphoreCreateInfo sci = {};
    sci.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    g_CreateSemaphore(device, &sci, nullptr, &g_overlaySem);

    g_renderReady = true;
    OverlayLog("Render resources ready (%u framebuffers, extent %ux%u)", count, g_extent.width, g_extent.height);
    return true;
}

// ── Record overlay commands (empty pass for now — proves pipeline works) ──────
void RecordOverlay(uint32_t idx) {
    if (!g_renderReady || idx >= g_cmdBuffers.size()) return;

    VkCommandBuffer cmd = g_cmdBuffers[idx];
    g_ResetCmdBuf(cmd, 0);

    VkCommandBufferBeginInfo bi = {};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    g_BeginCmdBuf(cmd, &bi);

    VkRenderPassBeginInfo rpbi = {};
    rpbi.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rpbi.renderPass = g_renderPass;
    rpbi.framebuffer = g_framebuffers[idx];
    rpbi.renderArea.extent = g_extent;
    g_CmdBeginRP(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);

    // TODO: ImGui draw commands go here
    // Empty render pass preserves existing frame (LOAD_OP_LOAD)

    g_CmdEndRP(cmd);
    g_EndCmdBuf(cmd);
}

// ── Hooked vkQueuePresentKHR ──────────────────────────────────────────────────
VkResult VKAPI_CALL HookedPresent(VkQueue queue, const VkPresentInfoKHR* pPresent) {
    // First present call: extract device and setup render resources
    if (g_firstPresent && pPresent->swapchainCount > 0) {
        g_firstPresent = false;
        g_queue = queue;

        // Cast queue to device — they share the same dispatch table pointer
        // This is the standard technique used by overlay tools
        VkDevice device = (VkDevice)queue;
        VkSwapchainKHR swapchain = pPresent->pSwapchains[0];

        OverlayLog("First present! Queue=0x%p, Swapchain=0x%p", queue, swapchain);

        if (!SetupFromSwapchain(device, swapchain)) {
            OverlayLog("Setup failed — overlay disabled, passing through");
        }
    }

    // Poll for new messages
    EnterCriticalSection(&g_cs);
    if (g_logReader) {
        auto msgs = g_logReader->poll();
        if (!msgs.empty()) {
            g_currentMessage = msgs.back().text;
            g_messageTimestamp = GetTickCount();
            OverlayLog("Message: %s", g_currentMessage.c_str());
        }
    }
    if (!g_currentMessage.empty() && (GetTickCount() - g_messageTimestamp) > g_displayDurationMs) {
        g_currentMessage.clear();
    }
    bool hasMsg = !g_currentMessage.empty();
    LeaveCriticalSection(&g_cs);

    // Submit overlay if we have a message and render resources
    if (hasMsg && g_renderReady && pPresent->swapchainCount > 0) {
        uint32_t idx = pPresent->pImageIndices[0];
        if (idx < g_cmdBuffers.size()) {
            RecordOverlay(idx);

            VkSubmitInfo si = {};
            si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
            si.waitSemaphoreCount = pPresent->waitSemaphoreCount;
            si.pWaitSemaphores = pPresent->pWaitSemaphores;
            VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
            si.pWaitDstStageMask = &waitStage;
            si.commandBufferCount = 1;
            si.pCommandBuffers = &g_cmdBuffers[idx];
            si.signalSemaphoreCount = 1;
            si.pSignalSemaphores = &g_overlaySem;

            g_QueueSubmit(queue, 1, &si, VK_NULL_HANDLE);

            // Present waits on our semaphore
            VkPresentInfoKHR mod = *pPresent;
            mod.waitSemaphoreCount = 1;
            mod.pWaitSemaphores = &g_overlaySem;
            return g_origPresent(queue, &mod);
        }
    }

    return g_origPresent(queue, pPresent);
}

// ── Hook setup (only vkQueuePresentKHR) ───────────────────────────────────────
bool SetupHook() {
    if (!LoadFunctions()) {
        OverlayLog("Failed to load Vulkan functions from DLL");
        return false;
    }
    OverlayLog("Vulkan functions loaded from vulkan-1.dll");

    if (MH_Initialize() != MH_OK) {
        OverlayLog("MinHook init failed");
        return false;
    }

    auto addr = GetProcAddress(g_vulkanDll, "vkQueuePresentKHR");
    if (!addr) {
        OverlayLog("vkQueuePresentKHR not found in vulkan-1.dll");
        return false;
    }

    if (MH_CreateHook((LPVOID)addr, (LPVOID)&HookedPresent, (LPVOID*)&g_origPresent) != MH_OK) {
        OverlayLog("Failed to create hook for vkQueuePresentKHR");
        return false;
    }

    if (MH_EnableHook((LPVOID)addr) != MH_OK) {
        OverlayLog("Failed to enable hook");
        return false;
    }

    OverlayLog("vkQueuePresentKHR hooked at 0x%p", addr);
    return true;
}

void CleanupAll() {
    Cleanup();
    MH_DisableHook(MH_ALL_HOOKS);
    MH_Uninitialize();
    delete g_logReader;
    g_logReader = nullptr;
    if (g_logFile) { fclose(g_logFile); g_logFile = nullptr; }
    DeleteCriticalSection(&g_cs);
}

DWORD WINAPI InitThread(LPVOID param) {
    // Setup log file next to DLL
    char dllPath[MAX_PATH];
    GetModuleFileNameA((HMODULE)param, dllPath, MAX_PATH);
    std::string logPath(dllPath);
    logPath = logPath.substr(0, logPath.find_last_of("\\/") + 1) + "overlay_debug.log";
    g_logFile = fopen(logPath.c_str(), "w");

    InitializeCriticalSection(&g_cs);
    OverlayLog("=== RandOverlay DLL loaded ===");
    OverlayLog("PID: %lu", GetCurrentProcessId());

    Sleep(1000); // Brief wait for Vulkan to finish init

    g_logReader = new LogReader();
    OverlayLog("Log reader initialized, monitoring Archipelago logs");

    if (SetupHook()) {
        g_initialized = true;
        OverlayLog("Hook active. Overlay will initialize on first present call.");
    } else {
        OverlayLog("Hook setup FAILED");
    }

    return 0;
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved) {
    switch (reason) {
        case DLL_PROCESS_ATTACH:
            DisableThreadLibraryCalls(hModule);
            CreateThread(NULL, 0, InitThread, hModule, 0, NULL);
            break;
        case DLL_PROCESS_DETACH:
            CleanupAll();
            break;
    }
    return TRUE;
}
