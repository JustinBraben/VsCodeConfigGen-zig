//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const VSCodeConfig = struct {
    steps: ArrayList(BuildStep),
    project_name: []const u8,
    
    const BuildStep = struct {
        name: []const u8,
        description: []const u8,
        step_type: StepType,
        
        const StepType = enum {
            run,
            @"test",
            build,
            custom,
        };
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        print("Usage: {s} <input_directory> <output_directory>\n", .{args[0]});
        return;
    }

    const input_dir = args[1];
    const output_dir = args[2];

    // Check if build.zig exists
    const build_zig_path = try std.fs.path.join(allocator, &[_][]const u8{ input_dir, "build.zig" });
    defer allocator.free(build_zig_path);
std.fs.accessAbsolute(build_zig_path, .{}) catch |err| {
        print("Error: Cannot access build.zig at {s}: {}\n", .{ build_zig_path, err });
        return;
    };

    print("Found build.zig at: {s}\n", .{build_zig_path});

    // Parse build steps using `zig build -l`
    const config = try parseBuildSteps(allocator, input_dir);
    defer config.steps.deinit();

    // Create output directory if it doesn't exist
    std.fs.makeDirAbsolute(output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Generate VSCode configuration files
    try generateExtensionsJson(allocator, output_dir);
    try generateTasksJson(allocator, output_dir, &config);
    try generateLaunchJson(allocator, output_dir, &config);
    try generateSettingsJson(allocator, output_dir, &config);

    print("Successfully generated VSCode configuration files in: {s}\n", .{output_dir});
}

fn parseBuildSteps(allocator: Allocator, input_dir: []const u8) !VSCodeConfig {
    var config = VSCodeConfig{
        .steps = ArrayList(VSCodeConfig.BuildStep).init(allocator),
        .project_name = std.fs.path.basename(input_dir),
    };

    // Execute `zig build -l` in the input directory
    var child = std.process.Child.init(&[_][]const u8{ "zig", "build", "-l" }, allocator);
    child.cwd = input_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        print("Error running 'zig build -l':\n{s}\n", .{stderr});
        return error.ZigBuildFailed;
    }

    // Parse the output
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var in_steps_section = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Look for the steps section
        if (std.mem.indexOf(u8, trimmed, "Steps:") != null) {
            in_steps_section = true;
            continue;
        }

        if (in_steps_section and std.mem.startsWith(u8, trimmed, "  ")) {
            // Parse step line: "  step_name    description"
            const step_line = std.mem.trim(u8, trimmed, " ");
            var parts = std.mem.splitScalar(u8, step_line, ' ');
            const step_name = parts.next() orelse continue;
            
            // Skip empty parts and collect description
            var description_parts = ArrayList([]const u8).init(allocator);
            defer description_parts.deinit();
            
            while (parts.next()) |part| {
                if (part.len > 0) {
                    try description_parts.append(part);
                }
            }
            
            const description = if (description_parts.items.len > 0)
                try std.mem.join(allocator, " ", description_parts.items)
            else
                try allocator.dupe(u8, "");

            // Determine step type
            const step_type = if (std.mem.eql(u8, step_name, "run"))
                VSCodeConfig.BuildStep.StepType.run
            else if (std.mem.eql(u8, step_name, "test"))
                VSCodeConfig.BuildStep.StepType.@"test"
            else if (std.mem.eql(u8, step_name, "build") or std.mem.eql(u8, step_name, "install"))
                VSCodeConfig.BuildStep.StepType.build
            else
                VSCodeConfig.BuildStep.StepType.custom;

            try config.steps.append(.{
                .name = try allocator.dupe(u8, step_name),
                .description = description,
                .step_type = step_type,
            });
        }
    }

    return config;
}

fn generateExtensionsJson(allocator: Allocator, output_dir: []const u8) !void {
    const extensions_content =
        \\{
        \\    "recommendations": [
        \\        "ziglang.vscode-zig",
        \\        "ms-vscode.cpptools"
        \\    ]
        \\}
        \\
    ;

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "extensions.json" });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    try file.writeAll(extensions_content);
}

