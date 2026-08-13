/*
 * RandOverlay mock Vulkan host — a "fake emulator" for testing the implicit
 * layer without RPCS3/PCSX2.
 *
 * It opens a window and runs a real Vulkan present loop (instance -> device ->
 * swapchain -> render pass clear -> queue present) with an animated background.
 * Because the RandOverlay layer is a GLOBAL implicit layer, once it is
 * registered it loads into THIS process too and draws the overlay on top — so a
 * screenshot of this window shows the exact overlay path RPCS3 would use.
 *
 * IMPORTANT: build this AS `rpcs3` / `rpcs3.exe` so the layer's process gate
 * activates. Point the layer at a test log via the RANDOVERLAY_INI env var.
 *
 * Windows uses a Win32 window + VK_KHR_win32_surface; Linux uses xcb +
 * VK_KHR_xcb_surface, which runs fine under Xvfb for headless CI.
 *
 * Env vars:
 *   MOCK_SECONDS=<n>        runtime cap (default 30)
 *   MOCK_WINDOW_MODE=borderless
 *   MOCK_STATIC_FRAME=1     freeze the clear colour (required for readback)
 *   MOCK_READBACK=1         copy the presented image back and report overlay
 *                           pixel coverage — the headless equivalent of the
 *                           Windows screenshot assertion
 *   MOCK_READBACK_PPM=<p>   also dump that frame as a binary PPM
 *
 * Auto-exits after MOCK_SECONDS or on window close.
 */
#if defined(_WIN32)
  #define WIN32_LEAN_AND_MEAN
  #define NOMINMAX
  #define VK_USE_PLATFORM_WIN32_KHR
  #include <windows.h>
#else
  #define VK_USE_PLATFORM_XCB_KHR
  #include <xcb/xcb.h>
  #include <unistd.h>
#endif

#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <chrono>
#include <vector>

#define VK_CHECK(x) do { VkResult _r = (x); if (_r != VK_SUCCESS) { \
    printf("[mock] VK_CHECK failed (%d) at %s:%d\n", _r, __FILE__, __LINE__); fflush(stdout); \
    exit(2); } } while (0)

static bool       g_quit   = false;
static VkExtent2D g_extent = { 960, 540 };

static bool envIs(const char* name, const char* value) {
    const char* v = getenv(name);
    return v && strcmp(v, value) == 0;
}

static uint64_t nowMs() {
    using namespace std::chrono;
    return (uint64_t)duration_cast<milliseconds>(
        steady_clock::now().time_since_epoch()).count();
}

// ── Platform window ───────────────────────────────────────────────────────────
#if defined(_WIN32)

static HWND g_hwnd = nullptr;

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_CLOSE || m == WM_DESTROY) { g_quit = true; PostQuitMessage(0); return 0; }
    return DefWindowProc(h, m, w, l);
}

static void CreateHostWindow(bool borderless) {
    HINSTANCE hinst = GetModuleHandle(nullptr);
    WNDCLASSA wc = {};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = "RandOverlayMockHost";
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassA(&wc);
    DWORD windowStyle = borderless ? WS_POPUP : (WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX);
    int windowX = borderless ? 0 : 120;
    int windowY = borderless ? 0 : 120;
    int windowW = borderless ? GetSystemMetrics(SM_CXSCREEN) : (int)g_extent.width;
    int windowH = borderless ? GetSystemMetrics(SM_CYSCREEN) : (int)g_extent.height;
    g_hwnd = CreateWindowExA(0, wc.lpszClassName, "RandOverlay Mock Host",
                             windowStyle, windowX, windowY, windowW, windowH,
                             nullptr, nullptr, hinst, nullptr);
    ShowWindow(g_hwnd, SW_SHOW);
    UpdateWindow(g_hwnd);
    // Keep the mock window visible on top for screenshot capture.
    SetWindowPos(g_hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
    SetForegroundWindow(g_hwnd);
    RECT r = {};
    GetWindowRect(g_hwnd, &r);
    printf("[mock-meta] ready=1 hwnd=0x%p mode=%s x=%ld y=%ld width=%ld height=%ld\n",
           (void*)g_hwnd, borderless ? "borderless" : "windowed",
           r.left, r.top, r.right - r.left, r.bottom - r.top);
    fflush(stdout);
}

static void PumpEvents() {
    MSG msg;
    while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessage(&msg); }
}

