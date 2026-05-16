const std = @import("std");
/// An error type returned by the standard allocator.
pub const AllocatorError = std.mem.Allocator.Error;
pub const UnexpectedError = std.Io.UnexpectedError;

pub const ParseError = @import("parser/ParseError.zig").Error;
pub const PrintError = @import("parser/ParseError.zig").PrintError;
/// An Error returned by the `std.process.argsAlloc`.
///
/// `std.process.argsAlloc` is used to obtain the command line arguments from
/// the current process.
pub const OtherError = error{Overflow};
/// Complete error type of the library.
pub const YazapError = AllocatorError || UnexpectedError || ParseError || PrintError || OtherError;
