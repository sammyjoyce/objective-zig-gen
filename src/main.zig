const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Progress = std.Progress;
const fs = std.fs;

const builtin = @import("builtin");

const root = @import("root.zig");
const Framework = root.Framework;
const Manifest = root.Manifest;
const Renderer = @import("Renderer.zig");

const Parser = @import("Parser.zig");
const Registry = Parser.Registry;
const Type = Parser.Type;

const ArgParser = @import("arg_parser.zig").ArgParser;

fn mainImpl() !void {
    // Allocate a general-purpose allocator and ensure proper deinitialization.
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_allocator.allocator();
    defer std.debug.assert(gpa_allocator.deinit() == .ok);

    // Parse command-line arguments.
    const args = try ArgParser.run(
        gpa,
        &.{
            .{ .name = "no_render", .alias = "nr", .description = "Only parse the files. Used for debugging." },
            .{ .name = "output", .alias = "o", .description = "Sets the output directory of the generated files.", .param = .string },
            .{ .name = "no_fmt", .alias = "nf", .description = "Prevents zig fmt from running on the generated output." },
            .{ .name = "single_threaded", .alias = "st", .description = "Parses and renders frameworks serially as given in the framework. Typically used for debugging." },
        },
    );
    switch (args) {
        .parsed => |result| {
            // Read in the manifest file and deserialize it.
            const possible_frameworks = try root.parseJsonWithCustomErrorHandling(
                []const Framework,
                gpa,
                result.path,
            );
            if (possible_frameworks == null) {
                std.log.err("Found no frameworks in manifest '{s}'.", .{result.path});
                return;
            }
            const frameworks = possible_frameworks.?;
            defer frameworks.deinit();
            std.debug.print("Found {d} frameworks in manifest: {s}\n", .{frameworks.value.len, result.path});

            if (frameworks.value.len == 0) {
                std.log.err("Found no frameworks in manifest '{s}'.", .{result.path});
                return;
            }

            // Convert the parsed manifest into a map.
            var manifest = Manifest.init(gpa);
            defer manifest.deinit();
            for (frameworks.value) |*framework| {
                try manifest.put(framework.name, framework);
            }

            // Verify that every dependency is present in the manifest.
            for (frameworks.value) |framework| {
                for (framework.dependencies) |dependency| {
                    if (!manifest.contains(dependency)) {
                        std.log.err("Framework '{s}' has '{s}' listed as a dependency but it isn't in the manifest.", .{ framework.name, dependency });
                        return;
                    }
                }
            }

            // Acquire the absolute path to the Xcode SDK.
            const sdk_path = try root.acquireSDKPath(gpa);
            defer gpa.free(sdk_path);
            std.debug.print("Using SDK path: {s}\n", .{sdk_path});

            // Generate a path to the frameworks directory.
            const frameworks_path = try fs.path.join(
                gpa,
                &.{ sdk_path, "System/Library/Frameworks/" },
            );
            defer gpa.free(frameworks_path);

            // Start the thread pool if not in single-threaded mode.
            var pool: std.Thread.Pool = undefined;
            const single_threaded = result.options.contains("single_threaded") or builtin.single_threaded;
            // Thread error collection
            const ThreadError = struct {
                framework: []const u8,
                err: anyerror,
            };
            var thread_errors = std.ArrayList(ThreadError).init(gpa);
            defer thread_errors.deinit();
            var thread_errors_mutex: std.Thread.Mutex = .{};

            if (!single_threaded) {
                try pool.init(.{ .allocator = gpa });
                defer pool.deinit();
            }

            // Start progress tracking.
            const base_progress = Progress.start(.{ .estimated_total_items = 2 });
            defer base_progress.end();

            // Parse the frameworks concurrently (or serially if single_threaded).
            const results = try gpa.alloc(Registry, frameworks.value.len);
            {
                const parse_progress = base_progress.start("Parsing Frameworks", frameworks.value.len);
                defer parse_progress.end();

                if (single_threaded) {
                    for (frameworks.value, 0..) |*framework, index| {
                        try Parser.parse(.{
                            .gpa = gpa,
                            .arena = gpa,
                            .sdk_path = sdk_path,
                            .framework = framework,
                            .result = &results[index],
                            .progress = parse_progress,
                        });
                    }
                } else {
                    var parseWg: std.Thread.WaitGroup = .{};
                    for (frameworks.value, 0..) |*framework, index| {
                        const parse_args = Parser.ParseArgs{
                            .gpa = gpa,
                            .arena = gpa,
                            .sdk_path = sdk_path,
                            .framework = framework,
                            .result = &results[index],
                            .progress = parse_progress,
                        };
                        pool.spawnWg(&parseWg, struct {
                            fn wrapper(pa: Parser.ParseArgs, mutex: *std.Thread.Mutex, thread_errs: *std.ArrayList(ThreadError)) void {
                                Parser.parse(pa) catch |err| {
                                    mutex.lock();
                                    defer mutex.unlock();
                                    thread_errs.append(.{
                                        .framework = pa.framework.name,
                                        .err = err,
                                    }) catch {
                                        std.log.err("Failed to record error from framework {s}", .{pa.framework.name});
                                    };
                                };
                            }
                        }.wrapper, .{parse_args, &thread_errors_mutex, &thread_errors});
                    }
                    parseWg.wait();

                    // Check for any errors from parse threads
                    if (thread_errors.items.len > 0) {
                        // Report all errors that occurred
                        for (thread_errors.items) |err| {
                            std.log.err("Error parsing framework {s}: {s}", .{
                                err.framework,
                                @errorName(err.err),
                            });
                        }
                        return error.FrameworkParseError;
                    }
                }
            }

            // Debug: output each framework's parsed declaration count
            var i: usize = 0;
            while (i < frameworks.value.len) : (i += 1) {
                const reg = results[i];
                std.debug.print("Registry[{d}] for framework '{s}' has {d} top-level declarations.\n",
                    .{ i, reg.owner.name, reg.order.items.len });
            }

            // Stop here if no rendering is required.
            if (result.options.contains("no_render")) {
                return;
            }

            // Merge results from parsing.
            for (results) |*a| {
                for (results) |*b| {
                    if (a == b) continue;
                    {
                        var iter = b.typedefs.iterator();
                        while (iter.next()) |it| {
                            if (!a.typedefs.contains(it.key_ptr.*)) {
                                try a.typedefs.put(it.key_ptr.*, it.value_ptr.*);
                            }
                        }
                    }
                    {
                        var iter = b.structs.iterator();
                        while (iter.next()) |it| {
                            if (!a.structs.contains(it.key_ptr.*)) {
                                try a.structs.put(it.key_ptr.*, it.value_ptr.*);
                            }
                        }
                    }
                    {
                        var iter = b.unions.iterator();
                        while (iter.next()) |it| {
                            if (!a.unions.contains(it.key_ptr.*)) {
                                try a.unions.put(it.key_ptr.*, it.value_ptr.*);
                            }
                        }
                    }
                    {
                        var iter = b.enums.iterator();
                        while (iter.next()) |it| {
                            if (!a.enums.contains(it.key_ptr.*)) {
                                try a.enums.put(it.key_ptr.*, it.value_ptr.*);
                            }
                        }
                    }
                    {
                        var iter = b.interfaces.iterator();
                        while (iter.next()) |it| {
                            if (!a.interfaces.contains(it.key_ptr.*)) {
                                try a.interfaces.put(it.key_ptr.*, it.value_ptr.*);
                            }
                        }
                    }
                    {
                        var iter = b.protocols.iterator();
                        while (iter.next()) |it| {
                            if (!a.protocols.contains(it.key_ptr.*)) {
                                try a.protocols.put(it.key_ptr.*, it.value_ptr.*);
                            }
                        }
                    }
                }
            }

            // If no declarations were parsed, log a warning
            if (results[0].order.items.len == 0) {
                std.debug.print("Warning: No declarations were parsed for framework '{s}'.\n", .{ results[0].owner.name });
            }

            // Determine output directory from command-line options.
            var output_path: []const u8 = "output";
            if (result.options.get("output")) |value| {
                output_path = value.string;
            }

            // Try to create the output directory. Ignore any error about the directory already existing.
            fs.cwd().makeDir(output_path) catch |err| {
                if (err != fs.Dir.MakeError.PathAlreadyExists) {
                    return err;
                }
            };

            // Open the output directory.
            var output = try fs.cwd().openDir(output_path, .{});
            defer output.close();

            // Copy the Objective-C runtime file to the output directory.
            {
                var objc_file = try output.createFile("objc.zig", .{});
                defer objc_file.close();
                _ = try objc_file.write(@embedFile("objc.zig"));
            }

            // Render frameworks.
            {
                const render_progress = base_progress.start("Rendering Frameworks", frameworks.value.len);
                defer render_progress.end();

                // Clear previous errors
                thread_errors.clearRetainingCapacity();

                if (single_threaded) {
                    for (results) |*r| {
                        try Renderer.run(.{
                            .allocator = gpa,
                            .output = output,
                            .manifest = manifest,
                            .registry = r,
                            .progress = render_progress,
                        });
                    }
                } else {
                    var renderWg: std.Thread.WaitGroup = .{};
                    for (results) |*r| {
                        const render_args = Renderer.RunArgs{
                            .allocator = gpa,
                            .output = output,
                            .manifest = manifest,
                            .registry = r,
                            .progress = render_progress,
                        };
                        pool.spawnWg(&renderWg, struct {
                            fn wrapper(ra: Renderer.RunArgs, mutex: *std.Thread.Mutex, thread_errs: *std.ArrayList(ThreadError)) void {
                                Renderer.run(ra) catch |err| {
                                    mutex.lock();
                                    defer mutex.unlock();
                                    thread_errs.append(.{
                                        .framework = ra.registry.owner.name,
                                        .err = err,
                                    }) catch {
                                        std.log.err("Failed to record error from framework {s}", .{ra.registry.owner.name});
                                    };
                                };
                            }
                        }.wrapper, .{render_args, &thread_errors_mutex, &thread_errors});
                    }
                    renderWg.wait();

                    // Check for any errors from render threads
                    if (thread_errors.items.len > 0) {
                        // Report all errors that occurred
                        for (thread_errors.items) |err| {
                            std.log.err("Error rendering framework {s}: {s}", .{
                                err.framework,
                                @errorName(err.err),
                            });
                        }
                        return error.FrameworkRenderError;
                    }
                }
            }

            // Generate the root file that includes the runtime and all frameworks.
            {
                var root_file = try output.createFile("root.zig", .{});
                defer root_file.close();
                const writer = root_file.writer();
                _ = try writer.write("// THIS FILE IS AUTOGENERATED. MODIFICATIONS WILL NOT BE MAINTAINED.\n\n");
                _ = try writer.write("pub usingnamespace @import(\"objc.zig\"); // Export the Objective-C runtime to root.\n");
                for (frameworks.value) |f| {
                    try writer.print("pub const {s} = @import(\"{s}.zig\");\n", .{ f.output_file, f.output_file });
                }
            }

            // If formatting is not disabled, run zig fmt on the output directory.
            if (!result.options.contains("no_fmt")) {
                _ = try std.process.Child.run(.{
                    .allocator = gpa,
                    .argv = &.{
                        "zig",
                        "fmt",
                        output_path,
                    },
                });
            }
        },
        // For help or error cases, print the message.
        .help, .@"error" => |msg| std.debug.print("{s}", .{msg}),
    }
}

pub fn main() void {
    mainImpl() catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