static const char* PlatformSurfaceExtension() { return VK_KHR_WIN32_SURFACE_EXTENSION_NAME; }

static VkSurfaceKHR CreateHostSurface(VkInstance instance) {
    VkWin32SurfaceCreateInfoKHR sci = { VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR };
    sci.hinstance = GetModuleHandle(nullptr);
    sci.hwnd = g_hwnd;
    VkSurfaceKHR surface;
    VK_CHECK(vkCreateWin32SurfaceKHR(instance, &sci, nullptr, &surface));
    return surface;
}

static uint32_t CurrentPid() { return (uint32_t)GetCurrentProcessId(); }

#else // ── POSIX / xcb ────────────────────────────────────────────────────────

static xcb_connection_t* g_conn = nullptr;
static xcb_window_t      g_win  = 0;

static void CreateHostWindow(bool borderless) {
    int screenNum = 0;
    g_conn = xcb_connect(nullptr, &screenNum);
    if (!g_conn || xcb_connection_has_error(g_conn)) {
        printf("[mock] cannot connect to an X server (DISPLAY=%s). Run under "
               "xvfb-run for headless use.\n", getenv("DISPLAY") ? getenv("DISPLAY") : "<unset>");
        fflush(stdout);
        exit(2);
    }

    const xcb_setup_t* setup = xcb_get_setup(g_conn);
    xcb_screen_iterator_t it = xcb_setup_roots_iterator(setup);
    for (int i = 0; i < screenNum; i++) xcb_screen_next(&it);
    xcb_screen_t* screen = it.data;

    uint32_t width  = borderless ? screen->width_in_pixels  : g_extent.width;
    uint32_t height = borderless ? screen->height_in_pixels : g_extent.height;

    g_win = xcb_generate_id(g_conn);
    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint32_t values[2] = { screen->black_pixel,
                           XCB_EVENT_MASK_EXPOSURE | XCB_EVENT_MASK_STRUCTURE_NOTIFY };
    xcb_create_window(g_conn, XCB_COPY_FROM_PARENT, g_win, screen->root,
                      0, 0, (uint16_t)width, (uint16_t)height, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, mask, values);

    const char* title = "RandOverlay Mock Host";
    xcb_change_property(g_conn, XCB_PROP_MODE_REPLACE, g_win, XCB_ATOM_WM_NAME,
                        XCB_ATOM_STRING, 8, (uint32_t)strlen(title), title);

    xcb_map_window(g_conn, g_win);
    xcb_flush(g_conn);

    g_extent.width = width;
    g_extent.height = height;
    printf("[mock-meta] ready=1 window=0x%x mode=%s x=0 y=0 width=%u height=%u\n",
           (unsigned)g_win, borderless ? "borderless" : "windowed", width, height);
    fflush(stdout);
}

static void PumpEvents() {
    xcb_generic_event_t* ev;
    while ((ev = xcb_poll_for_event(g_conn)) != nullptr) {
        // Nothing to react to: the window is never resized and closing is
        // driven by the runtime cap. Just drain so the queue cannot grow.
        free(ev);
    }
}

static const char* PlatformSurfaceExtension() { return VK_KHR_XCB_SURFACE_EXTENSION_NAME; }

static VkSurfaceKHR CreateHostSurface(VkInstance instance) {
    VkXcbSurfaceCreateInfoKHR sci = { VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR };
    sci.connection = g_conn;
    sci.window = g_win;
    VkSurfaceKHR surface;
    VK_CHECK(vkCreateXcbSurfaceKHR(instance, &sci, nullptr, &surface));
    return surface;
}

static uint32_t CurrentPid() { return (uint32_t)getpid(); }

#endif // _WIN32

// ── Presented-image readback ──────────────────────────────────────────────────
// The headless counterpart of the Windows screenshot assertion: copy the image
// the layer just drew into back to host memory and measure how much of the
// overlay band differs from the clear colour. Requires MOCK_STATIC_FRAME=1 so
// the clear colour is a known constant.
struct Readback {
    VkBuffer       buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkCommandBuffer cmd   = VK_NULL_HANDLE;
    bool           ready  = false;
};

