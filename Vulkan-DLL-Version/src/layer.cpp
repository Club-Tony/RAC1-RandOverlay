/*
 * RandOverlay Vulkan Implicit Layer
 *
 * Sits in the Vulkan dispatch chain (registered as a per-user implicit layer)
 * and intercepts vkQueuePresentKHR to draw Archipelago randomizer event text
 * INSIDE the emulator's frame. Because it is in-chain, it works in exclusive
 * fullscreen, borderless, and windowed alike — unlike a top-most window overlay.
 *
 * Rendering is done with Dear ImGui's Vulkan backend. The layer is gated to the
 * supported emulators (rpcs3.exe / pcsx2-qt.exe / pcsx2.exe) so that leaving it
 * registered system-wide is safe for every other Vulkan app.
 */
#include <windows.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

// MinGW doesn't define VK_LAYER_EXPORT
#ifndef VK_LAYER_EXPORT
#define VK_LAYER_EXPORT extern "C" __declspec(dllexport)
#endif

#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <string>
#include <vector>

#include "imgui.h"
#include "backends/imgui_impl_vulkan.h"

#include "layer_dispatch.h"
#include "log_reader.h"
#include "config.h"
#include "process_gate.h"
#include "font_resolver.h"
#include "arch_client_check.h"

// ── Debug logging ─────────────────────────────────────────────────────────────
static FILE* g_log = nullptr;

