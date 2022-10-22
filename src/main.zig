const std = @import("std");
const net = std.net;
const mem = std.mem;
const fs = std.fs;
const io = std.io;

const BUFSIZ = 8196;

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    var args = try std.process.argsWithAllocator(allocator);
    const exe_name = args.next() orelse "webserver";
    const public_path = args.next() orelse {
        std.log.err("Usage: {s} <dir to serve files from>", .{exe_name});
        return;
    };
    var dir = try fs.cwd().openDir(public_path, .{});
    defer dir.close();
    const self_addr = try net.Address.parseIp("127.0.0.1", 9000);
    std.log.info("{}", .{self_addr});
    var listener = net.StreamServer.init(.{});
    try (&listener).listen(self_addr);
    std.log.info("Listening on http://{}; press Ctrl-C to exit...", .{self_addr});
    std.log.info("dir {}", .{dir});
    
    while ((&listener).accept()) |conn| {
        std.log.info("Accepted connection from: {}", .{conn.address});
        serveFile(&conn.stream, dir) catch |err| {
            if (@errorReturnTrace()) |bt| {
                std.log.err("Failed to serve client: {}: {}", .{err, bt});
            } else {
                std.log.err("Failed to serve client: {}", .{err});
            }
        };
        conn.stream.close();
    } else |err| {
        return err;
    }
}

const ServeFileError = error {
    RecvHeaderEOF,
    RecvHeaderExceededBuffer,
    HeaderDidNotMatch,
    FileNotFound,
};

fn serveFile(stream: *const net.Stream, dir: fs.Dir) !void {
    std.log.info("serve file {} {}", .{stream, dir});
    var recv_buf: [BUFSIZ]u8 = undefined;
    var recv_total: usize = 0;
    
    while (stream.read(recv_buf[recv_total..])) |recv_len| {
        if (recv_len == 0) {
            return ServeFileError.RecvHeaderEOF;
        }
        recv_total += recv_len;
        if (mem.containsAtLeast(u8, recv_buf[0..recv_total], 1, "\r\n\r\n")) {
            break;
        }
        if (recv_total >= recv_buf.len) {
            return ServeFileError.RecvHeaderExceededBuffer;
        }
    } else |read_err| {
        return read_err;
    }
    const recv_slice = recv_buf[0..recv_total];
    std.log.info(" <<<\n{s}", .{recv_slice});
    var file_path: []const u8 = undefined;
    var tok_iter = mem.tokenize(u8, recv_slice, " ");
    if (!mem.eql(u8, tok_iter.next() orelse "", "GET")) {
        return ServeFileError.HeaderDidNotMatch;
    }
    const path = tok_iter.next() orelse "";
    if (path[0] != '/') {
        return ServeFileError.HeaderDidNotMatch;
    }
    if (mem.eql(u8, path, "/")) {
        file_path = "index";
    } else {
        file_path = path[1..];
    }
    if (!mem.startsWith(u8, tok_iter.rest(), "HTTP/1.1\r\n")) {
        return ServeFileError.HeaderDidNotMatch;
    }
    var file_ext = fs.path.extension(file_path);
    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    
    if (file_ext.len == 0) {
        var path_fbs = io.fixedBufferStream(&path_buf);
        try path_fbs.writer().print("{s}.html", .{file_path});
        file_ext = ".html";
        file_path = path_fbs.getWritten();
    }
    try sendFile(stream, dir, file_path, file_ext);
}

fn sendFile(stream: *const net.Stream, dir: fs.Dir, file_path: []const u8, file_ext: []const u8) !void {
    std.log.info("Opening {s}", .{file_path});
    const body_file = dir.openFile(file_path, .{}) catch {
        try sendHttp404(stream);
        return;
    };
    defer body_file.close();
    const file_len = try body_file.getEndPos();
    
    const http_head = 
        "HTTP/1.1 200 OK\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n";
    const mimes = .{
        .{".html", "text/html"},
        .{".css", "text/css"},
        .{".map", "application/json"},
        .{".svg", "image/svg+xml"},
        .{".jpg", "image/jpg"},
        .{".png", "image/png"}
    };
    var mime: []const u8 = "text/plain";
    inline for (mimes) |kv| {
        if (mem.eql(u8, kv[0], file_ext)) {
            mime = kv[1];
        }
    }
    std.log.info(" >>>\n" ++ http_head, .{mime, file_len});
    try stream.writer().print(http_head, .{mime, file_len});
    const zero_iovec = &[0]std.os.iovec_const{};
    var send_total: usize = 0;
    while (true) {
        const send_len = try std.os.sendfile(
            stream.handle,
            body_file.handle,
            send_total,
            file_len,
            zero_iovec,
            zero_iovec,
            0
        );

        if (send_len == 0)
            break;

        send_total += send_len;
    }
} 

fn sendHttp404(stream: *const net.Stream) !void {
    const http_404_head = 
        "HTTP/1.1 404 Not Found\r\n" ++
        "Connection: close\r\n" ++
        "Content-Type: text/html\r\n" ++
        "Content-Length: {}\r\n" ++
        "\r\n";
    const http_404_response = "<html><head><title>Not Found</title></head><body><h1>Not Found</h1></body></html>";
    try stream.writer().print(http_404_head, .{http_404_response.len});
    try stream.writer().print(http_404_response, .{});
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
