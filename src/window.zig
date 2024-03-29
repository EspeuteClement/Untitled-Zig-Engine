const std = @import("std");
const Allocator = std.mem.Allocator;

const glfw = @import("glfw");
const gl = @import("gl");
const glhelp = @import("glhelp.zig");

const texture = @import("texture.zig");
const sprite = @import("sprite.zig");
const shader = @import("shader.zig");

const profile = @import("profile.zig");

const c = @cImport({
    @cDefine("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", "1");
    @cInclude("cimgui.h");
    @cInclude("imgui/imgui_impl_opengl3.h");
    @cInclude("imgui/imgui_impl_glfw.h");
});

const with_imgui = @import("build_options").with_imgui;

fn getProcAdress(dummy: ?*anyopaque, proc_name: [:0]const u8) ?*const anyopaque {
    _ = dummy;
    return glfw.getProcAddress(proc_name);
}

fn onResize(window: glfw.Window, width: u32, height: u32) void {
    _ = window;
    _ = width;
    _ = height;

    var self: *Context.Data = window.getUserPointer(Context.Data) orelse @panic("missing userptr");

    self.config.window_width = width;
    self.config.window_height = height;
    //gl.viewport(0, 0, @intCast(gl.GLint, width), @intCast(gl.GLint, height));
}

