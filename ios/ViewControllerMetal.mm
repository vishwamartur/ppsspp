#import "AppDelegate.h"
#import "ViewControllerMetal.h"
#import "DisplayManager.h"
#include "Controls.h"
#import "iOSCoreAudio.h"

#include "Common/Log.h"

#include "Common/GPU/Vulkan/VulkanLoader.h"
#include "Common/GPU/Vulkan/VulkanContext.h"
#include "Common/GPU/Vulkan/VulkanRenderManager.h"
#include "Common/GPU/thin3d.h"
#include "Common/GPU/thin3d_create.h"
#include "Common/Data/Text/Parsers.h"
#include "Common/Data/Encoding/Utf8.h"
#include "Common/System/Display.h"
#include "Common/System/System.h"
#include "Common/System/OSD.h"
#include "Common/System/NativeApp.h"
#include "Common/GraphicsContext.h"
#include "Common/Thread/ThreadUtil.h"

#include "Core/Config.h"
#include "Core/ConfigValues.h"
#include "Core/System.h"

// TODO: Share this between backends.
static uint32_t FlagsFromConfig() {
	uint32_t flags;
	if (g_Config.bVSync) {
		flags = VULKAN_FLAG_PRESENT_FIFO;
	} else {
		flags = VULKAN_FLAG_PRESENT_MAILBOX | VULKAN_FLAG_PRESENT_IMMEDIATE;
	}
	return flags;
}

enum class GraphicsContextState {
	PENDING,
	INITIALIZED,
	FAILED_INIT,
	SHUTDOWN,
};

class IOSVulkanContext : public GraphicsContext {
public:
	IOSVulkanContext();
	~IOSVulkanContext() {
		delete g_Vulkan;
		g_Vulkan = nullptr;
	}

	bool InitAPI();

	bool InitFromRenderThread(CAMetalLayer *layer, int desiredBackbufferSizeX, int desiredBackbufferSizeY);
	void ShutdownFromRenderThread();  // Inverses InitFromRenderThread.

	void Shutdown();
	void Resize();

	void *GetAPIContext() { return g_Vulkan; }
	Draw::DrawContext *GetDrawContext() { return draw_; }

private:
	VulkanContext *g_Vulkan = nullptr;
	Draw::DrawContext *draw_ = nullptr;
	GraphicsContextState state_ = GraphicsContextState::PENDING;
};

IOSVulkanContext::IOSVulkanContext() {}

bool IOSVulkanContext::InitFromRenderThread(CAMetalLayer *layer, int desiredBackbufferSizeX, int desiredBackbufferSizeY) {
	INFO_LOG(G3D, "IOSVulkanContext::InitFromRenderThread: desiredwidth=%d desiredheight=%d", desiredBackbufferSizeX, desiredBackbufferSizeY);
	if (!g_Vulkan) {
		ERROR_LOG(G3D, "IOSVulkanContext::InitFromRenderThread: No Vulkan context");
		return false;
	}

	VkResult res = g_Vulkan->InitSurface(WINDOWSYSTEM_METAL_EXT, (void *)layer, nullptr);
	if (res != VK_SUCCESS) {
		ERROR_LOG(G3D, "g_Vulkan->InitSurface failed: '%s'", VulkanResultToString(res));
		return false;
	}

	bool success = true;
	if (g_Vulkan->InitSwapchain()) {
		bool useMultiThreading = g_Config.bRenderMultiThreading;
		if (g_Config.iInflightFrames == 1) {
			useMultiThreading = false;
		}
		draw_ = Draw::T3DCreateVulkanContext(g_Vulkan, useMultiThreading);
		SetGPUBackend(GPUBackend::VULKAN);
		success = draw_->CreatePresets();  // Doesn't fail, we ship the compiler.
		_assert_msg_(success, "Failed to compile preset shaders");
		draw_->HandleEvent(Draw::Event::GOT_BACKBUFFER, g_Vulkan->GetBackbufferWidth(), g_Vulkan->GetBackbufferHeight());

		VulkanRenderManager *renderManager = (VulkanRenderManager *)draw_->GetNativeObject(Draw::NativeObject::RENDER_MANAGER);
		renderManager->SetInflightFrames(g_Config.iInflightFrames);
		success = renderManager->HasBackbuffers();
	} else {
		success = false;
	}

	INFO_LOG(G3D, "IOSVulkanContext::Init completed, %s", success ? "successfully" : "but failed");
	if (!success) {
		g_Vulkan->DestroySwapchain();
		g_Vulkan->DestroySurface();
		g_Vulkan->DestroyDevice();
		g_Vulkan->DestroyInstance();
	}
	return success;
}

