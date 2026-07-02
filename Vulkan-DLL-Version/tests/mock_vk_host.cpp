/*
 * RandOverlay mock Vulkan host — a "fake emulator" for VISUALLY testing the
 * implicit layer without RPCS3/PCSX2.
 *
 * It opens a window and runs a real Vulkan present loop (instance -> device ->
 * swapchain -> render pass clear -> queue present) with an animated background.
 * Because the RandOverlay layer is a GLOBAL implicit layer, once it is
 * registered it loads into THIS process too and draws the overlay on top — so a
 * desktop screenshot of this window shows the exact overlay path RPCS3 would use.
 *
 * IMPORTANT: build this AS `rpcs3.exe` so the layer's process gate activates.
 * Point the layer at a test log via the RANDOVERLAY_INI env var.
 *
 * Auto-exits after ~30s (safety) or on window close.
 */
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define VK_USE_PLATFORM_WIN32_KHR
#include <windows.h>
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>

#define VK_CHECK(x) do { VkResult _r = (x); if (_r != VK_SUCCESS) { \
    printf("[mock] VK_CHECK failed (%d) at %s:%d\n", _r, __FILE__, __LINE__); fflush(stdout); \
    exit(2); } } while (0)

static HWND        g_hwnd = nullptr;
static bool        g_quit = false;
static VkExtent2D  g_extent = { 960, 540 };

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_CLOSE || m == WM_DESTROY) { g_quit = true; PostQuitMessage(0); return 0; }
    return DefWindowProc(h, m, w, l);
}

