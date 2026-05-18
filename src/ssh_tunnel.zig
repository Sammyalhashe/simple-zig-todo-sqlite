const std = @import("std");

pub const local_forward_port = 3307;
const remote_target = "127.0.0.1:3306";
const ssh_host_key_option = "StrictHostKeyChecking=no";
const exit_on_fwd_fail_option = "ExitOnForwardFailure=yes";
const tunnel_settle_ns = 2 * std.time.ns_per_s;
const forward_spec = std.fmt.comptimePrint("{d}:{s}", .{ local_forward_port, remote_target });

pub const SshTunnelError = error{SshTunnelFailed};

/// SSH tunnel that forwards local port 3307 to a remote MariaDB (127.0.0.1:3306).
/// Wraps the child process lifetime so callers get deterministic cleanup via `deinit`.
pub const SshTunnel = struct {
    child: std.process.Child,

    /// Spawns an SSH tunnel to `uri`, optionally authenticating with sshpass.
    /// Blocks for 2 seconds to let the tunnel establish, then verifies the
    /// forwarded port is reachable before returning.
    pub fn spawn(io: std.Io, uri: []const u8, password: ?[]const u8) (SshTunnelError || std.process.SpawnError)!SshTunnel {
        var child = try std.process.spawn(io, .{
            .argv = if (password) |pw|
                &[_][]const u8{ "sshpass", "-p", pw, "ssh", "-o", ssh_host_key_option, "-o", exit_on_fwd_fail_option, "-N", "-L", forward_spec, uri }
            else
                &[_][]const u8{ "ssh", "-o", ssh_host_key_option, "-o", exit_on_fwd_fail_option, "-N", "-L", forward_spec, uri },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        std.Io.sleep(io, .{ .nanoseconds = tunnel_settle_ns }, .real) catch {};

        // Verify the tunnel is actually up by probing the forwarded port.
        // If SSH exited (bad credentials, host unreachable, port conflict),
        // the connect will fail with ConnectionRefused.
        // Note: timeout option panics in Zig 0.16 threaded IO, so we connect
        // without one — the 2s sleep above gives the tunnel time to bind.
        const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(local_forward_port) };
        const stream = loopback.connect(io, .{ .mode = .stream }) catch {
            // Tunnel is not up -- kill the (likely already dead) child and
            // report a clear error instead of letting the caller slam into
            // a MariaDB connect failure.
            child.kill(io);
            return error.SshTunnelFailed;
        };
        stream.close(io);

        return .{ .child = child };
    }

    /// Kills the SSH child process and releases resources.
    pub fn deinit(self: *SshTunnel, io: std.Io) void {
        self.child.kill(io);
    }
};
