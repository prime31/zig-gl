const std = @import("std");
const sdl = @import("sdl");
const imgui_gl = @import("imgui_gl");
const imgui = @import("imgui");
const renderkit = @import("renderkit");

pub const utils = @import("utils/utils.zig");

const Window = @import("window.zig").Window;
const WindowConfig = @import("window.zig").WindowConfig;
const Input = @import("input.zig").Input;
const Time = @import("time.zig").Time;

pub const Config = struct {
    init: fn () anyerror!void,
    update: ?fn () anyerror!void = null,
    render: fn () anyerror!void,
    shutdown: ?fn () anyerror!void = null,

    window: WindowConfig = WindowConfig{},

    update_rate: f64 = 60, // desired fps
    imgui_viewports: bool = true, // whether imgui viewports should be enabled
    imgui_docking: bool = true, // whether imgui docking should be enabled
};

pub var window: Window = undefined;
pub var time: Time = undefined;
pub var input: Input = undefined;

pub fn run(config: Config) !void {
    window = try Window.init(.{});

    var metal_setup = renderkit.MetalSetup{};
    if (renderkit.current_renderer == .metal) {
        var metal_view = sdl.SDL_Metal_CreateView(window.sdl_window);
        metal_setup.ca_layer = sdl.SDL_Metal_GetLayer(metal_view);
    }

    renderkit.renderer.setup(.{
        .allocator = std.testing.allocator,
        .gl_loader = sdl.SDL_GL_GetProcAddress,
        .metal = metal_setup,
    });

    time = Time.init(config.update_rate);
    input = Input.init(window.scale());

    if (renderkit.enable_imgui) {
        if (renderkit.current_renderer != .opengl) @panic("ImGui only works with OpenGL so far!");

        _ = imgui.igCreateContext(null);
        var io = imgui.igGetIO();
        io.ConfigFlags |= imgui.ImGuiConfigFlags_NavEnableKeyboard;
        if (config.imgui_docking) io.ConfigFlags |= imgui.ImGuiConfigFlags_DockingEnable;
        if (config.imgui_viewports) io.ConfigFlags |= imgui.ImGuiConfigFlags_ViewportsEnable;
        imgui_gl.initForGl(null, window.sdl_window, window.gl_ctx);

        var style = imgui.igGetStyle();
        style.WindowRounding = 0;
    }

    try config.init();

    while (!pollEvents()) {
        time.tick();
        if (config.update) |update| try update();
        try config.render();

        if (renderkit.enable_imgui) {
            const size = window.drawableSize();
            renderkit.viewport(0, 0, size.w, size.h);

            imgui_gl.render();
            _ = sdl.SDL_GL_MakeCurrent(window.sdl_window, window.gl_ctx);
        }

        if (renderkit.current_renderer == .opengl) sdl.SDL_GL_SwapWindow(window.sdl_window);
        renderkit.commitFrame();
        input.newFrame();
    }

    if (renderkit.enable_imgui) imgui_gl.shutdown();
    renderkit.renderer.shutdown();
    window.deinit();
    sdl.SDL_Quit();
}

fn pollEvents() bool {
    var event: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&event) != 0) {
        if (renderkit.enable_imgui and imguiHandleEvent(&event)) continue;

        switch (event.type) {
            sdl.SDL_QUIT => return true,
            sdl.SDL_WINDOWEVENT => {
                if (event.window.windowID == window.id) {
                    if (event.window.event == sdl.SDL_WINDOWEVENT_CLOSE) return true;
                    window.handleEvent(&event.window);
                }
            },
            else => input.handleEvent(&event),
        }
    }

    if (renderkit.enable_imgui) imgui_gl.newFrame(window.sdl_window);

    return false;
}

// returns true if the event is handled by imgui and should be ignored by via
fn imguiHandleEvent(evt: *sdl.SDL_Event) bool {
    if (imgui_gl.ImGui_ImplSDL2_ProcessEvent(evt)) {
        return switch (evt.type) {
            sdl.SDL_MOUSEWHEEL, sdl.SDL_MOUSEBUTTONDOWN => return imgui.igGetIO().WantCaptureMouse,
            sdl.SDL_KEYDOWN, sdl.SDL_KEYUP, sdl.SDL_TEXTINPUT => return imgui.igGetIO().WantCaptureKeyboard,
            sdl.SDL_WINDOWEVENT => return true,
            else => return false,
        };
    }
    return false;
}