int main() {
    printf("[mock] pid=%lu starting Vulkan present loop\n", GetCurrentProcessId()); fflush(stdout);

    // ── Win32 window ──────────────────────────────────────────────────────
    HINSTANCE hinst = GetModuleHandle(nullptr);
    WNDCLASSA wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = "RandOverlayMockHost";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassA(&wc);
    g_hwnd = CreateWindowExA(0, wc.lpszClassName, "RandOverlay Mock Host (fake rpcs3)",
                             WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
                             120, 120, (int)g_extent.width, (int)g_extent.height,
                             nullptr, nullptr, hinst, nullptr);
    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);
    // Keep the mock window visible on top for screenshot capture.
    SetWindowPos(g_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
    SetForegroundWindow(g_hwnd);

    // ── Instance ──────────────────────────────────────────────────────────
    const char* instExt[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME };
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO };
    app.pApplicationName = "RandOverlayMockHost";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO };
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = instExt;
    VkInstance instance;
    VK_CHECK(vkCreateInstance(&ici, nullptr, &instance));
    printf("[mock] instance created\n"); fflush(stdout);

    // ── Surface ───────────────────────────────────────────────────────────
    VkWin32SurfaceCreateInfoKHR sci = { VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR };
    sci.hinstance = hinst;
    sci.hwnd = g_hwnd;
    VkSurfaceKHR surface;
    VK_CHECK(vkCreateWin32SurfaceKHR(instance, &sci, nullptr, &surface));

    // ── Physical device + graphics/present queue family ───────────────────
    uint32_t pdCount = 0; vkEnumeratePhysicalDevices(instance, &pdCount, nullptr);
    std::vector<VkPhysicalDevice> pds(pdCount);
    vkEnumeratePhysicalDevices(instance, &pdCount, pds.data());
    if (pdCount == 0) { printf("[mock] no Vulkan device\n"); return 2; }
    VkPhysicalDevice phys = pds[0];
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(phys, &props);
    printf("[mock] GPU: %s\n", props.deviceName); fflush(stdout);

    uint32_t qfCount = 0; vkGetPhysicalDeviceQueueFamilyProperties(phys, &qfCount, nullptr);
    std::vector<VkQueueFamilyProperties> qfp(qfCount);
    vkGetPhysicalDeviceQueueFamilyProperties(phys, &qfCount, qfp.data());
    uint32_t qFamily = UINT32_MAX;
    for (uint32_t i = 0; i < qfCount; i++) {
        VkBool32 present = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(phys, i, surface, &present);
        if ((qfp[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) { qFamily = i; break; }
    }
    if (qFamily == UINT32_MAX) { printf("[mock] no graphics+present queue\n"); return 2; }

    // ── Device + queue ────────────────────────────────────────────────────
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO };
    qci.queueFamilyIndex = qFamily; qci.queueCount = 1; qci.pQueuePriorities = &prio;
    const char* devExt[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO };
    dci.queueCreateInfoCount = 1; dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 1; dci.ppEnabledExtensionNames = devExt;
    VkDevice device;
    VK_CHECK(vkCreateDevice(phys, &dci, nullptr, &device));
    VkQueue queue; vkGetDeviceQueue(device, qFamily, 0, &queue);
    printf("[mock] device + queue ready (family %u)\n", qFamily); fflush(stdout);

    // ── Swapchain ─────────────────────────────────────────────────────────
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys, surface, &caps);
    if (caps.currentExtent.width != UINT32_MAX) g_extent = caps.currentExtent;
    uint32_t fmtCount = 0; vkGetPhysicalDeviceSurfaceFormatsKHR(phys, surface, &fmtCount, nullptr);
    std::vector<VkSurfaceFormatKHR> fmts(fmtCount);
    vkGetPhysicalDeviceSurfaceFormatsKHR(phys, surface, &fmtCount, fmts.data());
    VkSurfaceFormatKHR sf = fmts[0];
    for (auto& f : fmts) if (f.format == VK_FORMAT_B8G8R8A8_UNORM) { sf = f; break; }

    uint32_t imgCount = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && imgCount > caps.maxImageCount) imgCount = caps.maxImageCount;

    VkSwapchainCreateInfoKHR scci = { VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
    scci.surface = surface;
    scci.minImageCount = imgCount;
    scci.imageFormat = sf.format;
    scci.imageColorSpace = sf.colorSpace;
    scci.imageExtent = g_extent;
    scci.imageArrayLayers = 1;
    scci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    scci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    scci.preTransform = caps.currentTransform;
    scci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    scci.presentMode = VK_PRESENT_MODE_FIFO_KHR; // always supported
    scci.clipped = VK_TRUE;
    VkSwapchainKHR swap;
    VK_CHECK(vkCreateSwapchainKHR(device, &scci, nullptr, &swap));

    uint32_t scImgCount = 0; vkGetSwapchainImagesKHR(device, swap, &scImgCount, nullptr);
    std::vector<VkImage> images(scImgCount);
    vkGetSwapchainImagesKHR(device, swap, &scImgCount, images.data());
    printf("[mock] swapchain: %u images %ux%u fmt=%d\n", scImgCount, g_extent.width, g_extent.height, sf.format);
    fflush(stdout);

    // Image views
    std::vector<VkImageView> views(scImgCount);
    for (uint32_t i = 0; i < scImgCount; i++) {
        VkImageViewCreateInfo ivci = { VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO };
        ivci.image = images[i]; ivci.viewType = VK_IMAGE_VIEW_TYPE_2D; ivci.format = sf.format;
        ivci.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
        VK_CHECK(vkCreateImageView(device, &ivci, nullptr, &views[i]));
    }

    // Render pass (clear -> present-src, so the layer's PRESENT_SRC render pass is valid)
    VkAttachmentDescription att = {};
    att.format = sf.format; att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR; att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE; att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED; att.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference ref = { 0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription sub = {}; sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1; sub.pColorAttachments = &ref;
    VkRenderPassCreateInfo rpci = { VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO };
    rpci.attachmentCount = 1; rpci.pAttachments = &att; rpci.subpassCount = 1; rpci.pSubpasses = &sub;
    VkRenderPass rp; VK_CHECK(vkCreateRenderPass(device, &rpci, nullptr, &rp));

    std::vector<VkFramebuffer> fbs(scImgCount);
    for (uint32_t i = 0; i < scImgCount; i++) {
        VkFramebufferCreateInfo fbci = { VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO };
        fbci.renderPass = rp; fbci.attachmentCount = 1; fbci.pAttachments = &views[i];
        fbci.width = g_extent.width; fbci.height = g_extent.height; fbci.layers = 1;
        VK_CHECK(vkCreateFramebuffer(device, &fbci, nullptr, &fbs[i]));
    }

    // Command pool + buffers
    VkCommandPoolCreateInfo cpci = { VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO };
    cpci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT; cpci.queueFamilyIndex = qFamily;
    VkCommandPool pool; VK_CHECK(vkCreateCommandPool(device, &cpci, nullptr, &pool));
    std::vector<VkCommandBuffer> cmds(scImgCount);
    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = pool; cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; cbai.commandBufferCount = scImgCount;
    VK_CHECK(vkAllocateCommandBuffers(device, &cbai, cmds.data()));

    // Sync (single frame in flight; vkQueueWaitIdle each frame keeps it simple + correct)
    VkSemaphore imgAvail, renderDone;
    VkSemaphoreCreateInfo semci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VK_CHECK(vkCreateSemaphore(device, &semci, nullptr, &imgAvail));
    VK_CHECK(vkCreateSemaphore(device, &semci, nullptr, &renderDone));

    const char* secEnv = getenv("MOCK_SECONDS");
    DWORD limitMs = (secEnv && atoi(secEnv) > 0) ? (DWORD)atoi(secEnv) * 1000 : 30000;
    printf("[mock] entering present loop (runtime %lus)\n", limitMs / 1000); fflush(stdout);
    DWORD start = GetTickCount();
    uint32_t frame = 0;

    while (!g_quit) {
        MSG msg;
        while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessage(&msg); }
        if (GetTickCount() - start > limitMs) break; // safety auto-exit

        uint32_t idx = 0;
        VkResult acq = vkAcquireNextImageKHR(device, swap, UINT64_MAX, imgAvail, VK_NULL_HANDLE, &idx);
        if (acq == VK_ERROR_OUT_OF_DATE_KHR) break;

        // animated clear colour (slow hue sweep) so frames visibly change
        float t = frame * 0.01f;
        VkClearValue clear;
        clear.color.float32[0] = 0.25f + 0.20f * sinf(t);
        clear.color.float32[1] = 0.30f + 0.20f * sinf(t + 2.0f);
        clear.color.float32[2] = 0.45f + 0.20f * sinf(t + 4.0f);
        clear.color.float32[3] = 1.0f;

        VkCommandBuffer cmd = cmds[idx];
        vkResetCommandBuffer(cmd, 0);
        VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        vkBeginCommandBuffer(cmd, &bi);
        VkRenderPassBeginInfo rpbi = { VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO };
        rpbi.renderPass = rp; rpbi.framebuffer = fbs[idx];
        rpbi.renderArea.extent = g_extent; rpbi.clearValueCount = 1; rpbi.pClearValues = &clear;
        vkCmdBeginRenderPass(cmd, &rpbi, VK_SUBPASS_CONTENTS_INLINE);
        vkCmdEndRenderPass(cmd);
        vkEndCommandBuffer(cmd);

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
        si.waitSemaphoreCount = 1; si.pWaitSemaphores = &imgAvail; si.pWaitDstStageMask = &waitStage;
        si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
        si.signalSemaphoreCount = 1; si.pSignalSemaphores = &renderDone;
        VK_CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));

        // The RandOverlay layer intercepts this present, waits on renderDone,
        // draws its ImGui text, and re-points present at its own semaphore.
        VkPresentInfoKHR pi = { VK_STRUCTURE_TYPE_PRESENT_INFO_KHR };
        pi.waitSemaphoreCount = 1; pi.pWaitSemaphores = &renderDone;
        pi.swapchainCount = 1; pi.pSwapchains = &swap; pi.pImageIndices = &idx;
        VkResult pr = vkQueuePresentKHR(queue, &pi);
        if (pr == VK_ERROR_OUT_OF_DATE_KHR) break;

        vkQueueWaitIdle(queue);
        frame++;
    }

    printf("[mock] exiting after %u frames\n", frame); fflush(stdout);
    vkDeviceWaitIdle(device);
    return 0;
}