static uint32_t FindMemoryType(VkPhysicalDevice phys, uint32_t typeBits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(phys, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((typeBits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want)
            return i;
    return UINT32_MAX;
}

static bool InitReadback(Readback& rb, VkPhysicalDevice phys, VkDevice device,
                         VkCommandPool pool, VkDeviceSize bytes) {
    VkBufferCreateInfo bci = { VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO };
    bci.size = bytes;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    bci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(device, &bci, nullptr, &rb.buffer) != VK_SUCCESS) return false;

    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(device, rb.buffer, &mr);
    uint32_t type = FindMemoryType(phys, mr.memoryTypeBits,
                                   VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                   VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (type == UINT32_MAX) return false;

    VkMemoryAllocateInfo mai = { VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO };
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = type;
    if (vkAllocateMemory(device, &mai, nullptr, &rb.memory) != VK_SUCCESS) return false;
    vkBindBufferMemory(device, rb.buffer, rb.memory, 0);

    VkCommandBufferAllocateInfo cbai = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO };
    cbai.commandPool = pool;
    cbai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cbai.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(device, &cbai, &rb.cmd) != VK_SUCCESS) return false;

    rb.ready = true;
    return true;
}

// Copies swapchain image `img` to the staging buffer and returns mapped RGBA.
static const uint8_t* CaptureImage(Readback& rb, VkDevice device, VkQueue queue,
                                   VkImage img, VkExtent2D extent) {
    vkResetCommandBuffer(rb.cmd, 0);
    VkCommandBufferBeginInfo bi = { VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(rb.cmd, &bi);

    VkImageMemoryBarrier toSrc = { VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER };
    toSrc.oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    toSrc.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    toSrc.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toSrc.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    toSrc.image = img;
    toSrc.subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 };
    toSrc.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT;
    toSrc.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(rb.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &toSrc);

    VkBufferImageCopy copy = {};
    copy.imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 };
    copy.imageExtent = { extent.width, extent.height, 1 };
    vkCmdCopyImageToBuffer(rb.cmd, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb.buffer, 1, &copy);

    VkImageMemoryBarrier back = toSrc;
    back.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    back.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    back.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    back.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
    vkCmdPipelineBarrier(rb.cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &back);

    vkEndCommandBuffer(rb.cmd);

    VkSubmitInfo si = { VK_STRUCTURE_TYPE_SUBMIT_INFO };
    si.commandBufferCount = 1;
    si.pCommandBuffers = &rb.cmd;
    VK_CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    vkQueueWaitIdle(queue);

    void* mapped = nullptr;
    if (vkMapMemory(device, rb.memory, 0, VK_WHOLE_SIZE, 0, &mapped) != VK_SUCCESS) return nullptr;
    return (const uint8_t*)mapped;
}