static void LayerLog(const char* fmt, ...) {
    if (!g_log) {
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

// ── State ─────────────────────────────────────────────────────────────────────
static RandOverlayConfig g_config;
static bool g_disabled = false;

static LogReader* g_logReader = nullptr;
static std::string g_currentMessage;
static ULONGLONG g_messageTimestamp = 0;
static ULONGLONG g_lastPollTick = 0;      // parity: poll the log at PollMs, not per frame
static bool g_readyMessageShown = false;  // parity: one-time startup notification

// Message alpha lifecycle (parity with AHK/PS fade behavior):
// fade in over FadeInMs (inside the hold window), hold until DisplayMs,
// fade out over FadeOutMs, then clear. Returns 0 when nothing should draw.
static float MessageAlpha(ULONGLONG now) {
    if (g_currentMessage.empty()) return 0.0f;
    ULONGLONG t = now - g_messageTimestamp;
    ULONGLONG holdEnd = (ULONGLONG)g_config.displayMs;
    ULONGLONG fadeEnd = holdEnd + (ULONGLONG)g_config.fadeOutMs;
    if (t >= fadeEnd) { g_currentMessage.clear(); return 0.0f; }
    float a = 1.0f;
    if (g_config.fadeInMs > 0 && t < (ULONGLONG)g_config.fadeInMs)
        a = (float)t / (float)g_config.fadeInMs;
    else if (t >= holdEnd && g_config.fadeOutMs > 0)
        a = 1.0f - (float)(t - holdEnd) / (float)g_config.fadeOutMs;
    return a < 0.0f ? 0.0f : (a > 1.0f ? 1.0f : a);
}

// Vulkan chain / handles
static PFN_vkGetInstanceProcAddr g_nextGIPA = nullptr; // next layer down (instance)
static PFN_vkGetDeviceProcAddr   g_nextGDPA = nullptr; // next layer down (device)
static PFN_vkSetDeviceLoaderData g_setDeviceLoaderData = nullptr;
static VkInstance        g_instance       = VK_NULL_HANDLE;
static VkPhysicalDevice  g_physicalDevice = VK_NULL_HANDLE;
static VkDevice          g_device         = VK_NULL_HANDLE;
static uint32_t          g_apiVersion     = VK_API_VERSION_1_0;
static uint32_t          g_queueFamily    = 0;
static VkQueue           g_graphicsQueue  = VK_NULL_HANDLE;

// Swapchain / render resources
static VkSwapchainKHR g_swapchain  = VK_NULL_HANDLE;
static VkFormat       g_swapFormat = VK_FORMAT_B8G8R8A8_UNORM;
static VkExtent2D     g_swapExtent = {0, 0};
static VkRenderPass   g_renderPass = VK_NULL_HANDLE;
static VkCommandPool  g_cmdPool    = VK_NULL_HANDLE;
static std::vector<VkImage>       g_swapImages;
static std::vector<VkImageView>   g_swapViews;
static std::vector<VkFramebuffer> g_framebuffers;
static std::vector<VkCommandBuffer> g_cmdBuffers;
static std::vector<bool>          g_cmdRecorded;
static std::vector<VkSemaphore>   g_overlaySems; // one per swapchain image
static bool g_renderReady = false;
static bool g_imguiReady  = false;
static ULONGLONG g_lastPresentTick = 0;

static VkResult VKAPI_CALL AllocateLayerCommandBuffers(
    VkDevice device,
    const VkCommandBufferAllocateInfo* pAllocateInfo,
    VkCommandBuffer* pCommandBuffers);

// ── ImGui Vulkan function loader (routes DOWN the chain, not the loader exports) ─
static bool IsInstanceLevelImguiFunction(const char* name) {
    static const char* const names[] = {
        "vkDestroySurfaceKHR",
        "vkEnumeratePhysicalDevices",
        "vkGetPhysicalDeviceProperties",
        "vkGetPhysicalDeviceMemoryProperties",
        "vkGetPhysicalDeviceQueueFamilyProperties",
        "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        "vkGetPhysicalDeviceSurfaceFormatsKHR",
        "vkGetPhysicalDeviceSurfacePresentModesKHR",
    };
    for (const char* candidate : names)
        if (strcmp(name, candidate) == 0) return true;
    return false;
}

static PFN_vkVoidFunction ImguiLoader(const char* name, void*) {
    PFN_vkVoidFunction f = nullptr;
    if (IsInstanceLevelImguiFunction(name)) {
        if (g_nextGIPA && g_instance) f = g_nextGIPA(g_instance, name);
    } else {
        if (strcmp(name, "vkAllocateCommandBuffers") == 0)
            return (PFN_vkVoidFunction)&AllocateLayerCommandBuffers;
        if (g_nextGDPA && g_device) f = g_nextGDPA(g_device, name);
        if (!f && g_nextGIPA && g_instance) f = g_nextGIPA(g_instance, name);
    }
    return f;
}

static VkResult VKAPI_CALL AllocateLayerCommandBuffers(
    VkDevice device,
    const VkCommandBufferAllocateInfo* pAllocateInfo,
    VkCommandBuffer* pCommandBuffers)
{
    auto& d = GetDeviceDispatch(device);
    VkResult result = d.AllocateCommandBuffers(device, pAllocateInfo, pCommandBuffers);
    if (result != VK_SUCCESS) return result;
    if (!g_setDeviceLoaderData) return VK_ERROR_INITIALIZATION_FAILED;

    for (uint32_t i = 0; i < pAllocateInfo->commandBufferCount; i++) {
        result = g_setDeviceLoaderData(device, pCommandBuffers[i]);
        if (result != VK_SUCCESS) return result;
    }
    return VK_SUCCESS;
}

// ── ImGui shutdown ────────────────────────────────────────────────────────────
static void ShutdownImgui() {
    if (!g_imguiReady) return;
    ImGui_ImplVulkan_Shutdown();
    if (ImGui::GetCurrentContext()) ImGui::DestroyContext();
    g_imguiReady = false;
}

// ── ImGui init (bound to our overlay render pass) ─────────────────────────────
static bool InitImgui() {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;   // don't read/write imgui.ini
    io.LogFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;

    // Font parity with the AHK/PS runtimes: the configured FontFamily
    // (HandelGothic BT — the R&C-style font), then FontFallback (Bahnschrift),
    // then ImGui's built-in font as a last resort.
    float fontPx = (float)(g_config.fontSize > 0 ? g_config.fontSize : 40);
    ImFont* font = nullptr;
    std::string fontPath = rofont::resolveFamilyToFile(g_config.fontFamily);
    if (fontPath.empty()) {
        LayerLog("Font '%s' not installed, trying fallback '%s'",
                 g_config.fontFamily.c_str(), g_config.fontFallback.c_str());
        fontPath = rofont::resolveFamilyToFile(g_config.fontFallback);
    }
    if (!fontPath.empty())
        font = io.Fonts->AddFontFromFileTTF(fontPath.c_str(), fontPx);
    if (font) {
        LayerLog("Font loaded: %s (%.0fpx)", fontPath.c_str(), fontPx);
    } else {
        ImFontConfig fc;
        fc.SizePixels = fontPx;
        io.Fonts->AddFontDefault(&fc);
        LayerLog("Using ImGui default font (%.0fpx)", fontPx);
    }

    ImGui::StyleColorsDark();

    if (!ImGui_ImplVulkan_LoadFunctions(g_apiVersion, ImguiLoader, nullptr)) {
        LayerLog("ImGui_ImplVulkan_LoadFunctions FAILED");
        return false;
    }

    uint32_t imageCount = (uint32_t)g_swapImages.size();
    ImGui_ImplVulkan_InitInfo ii = {};
    ii.ApiVersion       = g_apiVersion;
    ii.Instance         = g_instance;
    ii.PhysicalDevice   = g_physicalDevice;
    ii.Device           = g_device;
    ii.QueueFamily      = g_queueFamily;
    ii.Queue            = g_graphicsQueue;
    ii.DescriptorPool   = VK_NULL_HANDLE;
    ii.DescriptorPoolSize = 16;                         // backend creates its own pool
    ii.MinImageCount    = imageCount < 2 ? 2 : imageCount;
    ii.ImageCount       = imageCount < 2 ? 2 : imageCount;
    ii.PipelineInfoMain.RenderPass  = g_renderPass;
    ii.PipelineInfoMain.Subpass     = 0;
    ii.PipelineInfoMain.MSAASamples = VK_SAMPLE_COUNT_1_BIT;
    ii.CheckVkResultFn  = nullptr;

    if (!ImGui_ImplVulkan_Init(&ii)) {
        LayerLog("ImGui_ImplVulkan_Init FAILED");
        return false;
    }
    g_imguiReady = true;
    LayerLog("ImGui initialized (font=%dpx, images=%u)", (int)fontPx, imageCount);
    return true;
}

// ── Cleanup render resources ──────────────────────────────────────────────────
static void CleanupRender(VkDevice device) {
    auto& d = GetDeviceDispatch(device);
    if (d.DeviceWaitIdle) d.DeviceWaitIdle(device);

    ShutdownImgui();

    if (g_cmdPool && !g_cmdBuffers.empty()) {
        d.FreeCommandBuffers(device, g_cmdPool, (uint32_t)g_cmdBuffers.size(), g_cmdBuffers.data());
        g_cmdBuffers.clear();
        g_cmdRecorded.clear();
    }
    for (auto s  : g_overlaySems) d.DestroySemaphore(device, s, nullptr);
    g_overlaySems.clear();
    for (auto fb : g_framebuffers) d.DestroyFramebuffer(device, fb, nullptr);
    g_framebuffers.clear();
    for (auto iv : g_swapViews)   d.DestroyImageView(device, iv, nullptr);
    g_swapViews.clear();
    if (g_renderPass) { d.DestroyRenderPass(device, g_renderPass, nullptr); g_renderPass = VK_NULL_HANDLE; }
    if (g_cmdPool)    { d.DestroyCommandPool(device, g_cmdPool, nullptr);    g_cmdPool    = VK_NULL_HANDLE; }
    g_swapImages.clear();
    g_renderReady = false;
}

// ── Setup render resources for the current swapchain ──────────────────────────
static bool SetupRender(VkDevice device) {
    auto& d = GetDeviceDispatch(device);

    uint32_t count = 0;
    if (d.GetSwapchainImagesKHR(device, g_swapchain, &count, nullptr) != VK_SUCCESS || count == 0) {
        LayerLog("GetSwapchainImagesKHR failed/empty");
        return false;
    }
    g_swapImages.resize(count);
    d.GetSwapchainImagesKHR(device, g_swapchain, &count, g_swapImages.data());
    LayerLog("Swapchain: %u images, %ux%u, format=%d", count, g_swapExtent.width, g_swapExtent.height, g_swapFormat);

    // Render pass: LOAD existing frame, draw on top, keep it in PRESENT_SRC layout.
    VkAttachmentDescription att = {};
    att.format         = g_swapFormat;
    att.samples        = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp         = VK_ATTACHMENT_LOAD_OP_LOAD;
    att.storeOp        = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout  = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    att.finalLayout    = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference ref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub = {};
    sub.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments    = &ref;

    VkSubpassDependency dep = {};
    dep.srcSubpass    = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass    = 0;
    dep.srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.srcAccessMask = 0;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo rpci = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    rpci.attachmentCount = 1;
    rpci.pAttachments    = &att;
    rpci.subpassCount    = 1;
    rpci.pSubpasses      = &sub;
    rpci.dependencyCount = 1;
    rpci.pDependencies   = &dep;

    if (d.CreateRenderPass(device, &rpci, nullptr, &g_renderPass) != VK_SUCCESS) {
        LayerLog("CreateRenderPass FAILED");
        return false;
    }

    g_swapViews.resize(count);
    g_framebuffers.resize(count);
    for (uint32_t i = 0; i < count; i++) {
        VkImageViewCreateInfo ivci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        ivci.image    = g_swapImages[i];
        ivci.viewType = VK_IMAGE_VIEW_TYPE_2D;
        ivci.format   = g_swapFormat;
        ivci.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        if (d.CreateImageView(device, &ivci, nullptr, &g_swapViews[i]) != VK_SUCCESS) {
            LayerLog("CreateImageView[%u] FAILED", i);
            return false;
        }

        VkFramebufferCreateInfo fbci = {VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        fbci.renderPass      = g_renderPass;
        fbci.attachmentCount = 1;
        fbci.pAttachments    = &g_swapViews[i];
        fbci.width           = g_swapExtent.width;
        fbci.height          = g_swapExtent.height;
        fbci.layers          = 1;
        if (d.CreateFramebuffer(device, &fbci, nullptr, &g_framebuffers[i]) != VK_SUCCESS) {
            LayerLog("CreateFramebuffer[%u] FAILED", i);
            return false;
        }
    }

    VkCommandPoolCreateInfo cpci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cpci.flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    cpci.queueFamilyIndex = g_queueFamily;
    if (d.CreateCommandPool(device, &cpci, nullptr, &g_cmdPool) != VK_SUCCESS) {
        LayerLog("CreateCommandPool FAILED");
        return false;
    }

    g_cmdBuffers.resize(count);
    g_cmdRecorded.assign(count, false);
    VkCommandBufferAllocateInfo cbai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cbai.commandPool        = g_cmdPool;
    cbai.level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = count;
    if (AllocateLayerCommandBuffers(device, &cbai, g_cmdBuffers.data()) != VK_SUCCESS) {
        LayerLog("AllocateCommandBuffers FAILED");
        return false;
    }

    g_overlaySems.resize(count);
    for (uint32_t i = 0; i < count; i++) {
        VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        if (d.CreateSemaphore_(device, &sci, nullptr, &g_overlaySems[i]) != VK_SUCCESS) {
            LayerLog("CreateSemaphore[%u] FAILED", i);
            return false;
        }
    }

    if (!InitImgui()) return false;

    g_renderReady = true;
    LayerLog("Render resources ready (%u framebuffers)", count);
    return true;
}

// ── Build + record the overlay for one swapchain image ────────────────────────
// `alpha` is the fade multiplier (0..1) from MessageAlpha — applied to both the
// panel background and the text, mirroring the AHK whole-window alpha fade.
static void DrawOverlay(VkCommandBuffer cmd, float alpha) {
    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)g_swapExtent.width, (float)g_swapExtent.height);

    ULONGLONG now = GetTickCount64();
    float dt = g_lastPresentTick ? (now - g_lastPresentTick) / 1000.0f : (1.0f / 60.0f);
    if (dt <= 0.0f) dt = 1.0f / 60.0f;
    io.DeltaTime = dt;
    g_lastPresentTick = now;

    ImGui_ImplVulkan_NewFrame();
    ImGui::NewFrame();

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs |
                             ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoSavedSettings |
                             ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoFocusOnAppearing |
                             ImGuiWindowFlags_NoMove;

    // Parity: AHK/PS place the overlay's TOP edge at height*VerticalPercent,
    // horizontally centered (pivot 0.5, 0.0 — not centered on the y line).
    ImVec2 pos(io.DisplaySize.x * 0.5f, io.DisplaySize.y * g_config.verticalPercent);
    ImGui::SetNextWindowPos(pos, ImGuiCond_Always, ImVec2(0.5f, 0.0f));

    // Single line auto-sized like AHK/WPF, but clamped to the frame (a game
    // frame has hard edges, unlike a top-level window) — wrap past the clamp.
    float maxW = io.DisplaySize.x * 0.92f;
    ImGui::SetNextWindowSizeConstraints(ImVec2(0, 0), ImVec2(maxW, FLT_MAX));

    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(12.0f, 8.0f)); // AHK Gui Margin 12,8
    ImGui::PushStyleColor(ImGuiCol_WindowBg,
        ImVec4(g_config.bgColor[0], g_config.bgColor[1], g_config.bgColor[2], g_config.bgAlpha * alpha));
    ImGui::PushStyleColor(ImGuiCol_Text,
        ImVec4(g_config.overlayColor[0], g_config.overlayColor[1], g_config.overlayColor[2], alpha));
    ImGui::PushStyleColor(ImGuiCol_Border, ImVec4(0, 0, 0, 0));

    ImGui::Begin("##randoverlay", nullptr, flags);
    ImGui::PushTextWrapPos(maxW - 24.0f); // wrap inside the clamped width
    ImGui::TextUnformatted(g_currentMessage.c_str());
    ImGui::PopTextWrapPos();
    ImGui::End();

    ImGui::PopStyleColor(3);
    ImGui::PopStyleVar();

    ImGui::Render();
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), cmd);
}

