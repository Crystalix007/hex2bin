const std = @import("std");

fn usage() noreturn {
    std.log.warn("usage: INPUT.hex OUTPUT.bin\n", .{});
    std.os.exit(1);
}

pub fn main() !void {
    // we never free anything
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena_allocator.allocator;

    var args = std.process.args();
    _ = try (args.next(allocator) orelse usage());
    const input_path_str = try (args.next(allocator) orelse usage());
    const output_path_str = try (args.next(allocator) orelse usage());
    if (args.next(allocator) != null) usage();

    var input_file = try std.fs.cwd().openFile(input_path_str, std.fs.File.OpenFlags{ .read = true });
    defer input_file.close();

    var output_file = try std.fs.cwd().createFile(output_path_str, std.fs.File.CreateFlags{ .truncate = true });
    defer output_file.close();

    var translator: Translator = undefined;
    translator.init(input_path_str, &input_file, &output_file, allocator);
    try translator.doIt();
}

const Translator = struct {
    const Self = @This();

    input_path_str: []const u8,
    input_file: *std.fs.File,
    buffered_input_reader: std.io.BufferedReader(4096, std.fs.File.Reader),
    input: std.io.BufferedReader(4096, std.fs.File.Reader).Reader,

    output_file: *std.fs.File,
    buffered_output_writer: std.io.BufferedWriter(4096, std.fs.File.Writer),
    output: std.io.BufferedWriter(4096, std.fs.File.Writer).Writer,

    allocator: *std.mem.Allocator,
    line_number: usize,
    column_number: usize,
    output_cursor: usize,
    put_back: ?u8,

    pub fn init(self: *Self, input_path_str: []const u8, input_file: *std.fs.File, output_file: *std.fs.File, allocator: *std.mem.Allocator) void {
        // FIXME: return a new object once we have https://github.com/zig-lang/zig/issues/287

        self.input_path_str = input_path_str;
        self.input_file = input_file;
        self.buffered_input_reader = std.io.bufferedReader(input_file.reader());
        self.input = self.buffered_input_reader.reader();

        self.output_file = output_file;
        self.buffered_output_writer = std.io.bufferedWriter(output_file.writer());
        self.output = self.buffered_output_writer.writer();

        self.line_number = 1;
        self.column_number = 0;
        self.output_cursor = 0;
        self.allocator = allocator;
    }

    pub fn doIt(self: *Self) !void {
        defer self.buffered_output_writer.flush() catch |err| {
            std.log.warn("Failed to flush output: {any}\n", .{err});
        };
        var too_close_for_nibble = false;
        while (true) {
            var c = self.readByte() catch |err| switch (err) {
                error.EndOfStream => {
                    // only allow EOF at the beginning of a line
                    if (self.column_number == 0) break;
                    return err;
                },
                else => return err,
            };

            if (parseNibble(c)) |nibble| {
                // hex encoded byte
                if (too_close_for_nibble) return self.parseError();
                // next char must be the rest of the byte
                const byteValue = (@intCast(u8, nibble) << 4) |
                    @intCast(u8, parseNibble(self.readByte() catch '-') orelse return self.parseError());
                try self.writeByte(byteValue);
                // and then a char which is not a hex byte
                too_close_for_nibble = true;
                continue;
            }
            too_close_for_nibble = false;

            if (c == ';') {
                // comment
                while (true) {
                    c = try self.readByte();
                    if (c == '\n') break;
                }
                // then do the newline handling below

            } else if (c == ':') {
                // offset directive
                if ('0' != try self.readByte()) return self.parseError();
                if ('x' != try self.readByte()) return self.parseError();
                var claimed_offset = try self.parseU64Hex();
                if (claimed_offset != self.output_cursor) {
                    // TODO: more specific error
                    return self.parseError();
                }
                too_close_for_nibble = true;
                continue;
            }

            // some other character
            switch (c) {
                ' ' => {},
                '\n' => {
                    self.line_number += 1;
                    self.column_number = 0;
                },
                else => return self.parseError(),
            }
        }
    }

    fn readByte(self: *Self) !u8 {
        const b = if (self.put_back) |b| b: {
            self.put_back = null;
            break :b b;
        } else try self.input.readByte();
        self.column_number += 1;
        return b;
    }

    fn putBackByte(self: *Self, b: u8) void {
        std.debug.assert(self.put_back == null);
        self.put_back = b;
        self.column_number -= 1;
    }

    fn writeByte(self: *Self, b: u8) !void {
        try self.output.writeByte(b);
        self.output_cursor += 1;
    }

    fn parseError(self: *Self) !void {
        std.log.warn("{s}:{d}:{d}: error: parse error\n", .{ self.input_path_str, self.line_number, self.column_number });
        return error.ParseError;
    }

    fn parseU64Hex(self: *Self) !u64 {
        var result: u64 = 0;
        var nibble_count: u32 = 0;
        while (nibble_count < 16) : (nibble_count += 1) {
            const c = try self.readByte();
            if (parseNibble(c)) |nibble| {
                result *= 16;
                result += nibble;
            } else {
                self.putBackByte(c);
                break;
            }
        }
        return result;
    }
};

fn parseNibble(c: u8) ?u4 {
    if ('0' <= c and c <= '9')
        return @truncate(u4, c - '0');
    if ('A' <= c and c <= 'F')
        return @truncate(u4, c - 'A') + 10;
    if ('a' <= c and c <= 'f')
        return @truncate(u4, c - 'a') + 10;
    return null;
}