fn generateTasksJson(allocator: Allocator, output_dir: []const u8, config: *const VSCodeConfig) !void {
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "tasks.json" });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    var writer = file.writer();

    try writer.writeAll("{\n");
    try writer.writeAll("    \"version\": \"2.0.0\",\n");
    try writer.writeAll("    \"tasks\": [\n");

    for (config.steps.items, 0..) |step, i| {
        const comma = if (i < config.steps.items.len - 1) "," else "";
        
        try writer.print("        {{\n", .{});
        try writer.print("            \"label\": \"zig {s}\",\n", .{step.name});
        try writer.print("            \"type\": \"shell\",\n", .{});
        try writer.print("            \"command\": \"zig\",\n", .{});
        try writer.print("            \"args\": [\"build\", \"{s}\"],\n", .{step.name});
        const step_type = switch (step.step_type) {
            .build => "build",
            .@"test" => "test",
            .run => "build",
            .custom => "build",
        };
        try writer.print("            \"group\": \"{s}\",\n", .{step_type});
        try writer.print("            \"presentation\": {{\n", .{});
        try writer.print("                \"echo\": true,\n", .{});
        try writer.print("                \"reveal\": \"always\",\n", .{});
        try writer.print("                \"focus\": false,\n", .{});
        try writer.print("                \"panel\": \"shared\",\n", .{});
        try writer.print("                \"showReuseMessage\": true,\n", .{});
        try writer.print("                \"clear\": false\n", .{});
        try writer.print("            }},\n", .{});
        try writer.print("            \"problemMatcher\": [\"$gcc\"]\n", .{});
        try writer.print("        }}{s}\n", .{comma});
    }

    try writer.writeAll("    ]\n");
    try writer.writeAll("}\n");
}

fn generateLaunchJson(allocator: Allocator, output_dir: []const u8, config: *const VSCodeConfig) !void {
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "launch.json" });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    var writer = file.writer();

    try writer.writeAll("{\n");
    try writer.writeAll("    \"version\": \"0.2.0\",\n");
    try writer.writeAll("    \"configurations\": [\n");

    // Find run steps to create debug configurations
    var run_configs_added = false;
    for (config.steps.items) |step| {
        if (step.step_type == .run) {
            if (run_configs_added) {
                try writer.writeAll(",\n");
            }
            
            try writer.print("        {{\n", .{});
            try writer.print("            \"name\": \"Debug {s}\",\n", .{config.project_name});
            try writer.print("            \"type\": \"lldb\",\n", .{});
            try writer.print("            \"request\": \"launch\",\n", .{});
            try writer.print("            \"program\": \"${{workspaceFolder}}/zig-out/bin/{s}\",\n", .{config.project_name});
            try writer.print("            \"args\": [],\n", .{});
            try writer.print("            \"cwd\": \"${{workspaceFolder}}\",\n", .{});
            try writer.print("            \"preLaunchTask\": \"zig {s}\"\n", .{step.name});
            try writer.print("        }}", .{});
            
            run_configs_added = true;
            break; // Only add one debug configuration
        }
    }

    if (!run_configs_added) {
        // Add a default debug configuration
        try writer.print("        {{\n", .{});
        try writer.print("            \"name\": \"Debug {s}\",\n", .{config.project_name});
        try writer.print("            \"type\": \"lldb\",\n", .{});
        try writer.print("            \"request\": \"launch\",\n", .{});
        try writer.print("            \"program\": \"${{workspaceFolder}}/zig-out/bin/{s}\",\n", .{config.project_name});
        try writer.print("            \"args\": [],\n", .{});
        try writer.print("            \"cwd\": \"${{workspaceFolder}}\",\n", .{});
        try writer.print("            \"preLaunchTask\": \"zig build\"\n", .{});
        try writer.print("        }}", .{});
    }

    try writer.writeAll("\n    ]\n");
    try writer.writeAll("}\n");
}

fn generateSettingsJson(allocator: Allocator, output_dir: []const u8, config: *const VSCodeConfig) !void {
    _ = config; // Currently unused, but could be used for project-specific settings
    
    const settings_content =
        \\{
        \\    // This enables breakpoints in .zig files.
        \\    // You can add this line to your global settings
        \\    // with Ctrl+P "> Preferences: Open Settings (JSON)"
        \\    // to have it apply to all projects
        \\    "debug.allowBreakpointsEverywhere": true
        \\}
        \\
    ;

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "settings.json" });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    try file.writeAll(settings_content);
}

const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