// ── Hooked: vkCreateInstance ──────────────────────────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_CreateInstance(
    const VkInstanceCreateInfo* pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkInstance* pInstance)
{
    auto* layerInfo = (VkLayerInstanceCreateInfo*)pCreateInfo->pNext;
    while (layerInfo && !(layerInfo->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO &&
                          layerInfo->function == VK_LAYER_LINK_INFO)) {
        layerInfo = (VkLayerInstanceCreateInfo*)layerInfo->pNext;
    }
    if (!layerInfo) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr gipa = layerInfo->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    layerInfo->u.pLayerInfo = layerInfo->u.pLayerInfo->pNext; // advance chain

    auto createInstance = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    VkResult result = createInstance(pCreateInfo, pAllocator, pInstance);
    if (result != VK_SUCCESS) return result;

    InitInstanceDispatch(*pInstance, gipa);
    g_nextGIPA = gipa;
    g_instance = *pInstance;
    if (pCreateInfo->pApplicationInfo && pCreateInfo->pApplicationInfo->apiVersion)
        g_apiVersion = pCreateInfo->pApplicationInfo->apiVersion;

    // Load config early so the process gate can consult it.
    g_config.load();

    // Environment kill-switch (also declared in the layer manifest).
    const char* off = getenv("DISABLE_RANDOVERLAY");
    bool envOff = (off && strcmp(off, "1") == 0);
    bool targeted = rogate::isTargetProcess(g_config.emulatorProcs);
    g_disabled = envOff || !targeted;

    LayerLog("=== RandOverlay Layer loaded ===");
    LayerLog("vkCreateInstance OK, instance=0x%p", (void*)*pInstance);
    LayerLog("process=%s, ini=%s, preset=%s, disabled=%d (envOff=%d, targeted=%d)",
             rogate::currentProcessExeLower().c_str(),
             g_config.iniPathUsed.empty() ? "(defaults)" : g_config.iniPathUsed.c_str(),
             g_config.activePreset.c_str(), (int)g_disabled, (int)envOff, (int)targeted);

    if (!g_disabled && !g_logReader) {
        g_logReader = new LogReader(g_config.logDir);
        LayerLog("Log reader initialized (logDir=%s)", g_config.logDir.c_str());
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
    auto* loaderDataInfo = (VkLayerDeviceCreateInfo*)pCreateInfo->pNext;
    while (loaderDataInfo &&
           !(loaderDataInfo->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
             loaderDataInfo->function == VK_LOADER_DATA_CALLBACK)) {
        loaderDataInfo = (VkLayerDeviceCreateInfo*)loaderDataInfo->pNext;
    }
    g_setDeviceLoaderData = loaderDataInfo ? loaderDataInfo->u.pfnSetDeviceLoaderData : nullptr;

    auto* layerInfo = (VkLayerDeviceCreateInfo*)pCreateInfo->pNext;
    while (layerInfo && !(layerInfo->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO &&
                          layerInfo->function == VK_LAYER_LINK_INFO)) {
        layerInfo = (VkLayerDeviceCreateInfo*)layerInfo->pNext;
    }
    if (!layerInfo) return VK_ERROR_INITIALIZATION_FAILED;

    PFN_vkGetInstanceProcAddr gipa = layerInfo->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr   gdpa = layerInfo->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    layerInfo->u.pLayerInfo = layerInfo->u.pLayerInfo->pNext; // advance chain

    auto createDevice = (PFN_vkCreateDevice)gipa(VK_NULL_HANDLE, "vkCreateDevice");
    VkResult result = createDevice(physDevice, pCreateInfo, pAllocator, pDevice);
    if (result != VK_SUCCESS) return result;

    InitDeviceDispatch(*pDevice, gdpa);
    g_nextGDPA       = gdpa;
    g_device         = *pDevice;
    g_physicalDevice = physDevice;

    if (pCreateInfo->queueCreateInfoCount > 0)
        g_queueFamily = pCreateInfo->pQueueCreateInfos[0].queueFamilyIndex;

    // Retrieve a concrete queue from the (graphics) family used for the pool/submits.
    auto& d = GetDeviceDispatch(*pDevice);
    if (d.GetDeviceQueue) d.GetDeviceQueue(*pDevice, g_queueFamily, 0, &g_graphicsQueue);

    LayerLog("vkCreateDevice OK, device=0x%p, queueFamily=%u, queue=0x%p",
             (void*)*pDevice, g_queueFamily, (void*)g_graphicsQueue);
    return VK_SUCCESS;
}

// ── Hooked: vkCreateSwapchainKHR ──────────────────────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_CreateSwapchainKHR(
    VkDevice device,
    const VkSwapchainCreateInfoKHR* pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkSwapchainKHR* pSwapchain)
{
    LayerLog("vkCreateSwapchainKHR entry (%ux%u format=%d oldSwapchain=0x%p)",
             pCreateInfo->imageExtent.width, pCreateInfo->imageExtent.height,
             pCreateInfo->imageFormat, (void*)pCreateInfo->oldSwapchain);

    if (g_renderReady) CleanupRender(device); // resolution / fullscreen toggle etc.

    auto& d = GetDeviceDispatch(device);
    VkResult result = d.CreateSwapchainKHR(device, pCreateInfo, pAllocator, pSwapchain);
    if (result != VK_SUCCESS) { LayerLog("real CreateSwapchainKHR failed: %d", result); return result; }

    g_swapchain  = *pSwapchain;
    g_swapFormat = pCreateInfo->imageFormat;
    g_swapExtent = pCreateInfo->imageExtent;
    g_device     = device;

    if (!g_disabled) {
        if (!SetupRender(device)) {
            LayerLog("SetupRender failed — overlay disabled, passing through");
            CleanupRender(device); // never break the game
        } else if (!g_readyMessageShown) {
            // Parity: AHK/PS show a one-time startup notification.
            g_readyMessageShown = true;
            g_currentMessage = "Archipelago Overlay ready - waiting for events";
            g_messageTimestamp = GetTickCount64();
            // Parity with the AHK startup check: offer to launch Archipelago
            // if it isn't running (non-blocking; RANDOVERLAY_NO_PROMPT=1 skips).
            roarch::promptIfNotRunning(g_config.launcherExe,
                                       g_config.activePreset,
                                       g_config.clientComponent);
        }
    }
    return VK_SUCCESS;
}

