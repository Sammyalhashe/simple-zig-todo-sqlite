const std = @import("std");

const Alloc = std.mem.Allocator;
const Dir = Io.Dir;
const Env = std.process.Environ;
const Init = std.process.Init;
const Io = std.Io;
const Json = std.json;

const config_filename: []const u8 = ".todo.json";
const home_env_var = "HOME";

pub const Configuration = struct {
    const Self = @This();

    pub const Backend = enum { sqlite, mariadb, jj };

    pub const MariadbConfig = struct {
        host: []const u8,
        password: ?[]const u8 = null,
    };

    pub const JjConfig = struct {
        path: []const u8,
    };

    pub const SqliteConfig = struct {
        path: []const u8,
    };

    pub const Options = struct {
        backend: Backend = .sqlite,
        mariadb: ?MariadbConfig = null,
        jj: ?JjConfig = null,
        sqlite: ?SqliteConfig = null,
    };

    options: Options,
    environ: Env,
    io: Io,
    allocator: Alloc,

    fn load(self: *Self) !void {
        const home = Env.getAlloc(self.environ, self.allocator, home_env_var) catch |err| {
            std.log.warn("HOME not set, using defaults: {s}", .{@errorName(err)});
            return;
        };

        const dir = Dir.openDirAbsolute(self.io, home, .{}) catch return;
        defer dir.close(self.io);

        const content = Dir.readFileAlloc(dir, self.io, config_filename, self.allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };

        const parsed = Json.parseFromSliceLeaky(Options, self.allocator, content, .{}) catch |err| {
            std.log.err("unable to parse config: {s}", .{@errorName(err)});
            return err;
        };

        self.options = parsed;
    }

    pub fn init(_init: Init) !Self {
        var conf: Self = .{
            .options = .{},
            .environ = _init.minimal.environ,
            .io = _init.io,
            .allocator = _init.arena.allocator(),
        };
        try conf.load();

        if (conf.options.sqlite == null) {
            conf.options.sqlite = .{ .path = "todo.db" };
        }
        return conf;
    }
};