int main() {
    printf("[mock] pid=%u starting Vulkan present loop\n", CurrentPid()); fflush(stdout);
    const char* modeEnv = getenv("MOCK_WINDOW_MODE");
    bool borderless = false;
    if (modeEnv) {
#if defined(_WIN32)
        borderless = _stricmp(modeEnv, "borderless") == 0;
#else
        borderless = strcasecmp(modeEnv, "borderless") == 0;
#endif
    }
    const bool staticFrame = envIs("MOCK_STATIC_FRAME", "1");
    const bool wantReadback = envIs("MOCK_READBACK", "1");

    CreateHostWindow(borderless);

    // ── Instance ──────────────────────────────────────────────────────────
    const char* instExt[] = { VK_KHR_SURFACE_EXTENSION_NAME, PlatformSurfaceExtension() };
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

    VkSurfaceKHR surface = CreateHostSurface(instance);

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

    VkImageUsageFlags usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    const bool canReadback = (caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0;
    if (wantReadback && canReadback) usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (wantReadback && !canReadback)
        printf("[mock] surface does not support TRANSFER_SRC; readback unavailable\n");

    VkSwapchainCreateInfoKHR scci = { VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR };
    scci.surface = surface;
    scci.minImageCount = imgCount;
    scci.imageFormat = sf.format;
    scci.imageColorSpace = sf.colorSpace;
    scci.imageExtent = g_extent;
    scci.imageArrayLayers = 1;
    scci.imageUsage = usage;
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

    Readback rb;
    const bool readbackOn = wantReadback && canReadback &&
        InitReadback(rb, phys, device, pool, (VkDeviceSize)g_extent.width * g_extent.height * 4);
    if (wantReadback && !readbackOn && canReadback)
        printf("[mock] readback buffer setup failed\n");

    // Sync (single frame in flight; vkQueueWaitIdle each frame keeps it simple + correct)
    VkSemaphore imgAvail, renderDone;
    VkSemaphoreCreateInfo semci = { VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VK_CHECK(vkCreateSemaphore(device, &semci, nullptr, &imgAvail));
    VK_CHECK(vkCreateSemaphore(device, &semci, nullptr, &renderDone));

    const char* secEnv = getenv("MOCK_SECONDS");
    uint64_t limitMs = (secEnv && atoi(secEnv) > 0) ? (uint64_t)atoi(secEnv) * 1000 : 30000;
    printf("[mock] entering present loop (runtime %llus)\n", (unsigned long long)(limitMs / 1000));
    fflush(stdout);
    uint64_t start = nowMs();
    uint32_t frame = 0;
    uint8_t clearBytes[3] = { 0, 0, 0 };

    while (!g_quit) {
        PumpEvents();
        if (nowMs() - start > limitMs) break; // safety auto-exit

        uint32_t idx = 0;
        VkResult acq = vkAcquireNextImageKHR(device, swap, UINT64_MAX, imgAvail, VK_NULL_HANDLE, &idx);
        if (acq == VK_ERROR_OUT_OF_DATE_KHR) break;

        // animated clear colour (slow hue sweep) so frames visibly change
        float t = staticFrame ? 0.0f : frame * 0.01f;
        VkClearValue clear;
        clear.color.float32[0] = 0.25f + 0.20f * sinf(t);
        clear.color.float32[1] = 0.30f + 0.20f * sinf(t + 2.0f);
        clear.color.float32[2] = 0.45f + 0.20f * sinf(t + 4.0f);
        clear.color.float32[3] = 1.0f;
        for (int c = 0; c < 3; c++)
            clearBytes[c] = (uint8_t)(clear.color.float32[c] * 255.0f + 0.5f);

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

        // Measure the overlay on the LAST frame only, once the layer has had
        // time to poll the log and fade its message in.
        if (readbackOn && nowMs() - start > limitMs - 400) {
            const uint8_t* px = CaptureImage(rb, device, queue, images[idx], g_extent);
            if (px) {
                // The overlay's top edge sits at VerticalPercent of the frame;
                // sample a generous band around it rather than assuming the
                // exact panel height.
                uint32_t y0 = (uint32_t)(g_extent.height * 0.10f);
                uint32_t y1 = (uint32_t)(g_extent.height * 0.40f);
                if (y1 > g_extent.height) y1 = g_extent.height;
                uint64_t differing = 0, total = 0;
                for (uint32_t y = y0; y < y1; y++) {
                    for (uint32_t x = 0; x < g_extent.width; x++) {
                        const uint8_t* p = px + ((uint64_t)y * g_extent.width + x) * 4;
                        // Swapchain is BGRA; clearBytes is RGB.
                        int db = abs((int)p[0] - (int)clearBytes[2]);
                        int dg = abs((int)p[1] - (int)clearBytes[1]);
                        int dr = abs((int)p[2] - (int)clearBytes[0]);
                        if (db > 12 || dg > 12 || dr > 12) differing++;
                        total++;
                    }
                }
                printf("[mock-readback] band_y=%u..%u differing=%llu total=%llu\n",
                       y0, y1, (unsigned long long)differing, (unsigned long long)total);

                const char* ppm = getenv("MOCK_READBACK_PPM");
                if (ppm) {
                    FILE* f = fopen(ppm, "wb");
                    if (f) {
                        fprintf(f, "P6\n%u %u\n255\n", g_extent.width, g_extent.height);
                        for (uint32_t y = 0; y < g_extent.height; y++)
                            for (uint32_t x = 0; x < g_extent.width; x++) {
                                const uint8_t* p = px + ((uint64_t)y * g_extent.width + x) * 4;
                                uint8_t rgb[3] = { p[2], p[1], p[0] };
                                fwrite(rgb, 1, 3, f);
                            }
                        fclose(f);
                        printf("[mock-readback] wrote %s\n", ppm);
                    }
                }
                fflush(stdout);
                vkUnmapMemory(device, rb.memory);
            }
            break; // measured; nothing more to do
        }
        frame++;
    }

    printf("[mock] exiting after %u frames\n", frame); fflush(stdout);
    vkDeviceWaitIdle(device);
    return 0;
}