// ── Hooked: vkQueuePresentKHR ─────────────────────────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_QueuePresentKHR(
    VkQueue queue,
    const VkPresentInfoKHR* pPresentInfo)
{
    auto& d = GetDeviceDispatch(queue); // queue shares the device's dispatch key

    static bool s_qpFirst = true;
    if (s_qpFirst) { s_qpFirst = false;
        LayerLog("QueuePresentKHR hook LIVE (g_logReader=%p disabled=%d)", (void*)g_logReader, (int)g_disabled); }

    // Poll for new messages at PollMs cadence (parity with AHK/PS — not per frame).
    ULONGLONG now = GetTickCount64();
    if (!g_disabled && g_logReader && (now - g_lastPollTick) >= (ULONGLONG)g_config.pollMs) {
        g_lastPollTick = now;
        std::string before = g_logReader->currentLogFile();
        auto msgs = g_logReader->poll();
        if (g_logReader->currentLogFile() != before)
            LayerLog("Log switched: %s", g_logReader->currentLogFile().c_str());
        if (!msgs.empty()) {
            g_currentMessage = msgs.back().text;
            g_messageTimestamp = now;
            LayerLog("Message: %s", g_currentMessage.c_str());
        }
    }

    float msgAlpha = MessageAlpha(now); // also clears the message once fully faded
    bool haveOverlay = g_renderReady && g_imguiReady && msgAlpha > 0.0f;

    // Only the simple, common single-swapchain case is decorated; otherwise pass through.
    if (haveOverlay && pPresentInfo->swapchainCount == 1 &&
        pPresentInfo->pSwapchains[0] == g_swapchain) {
        uint32_t idx = pPresentInfo->pImageIndices[0];
        if (idx < g_cmdBuffers.size()) {
            VkCommandBuffer cmd = g_cmdBuffers[idx];
            if (g_cmdRecorded[idx]) {
                d.ResetCommandBuffer(cmd, 0);
            }

            VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
            bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            d.BeginCommandBuffer(cmd, &bi);

            VkRenderPassBeginInfo rpbi = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
            rpbi.renderPass        = g_renderPass;
            rpbi.framebuffer       = g_framebuffers[idx];
            rpbi.renderArea.extent = g_swapExtent;
            d.CmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);

            DrawOverlay(cmd, msgAlpha);

            d.CmdEndRenderPass(cmd);
            d.EndCommandBuffer(cmd);
            g_cmdRecorded[idx] = true;

            // Our submit waits on the app's present-wait semaphores, signals ours;
            // present then waits only on ours.
            std::vector<VkPipelineStageFlags> waitStages(
                pPresentInfo->waitSemaphoreCount, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
            VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
            si.waitSemaphoreCount   = pPresentInfo->waitSemaphoreCount;
            si.pWaitSemaphores      = pPresentInfo->pWaitSemaphores;
            si.pWaitDstStageMask    = waitStages.empty() ? nullptr : waitStages.data();
            si.commandBufferCount   = 1;
            si.pCommandBuffers      = &cmd;
            si.signalSemaphoreCount = 1;
            si.pSignalSemaphores    = &g_overlaySems[idx];

            if (d.QueueSubmit(queue, 1, &si, VK_NULL_HANDLE) == VK_SUCCESS) {
                VkPresentInfoKHR mod = *pPresentInfo;
                mod.waitSemaphoreCount = 1;
                mod.pWaitSemaphores    = &g_overlaySems[idx];
                VkResult presentResult = d.QueuePresentKHR(queue, &mod);
                return presentResult;
            }
            LayerLog("overlay QueueSubmit failed — passing through");
        }
    }

    return d.QueuePresentKHR(queue, pPresentInfo);
}