void IOSVulkanContext::ShutdownFromRenderThread() {
	INFO_LOG(G3D, "IOSVulkanContext::Shutdown");
	draw_->HandleEvent(Draw::Event::LOST_BACKBUFFER, g_Vulkan->GetBackbufferWidth(), g_Vulkan->GetBackbufferHeight());
	delete draw_;
	draw_ = nullptr;
	g_Vulkan->WaitUntilQueueIdle();
	g_Vulkan->PerformPendingDeletes();
	g_Vulkan->DestroySwapchain();
	g_Vulkan->DestroySurface();
	INFO_LOG(G3D, "Done with ShutdownFromRenderThread");
}

void IOSVulkanContext::Shutdown() {
	INFO_LOG(G3D, "Calling NativeShutdownGraphics");
	g_Vulkan->DestroyDevice();
	g_Vulkan->DestroyInstance();
	// We keep the g_Vulkan context around to avoid invalidating a ton of pointers around the app.
	finalize_glslang();
	INFO_LOG(G3D, "IOSVulkanContext::Shutdown completed");
}

void IOSVulkanContext::Resize() {
	INFO_LOG(G3D, "IOSVulkanContext::Resize begin (oldsize: %dx%d)", g_Vulkan->GetBackbufferWidth(), g_Vulkan->GetBackbufferHeight());

	draw_->HandleEvent(Draw::Event::LOST_BACKBUFFER, g_Vulkan->GetBackbufferWidth(), g_Vulkan->GetBackbufferHeight());
	g_Vulkan->DestroySwapchain();
	g_Vulkan->DestroySurface();

	g_Vulkan->UpdateFlags(FlagsFromConfig());

	g_Vulkan->ReinitSurface();
	g_Vulkan->InitSwapchain();
	draw_->HandleEvent(Draw::Event::GOT_BACKBUFFER, g_Vulkan->GetBackbufferWidth(), g_Vulkan->GetBackbufferHeight());
	INFO_LOG(G3D, "IOSVulkanContext::Resize end (final size: %dx%d)", g_Vulkan->GetBackbufferWidth(), g_Vulkan->GetBackbufferHeight());
}

extern const char *PPSSPP_GIT_VERSION;

bool IOSVulkanContext::InitAPI() {
	INFO_LOG(G3D, "IOSVulkanContext::Init");
	init_glslang();

	g_LogOptions.breakOnError = true;
	g_LogOptions.breakOnWarning = true;
	g_LogOptions.msgBoxOnError = false;

	INFO_LOG(G3D, "Creating Vulkan context");
	Version gitVer(PPSSPP_GIT_VERSION);

	std::string errorStr;
	if (!VulkanLoad(&errorStr)) {
		ERROR_LOG(G3D, "Failed to load Vulkan driver library: %s", errorStr.c_str());
		state_ = GraphicsContextState::FAILED_INIT;
		return false;
	}

	if (!g_Vulkan) {
		// TODO: Assert if g_Vulkan already exists here?
		g_Vulkan = new VulkanContext();
	}

	VulkanContext::CreateInfo info{};
	info.app_name = "PPSSPP";
	info.app_ver = gitVer.ToInteger();
	info.flags = FlagsFromConfig();
	VkResult res = g_Vulkan->CreateInstance(info);
	if (res != VK_SUCCESS) {
		ERROR_LOG(G3D, "Failed to create vulkan context: %s", g_Vulkan->InitError().c_str());
		VulkanSetAvailable(false);
		delete g_Vulkan;
		g_Vulkan = nullptr;
		state_ = GraphicsContextState::FAILED_INIT;
		return false;
	}

	int physicalDevice = g_Vulkan->GetBestPhysicalDevice();
	if (physicalDevice < 0) {
		ERROR_LOG(G3D, "No usable Vulkan device found.");
		g_Vulkan->DestroyInstance();
		delete g_Vulkan;
		g_Vulkan = nullptr;
		state_ = GraphicsContextState::FAILED_INIT;
		return false;
	}

	g_Vulkan->ChooseDevice(physicalDevice);

	INFO_LOG(G3D, "Creating Vulkan device (flags: %08x)", info.flags);
	if (g_Vulkan->CreateDevice() != VK_SUCCESS) {
		INFO_LOG(G3D, "Failed to create vulkan device: %s", g_Vulkan->InitError().c_str());
		System_Toast("No Vulkan driver found. Using OpenGL instead.");
		g_Vulkan->DestroyInstance();
		delete g_Vulkan;
		g_Vulkan = nullptr;
		state_ = GraphicsContextState::FAILED_INIT;
		return false;
	}

	g_Vulkan->SetCbGetDrawSize([]() {
		return VkExtent2D {(uint32_t)g_display.pixel_xres, (uint32_t)g_display.pixel_yres};
	});

	INFO_LOG(G3D, "Vulkan device created!");
	state_ = GraphicsContextState::INITIALIZED;
	return true;
}