pub const Context = struct {
    data: *Data = undefined,
    allocator: Allocator = undefined,

    pub const Data = struct {
        glfw_window: glfw.Window = undefined,
        game_buffer: texture.FramebufferHandle = undefined,

        time : f64 = 0.0,

        config: Config = Config{},

        current_zoom: u8 = 1,

        batch: sprite.Batch = undefined,
        shader: shader.Shader(struct { uCamera: shader.Camera = undefined }) = undefined,

        const Config = struct {
            game_width: u32 = 640,
            game_height: u32 = 480,

            window_width: u32 = 640,
            window_height: u32 = 480,
        };
    };

    fn initGameRenderbuffer(self: *Context) !void {
        self.data.game_buffer = try texture.createFramebuffer(.{
            .width = @intCast(u16, self.data.config.game_width),
            .height = @intCast(u16, self.data.config.game_height),
            .depth = .RGB,
            .min_filter = .NEAREST,
            .mag_filter = .NEAREST,
        });
    }

    pub fn init(allocator: Allocator) !Context {
        try glfw.init(.{});
        errdefer glfw.terminate();

        var self: Context = undefined;

        self.data = try allocator.create(Data);
        errdefer allocator.destroy(self.data);

        self.data.* = Data{};

        self.allocator = allocator;

        std.debug.print("{d: >7.4} init window ...\n", .{glfw.getTime()});

        self.data.glfw_window = try glfw.Window.create(self.data.config.game_width, self.data.config.game_height, "Untilted Zig Engine", null, null, .{
            .opengl_profile = .opengl_core_profile,
            .context_version_major = 3,
            .context_version_minor = 3,
            .maximized = with_imgui,
        });
        errdefer self.data.glfw_window.destroy();

        glfw.Window.setUserPointer(self.data.glfw_window, self.data);
        glfw.Window.setFramebufferSizeCallback(self.data.glfw_window, onResize);

        //try self.data.glfw_window.setMonitor(glfw.Monitor.getPrimary(), 0,0,1920,1080, 60);

        std.debug.print("{d: >7.4} starting opengl context ...\n", .{glfw.getTime()});
        try glfw.makeContextCurrent(self.data.glfw_window);

        std.debug.print("{d: >7.4} loading opengl ...\n", .{glfw.getTime()});
        try gl.load(@as(?*anyopaque, null), getProcAdress);

        if (with_imgui) {
            _ = c.igCreateContext(null);
            var io: [*c]c.ImGuiIO = c.igGetIO();
            _ = io;

            c.igStyleColorsDark(null);

            _ = c.ImGui_ImplGlfw_InitForOpenGL(@ptrCast(*c.GLFWwindow, self.data.glfw_window.handle), true);
            _ = c.ImGui_ImplOpenGL3_Init("#version 130");
        }

        try texture.init(allocator);
        errdefer texture.deinit();

        try sprite.init(allocator);
        errdefer sprite.deinit();

        try glfw.swapInterval(0);

        try self.initGameRenderbuffer();

        self.data.batch = try sprite.Batch.init(self.allocator);
        errdefer self.data.batch.deinit();

        self.data.batch.texture_handle = texture.getFramebufferTexture(self.data.game_buffer);
        try self.data.batch.drawQuad(.{
            .x = 0.0,
            .y = 0.0,
            .w = @intCast(i16, self.data.config.game_width),
            .h = @intCast(i16, self.data.config.game_height),
            .u0 = 0,
            .v0 = @intCast(i16, self.data.config.game_height),
            .u1 = @intCast(i16, self.data.config.game_width),
            .v1 = 0,
        });

        self.data.shader = @TypeOf(self.data.shader).init(try glhelp.buildProgram(@embedFile("game/game.vert"), @embedFile("game/game.frag")));
        errdefer self.data.shader.deinit();

        return self;
    }

    pub fn deinit(self: *Context) void {
        if (with_imgui) {
            c.ImGui_ImplOpenGL3_Shutdown();
            c.ImGui_ImplGlfw_Shutdown();
            c.igDestroyContext(null);
        }

        self.data.batch.deinit();
        self.data.shader.deinit();

        texture.deinit();
        sprite.deinit();
        self.data.glfw_window.destroy();
        glfw.terminate();
        self.allocator.destroy(self.data);
    }

    fn getImGuiWindowsWantedSize(self : *Context, scale : u32) c.ImVec2
    {
        return .{ .x = @intToFloat(f32, scale * self.data.config.game_width), .y = @intToFloat(f32, scale * self.data.config.game_height) + 32.0 };
    } 

    fn imguiGameRenderSizeConstraintCallback(data_ptr: [*c]c.ImGuiSizeCallbackData) callconv(.C) void {
        if (data_ptr) |data| {
            var self: *Context = @ptrCast(*Context, @alignCast(@alignOf(Context), data.*.UserData));

            var scale_x: u32 = @floatToInt(u32, std.math.round(data.*.DesiredSize.x / @intToFloat(f32, self.data.config.game_width)));
            var scale_y: u32 = @floatToInt(u32, std.math.round(data.*.DesiredSize.y / @intToFloat(f32, self.data.config.game_height)));

            var min = @minimum(scale_x, scale_y);

            self.data.current_zoom = @intCast(u8, min);

            data.*.DesiredSize = self.getImGuiWindowsWantedSize(min);
        }
    }

    pub fn run(self: *Context, update_callback: fn(ctxt: Context) anyerror!void, draw_callback: fn (ctxt: Context) anyerror!void) !void {
        std.debug.print("{d: >7.4} starting main loop ...\n", .{glfw.getTime()});
        var show_demo_window: bool = true;

        self.data.time = glfw.getTime();
        var accumulator : f64 = 0.0;

        while (!self.data.glfw_window.shouldClose()) {
            var prof2 = profile.begin(@src(), "mainLoop"); defer prof2.end();
            
            const current_time = glfw.getTime();
            var delta_frame_time = current_time - self.data.time;
            self.data.time = current_time;

            std.debug.print("\n---------------\nNew frame, delta : {d:.4}ms\n", .{delta_frame_time/std.time.ms_per_s});

            if (std.math.fabs(delta_frame_time - 1.0/60.0) < 0.0005) {
                delta_frame_time = 1.0/60.0;
            }
            else if (std.math.fabs(delta_frame_time - 1.0/30.0) < 0.0005) {
                delta_frame_time = 1.0/30.0;
            }


            accumulator += delta_frame_time;

            while(accumulator >= 1.0 / 60.0) {
                try glfw.pollEvents();
                try update_callback(self.*);
                accumulator -= 1.0/60.0;
            }


            gl.clearColor(0.2, 0.2, 0.2, 1.0);
            gl.clear(gl.COLOR_BUFFER_BIT);

            if (with_imgui) {
                c.ImGui_ImplOpenGL3_NewFrame();
                c.ImGui_ImplGlfw_NewFrame();

                c.igNewFrame();

                if (show_demo_window) {
                    c.igShowDemoWindow(&show_demo_window);
                }
            }

            gl.viewport(0, 0, @intCast(c_int, self.data.config.game_width), @intCast(c_int, self.data.config.game_height));

            texture.bindFramebuffer(self.data.game_buffer);
            try draw_callback(self.*);
            texture.bindFramebuffer(null);

            if (with_imgui) {
                c.igSetNextWindowSize(self.getImGuiWindowsWantedSize(1), c.ImGuiCond_FirstUseEver);
                c.igSetNextWindowSizeConstraints(.{ .x = 0, .y = 0 }, .{ .x = std.math.f32_max, .y = std.math.f32_max }, imguiGameRenderSizeConstraintCallback, self);

                const textureID = texture.getTextureInternalID(texture.getFramebufferTexture(self.data.game_buffer));
                c.igPushStyleVar_Vec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
                _ = c.igBegin("Scene Window", null, c.ImGuiWindowFlags_NoScrollbar);
                c.igImage(@intToPtr(*anyopaque, textureID), .{ .x = @intToFloat(f32, self.data.config.game_width * @intCast(u32, self.data.current_zoom)), .y = @intToFloat(f32, self.data.config.game_height * @intCast(u32, self.data.current_zoom)) }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 0 }, .{ .x = 1.0, .y = 1.0, .z = 1.0, .w = 1.0 }, .{ .x = 1.0, .y = 1.0, .z = 1.0, .w = 0.0 });

                c.igEnd();
                c.igPopStyleVar(1);
            }

            if (!with_imgui) {
                gl.viewport(0, 0, @intCast(gl.GLint, self.data.config.window_width), @intCast(gl.GLint, self.data.config.window_height));

                self.data.shader.bind(.{
                    .uCamera = shader.makeCamera(0, 0, @intToFloat(f32, self.data.config.game_width), @intToFloat(f32, self.data.config.game_height)),
                });

                try self.data.batch.renderNoClear();
            }

            if (with_imgui) {
                c.igRender();
                c.ImGui_ImplOpenGL3_RenderDrawData(c.igGetDrawData());
            }

            {
                var prof = profile.begin(@src(), "swapBuffers"); defer prof.end();
                
                try glfw.Window.swapBuffers(self.data.glfw_window);
            }



            var update_time = glfw.getTime() - current_time;

            while (update_time < 1.0/60.0 * 0.5) {
                update_time = glfw.getTime() - current_time;
            }
        }
    }
};

test "Init deinit"
{
    var context: Context = try Context.init(std.testing.allocator);
    defer context.deinit();
}