// ── Hooked: vkDestroyDevice ───────────────────────────────────────────────────
VK_LAYER_EXPORT void VKAPI_CALL RandOverlay_DestroyDevice(
    VkDevice device, const VkAllocationCallbacks* pAllocator)
{
    LayerLog("vkDestroyDevice");
    if (g_renderReady) CleanupRender(device);
    auto& d = GetDeviceDispatch(device);
    d.DestroyDevice(device, pAllocator);

    std::lock_guard<std::mutex> lock(g_dispatchMutex);
    g_deviceDispatch.erase(GetDispatchKey(device));
    g_device = VK_NULL_HANDLE;
    g_graphicsQueue = VK_NULL_HANDLE;
}

// ── Hooked: vkDestroyInstance ─────────────────────────────────────────────────
VK_LAYER_EXPORT void VKAPI_CALL RandOverlay_DestroyInstance(
    VkInstance instance, const VkAllocationCallbacks* pAllocator)
{
    LayerLog("vkDestroyInstance");
    delete g_logReader;
    g_logReader = nullptr;

    auto& d = GetInstanceDispatch(instance);
    d.DestroyInstance(instance, pAllocator);

    {
        std::lock_guard<std::mutex> lock(g_dispatchMutex);
        g_instanceDispatch.erase(GetDispatchKey(instance));
    }
    g_instance = VK_NULL_HANDLE;
    if (g_log) { fclose(g_log); g_log = nullptr; }
}