#pragma mark -
#pragma mark PPSSPPViewControllerMetal

static std::atomic<bool> exitRenderLoop;
static std::atomic<bool> renderLoopRunning;
static bool renderer_inited = false;
static std::mutex renderLock;

@interface PPSSPPViewControllerMetal () {
	ICadeTracker g_iCadeTracker;
	TouchTracker g_touchTracker;

	IOSVulkanContext *graphicsContext;
	LocationHelper *locationHelper;
	CameraHelper *cameraHelper;
}

@property (nonatomic) GCController *gameController __attribute__((weak_import));

@end  // @interface

@implementation PPSSPPViewControllerMetal 

- (id)init {
	self = [super init];
	if (self) {
		sharedViewController = self;
		g_iCadeTracker.InitKeyMap();

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];

		if ([GCController class]) // Checking the availability of a GameController framework
		{
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerDidConnect:) name:GCControllerDidConnectNotification object:nil];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllerDidDisconnect:) name:GCControllerDidDisconnectNotification object:nil];
		}
	}
	return self;
}

// Should be very similar to the Android one, probably mergeable.
void VulkanRenderLoop(IOSVulkanContext *graphicsContext, CAMetalLayer *metalLayer, int desiredBackbufferSizeX, int desiredBackbufferSizeY) {
	SetCurrentThreadName("EmuThread");

	if (!graphicsContext) {
		ERROR_LOG(G3D, "runVulkanRenderLoop: Tried to enter without a created graphics context.");
		renderLoopRunning = false;
		exitRenderLoop = false;
		return;
	}

	if (exitRenderLoop) {
		WARN_LOG(G3D, "runVulkanRenderLoop: ExitRenderLoop requested at start, skipping the whole thing.");
		renderLoopRunning = false;
		exitRenderLoop = false;
		return;
	}

	// This is up here to prevent race conditions, in case we pause during init.
	renderLoopRunning = true;

	//WARN_LOG(G3D, "runVulkanRenderLoop. desiredBackbufferSizeX=%d desiredBackbufferSizeY=%d",
	//	desiredBackbufferSizeX, desiredBackbufferSizeY);

	if (!graphicsContext->InitFromRenderThread(metalLayer, desiredBackbufferSizeX, desiredBackbufferSizeY)) {
		// On Android, if we get here, really no point in continuing.
		// The UI is supposed to render on any device both on OpenGL and Vulkan. If either of those don't work
		// on a device, we blacklist it. Hopefully we should have already failed in InitAPI anyway and reverted to GL back then.
		ERROR_LOG(G3D, "Failed to initialize graphics context.");
		System_Toast("Failed to initialize graphics context.");

		delete graphicsContext;
		graphicsContext = nullptr;
		renderLoopRunning = false;
		return;
	}

	if (!exitRenderLoop) {
		if (!NativeInitGraphics(graphicsContext)) {
			ERROR_LOG(G3D, "Failed to initialize graphics.");
			// Gonna be in a weird state here..
		}
		graphicsContext->ThreadStart();
		renderer_inited = true;

		while (!exitRenderLoop) {
			{
				std::lock_guard<std::mutex> renderGuard(renderLock);
				NativeFrame(graphicsContext);
			}
			// Here Android processes frame commands.
		}
		INFO_LOG(G3D, "Leaving Vulkan main loop.");
	} else {
		INFO_LOG(G3D, "Not entering main loop.");
	}

	NativeShutdownGraphics();

	renderer_inited = false;
	graphicsContext->ThreadEnd();

	// Shut the graphics context down to the same state it was in when we entered the render thread.
	INFO_LOG(G3D, "Shutting down graphics context...");
	graphicsContext->ShutdownFromRenderThread();
	renderLoopRunning = false;
	exitRenderLoop = false;

	WARN_LOG(G3D, "Render loop function exited.");
}