// ── Layer entry points ────────────────────────────────────────────────────────
#define GETPROCADDR(name) if (strcmp(pName, "vk" #name) == 0) return (PFN_vkVoidFunction)&RandOverlay_##name

VK_LAYER_EXPORT PFN_vkVoidFunction VKAPI_CALL RandOverlay_GetDeviceProcAddr(
    VkDevice device, const char* pName)
{
    // A layer MUST return its own GetDeviceProcAddr here, or the loader/app will
    // resolve the chain past us and our device hooks (QueuePresentKHR!) get bypassed.
    GETPROCADDR(GetDeviceProcAddr);
    GETPROCADDR(QueuePresentKHR);
    GETPROCADDR(CreateSwapchainKHR);
    GETPROCADDR(DestroyDevice);

    auto& d = GetDeviceDispatch(device);
    if (!d.GetDeviceProcAddr) return nullptr;
    return d.GetDeviceProcAddr(device, pName);
}

VK_LAYER_EXPORT PFN_vkVoidFunction VKAPI_CALL RandOverlay_GetInstanceProcAddr(
    VkInstance instance, const char* pName)
{
    GETPROCADDR(GetInstanceProcAddr); // must return our own, same rule as GDPA
    GETPROCADDR(CreateInstance);
    GETPROCADDR(CreateDevice);
    GETPROCADDR(DestroyInstance);
    // Device-level functions may also be queried through the instance.
    GETPROCADDR(QueuePresentKHR);
    GETPROCADDR(CreateSwapchainKHR);
    GETPROCADDR(DestroyDevice);
    GETPROCADDR(GetDeviceProcAddr);

    if (instance == VK_NULL_HANDLE) return nullptr;
    auto& d = GetInstanceDispatch(instance);
    if (!d.GetInstanceProcAddr) return nullptr;
    return d.GetInstanceProcAddr(instance, pName);
}

// ── Negotiate loader<->layer interface (required) ─────────────────────────────
VK_LAYER_EXPORT VkResult VKAPI_CALL RandOverlay_NegotiateLoaderLayerInterfaceVersion(
    VkNegotiateLayerInterface* pVersionStruct)
{
    if (pVersionStruct->loaderLayerInterfaceVersion >= 2) {
        pVersionStruct->pfnGetInstanceProcAddr       = RandOverlay_GetInstanceProcAddr;
        pVersionStruct->pfnGetDeviceProcAddr         = RandOverlay_GetDeviceProcAddr;
        pVersionStruct->pfnGetPhysicalDeviceProcAddr = nullptr;
    }
    pVersionStruct->loaderLayerInterfaceVersion = 2;
    return VK_SUCCESS;
}