- (void)loadView {
	INFO_LOG(G3D, "Creating metal view");

	CGRect screenRect = [[UIScreen mainScreen] bounds];
	CGFloat screenWidth = screenRect.size.width;
	CGFloat screenHeight = screenRect.size.height;

	PPSSPPMetalView *metalView = [[PPSSPPMetalView alloc] initWithFrame:CGRectMake(0, 0, screenWidth,screenHeight)];
	self.view = metalView;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[[DisplayManager shared] setupDisplayListener];

	INFO_LOG(SYSTEM, "Metal viewDidLoad");

	UIScreen* screen = [(AppDelegate*)[UIApplication sharedApplication].delegate screen];
	self.view.frame = [screen bounds];
	self.view.multipleTouchEnabled = YES;
	graphicsContext = new IOSVulkanContext();

	[[DisplayManager shared] updateResolution:[UIScreen mainScreen]];

	if (!graphicsContext->InitAPI()) {
		_assert_msg_(false, "Failed to init Vulkan");
	}

	int desiredBackbufferSizeX = g_display.pixel_xres;
	int desiredBackbufferSizeY = g_display.pixel_yres;

	INFO_LOG(G3D, "Detected size: %dx%d", desiredBackbufferSizeX, desiredBackbufferSizeY);
	CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;

	[self hideKeyboard];

	// Spin up the emu thread. It will in turn spin up the Vulkan render thread
	// on its own.
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		VulkanRenderLoop(graphicsContext, layer, desiredBackbufferSizeX, desiredBackbufferSizeY);
	});
}

// Allow device rotation to resize the swapchain
-(void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator {
	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
	// TODO: Handle resizing properly.
	// demo_resize(&demo);
}

- (UIView *)getView {
	return [self view];
}

/** Since this is a single-view app, initialize Vulkan as view is appearing. */
- (void)viewWillAppear:(BOOL) animated {
	[super viewWillAppear: animated];

	self.view.contentScaleFactor = UIScreen.mainScreen.nativeScale;

	uint32_t fps = 60;
	/*
	_displayLink = [CADisplayLink displayLinkWithTarget: self selector: @selector(renderLoop)];
	[_displayLink setFrameInterval: 60 / fps];
	[_displayLink addToRunLoop: NSRunLoop.currentRunLoop forMode: NSDefaultRunLoopMode];
	*/
}

/*
-(void) renderLoop {
	demo_draw(&demo);
}
*/

- (void)viewDidDisappear: (BOOL) animated {
	// [_displayLink invalidate];
	// [_displayLink release];
	// demo_cleanup(&demo);
	[super viewDidDisappear: animated];
}


- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (void)shareText:(NSString *)text {
	NSArray *items = @[text];
	UIActivityViewController * viewController = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
	dispatch_async(dispatch_get_main_queue(), ^{
		[self presentViewController:viewController animated:YES completion:nil];
	});
}

extern float g_safeInsetLeft;
extern float g_safeInsetRight;
extern float g_safeInsetTop;
extern float g_safeInsetBottom;

- (void)viewSafeAreaInsetsDidChange {
	if (@available(iOS 11.0, *)) {
		[super viewSafeAreaInsetsDidChange];
		// we use 0.0f instead of safeAreaInsets.bottom because the bottom overlay isn't disturbing (for now)
		g_safeInsetLeft = self.view.safeAreaInsets.left;
		g_safeInsetRight = self.view.safeAreaInsets.right;
		g_safeInsetTop = self.view.safeAreaInsets.top;
		g_safeInsetBottom = 0.0f;
	}
}

- (void)bindDefaultFBO
{
	// Do nothing
}

- (void)buttonDown:(iCadeState)button
{
	g_iCadeTracker.ButtonDown(button);
}

- (void)buttonUp:(iCadeState)button
{
	g_iCadeTracker.ButtonUp(button);
}

// The below is inspired by https://stackoverflow.com/questions/7253477/how-to-display-the-iphone-ipad-keyboard-over-a-full-screen-opengl-es-app
// It's a bit limited but good enough.

-(void) deleteBackward {
	KeyInput input{};
	input.deviceId = DEVICE_ID_KEYBOARD;
	input.flags = KEY_DOWN | KEY_UP;
	input.keyCode = NKCODE_DEL;
	NativeKey(input);
	INFO_LOG(SYSTEM, "Backspace");
}

-(BOOL) hasText
{
	return YES;
}

-(void) insertText:(NSString *)text
{
	std::string str = std::string([text UTF8String]);
	INFO_LOG(SYSTEM, "Chars: %s", str.c_str());
	UTF8 chars(str);
	while (!chars.end()) {
		uint32_t codePoint = chars.next();
		KeyInput input{};
		input.deviceId = DEVICE_ID_KEYBOARD;
		input.flags = KEY_CHAR;
		input.unicodeChar = codePoint;
		NativeKey(input);
	}
}

-(BOOL) canBecomeFirstResponder
{
	return YES;
}

-(void) showKeyboard {
	dispatch_async(dispatch_get_main_queue(), ^{
		[self becomeFirstResponder];
	});
}

-(void) hideKeyboard {
	dispatch_async(dispatch_get_main_queue(), ^{
		[self resignFirstResponder];
	});
}

@end

@implementation PPSSPPMetalView

/** Returns a Metal-compatible layer. */
+(Class) layerClass { return [CAMetalLayer class]; }

@end
