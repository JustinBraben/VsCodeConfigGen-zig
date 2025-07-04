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

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        for (self.steps.items) |item| {
            allocator.free(item.name);
            allocator.free(item.description);
        }
        self.steps.deinit();
    }
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
    var config = try parseBuildSteps(allocator, input_dir);
    defer config.deinit(allocator);

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

    print("Raw zig build -l output:\n{s}\n", .{stdout});

    // Parse the output - look for lines that start with "  " (two spaces)
    var lines = std.mem.splitScalar(u8, stdout, '\n');

    while (lines.next()) |line| {
        // Look for lines that start with exactly two spaces followed by a step name
        if (line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') {
            const step_line = std.mem.trim(u8, line, " \t\r\n");
            
            // Find the first whitespace to separate step name from description
            var space_index: ?usize = null;
            for (step_line, 0..) |char, i| {
                if (char == ' ' or char == '\t') {
                    space_index = i;
                    break;
                }
            }
            
            const step_name = if (space_index) |idx| 
                step_line[0..idx]
            else 
                step_line;
            
            const description = if (space_index) |idx|
                std.mem.trim(u8, step_line[idx..], " \t")
            else
                "";

            print("Found step: '{s}' with description: '{s}'\n", .{ step_name, description });

            // Determine step type
            const step_type: VSCodeConfig.BuildStep.StepType = if (std.mem.eql(u8, step_name, "run"))
                .run
            else if (std.mem.eql(u8, step_name, "test"))
                .@"test"
            else if (std.mem.eql(u8, step_name, "build") or std.mem.eql(u8, step_name, "install"))
                .build
            else
                .custom;

            try config.steps.append(.{
                .name = try allocator.dupe(u8, step_name),
                .description = try allocator.dupe(u8, description),
                .step_type = step_type,
            });
        }
    }

    print("Found {} build steps\n", .{config.steps.items.len});
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

    // Always add a default build task first
    try writer.writeAll("        {\n");
    try writer.writeAll("            \"label\": \"zig build\",\n");
    try writer.writeAll("            \"type\": \"shell\",\n");
    try writer.writeAll("            \"command\": \"zig\",\n");
    try writer.writeAll("            \"args\": [\"build\"],\n");
    try writer.writeAll("            \"group\": {\n");
    try writer.writeAll("                \"kind\": \"build\",\n");
    try writer.writeAll("                \"isDefault\": true\n");
    try writer.writeAll("            },\n");
    try writer.writeAll("            \"presentation\": {\n");
    try writer.writeAll("                \"echo\": true,\n");
    try writer.writeAll("                \"reveal\": \"always\",\n");
    try writer.writeAll("                \"focus\": false,\n");
    try writer.writeAll("                \"panel\": \"shared\",\n");
    try writer.writeAll("                \"showReuseMessage\": true,\n");
    try writer.writeAll("                \"clear\": false\n");
    try writer.writeAll("            },\n");
    try writer.writeAll("            \"problemMatcher\": [\"$gcc\"]\n");
    try writer.writeAll("        }");

    // Add comma if there are more tasks
    if (config.steps.items.len > 0) {
        try writer.writeAll(",\n");
    }

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

    // Find the appropriate build task name
    var build_task_name: []const u8 = "zig build"; // default
    var has_build_task = false;
    
    for (config.steps.items) |step| {
        if (std.mem.eql(u8, step.name, "build") or std.mem.eql(u8, step.name, "install")) {
            build_task_name = try std.fmt.allocPrint(allocator, "zig {s}", .{step.name});
            has_build_task = true;
            break;
        }
    }
    defer if (has_build_task) allocator.free(build_task_name);

    // Find one run step to create debug configurations
    for (config.steps.items) |step| {
        if (step.step_type == .run) {
            
            try writer.print("        {{\n", .{});
            try writer.print("            \"name\": \"Debug {s}\",\n", .{config.project_name});
            try writer.print("            \"type\": \"cppdbg\",\n", .{});
            try writer.print("            \"request\": \"launch\",\n", .{});
            try writer.print("            \"program\": \"${{workspaceFolder}}/zig-out/bin/{s}\",\n", .{config.project_name});
            try writer.print("            \"args\": [],\n", .{});
            try writer.print("            \"stopAtEntry\": false,\n", .{});
            try writer.print("            \"cwd\": \"${{workspaceFolder}}\",\n", .{});
            try writer.print("            \"environment\": [],\n", .{});
            try writer.print("            \"preLaunchTask\": \"{s}\",\n", .{build_task_name});
            try writer.print("            \"osx\": {{\n", .{});
            try writer.print("                \"MIMode\": \"lldb\"\n", .{});
            try writer.print("            }},\n", .{});
            try writer.print("            \"linux\": {{\n", .{});
            try writer.print("                \"MIMode\": \"gdb\",\n", .{});
            try writer.print("                \"setupCommands\": [\n", .{});
            try writer.print("                    {{\n", .{});
            try writer.print("                        \"description\": \"Enable pretty-printing for gdb\",\n", .{});
            try writer.print("                        \"text\": \"-enable-pretty-printing\",\n", .{});
            try writer.print("                        \"ignoreFailures\": true\n", .{});
            try writer.print("                    }}\n", .{});
            try writer.print("                ]\n", .{});
            try writer.print("            }},\n", .{});
            try writer.print("            \"windows\": {{\n", .{});
            try writer.print("                \"type\": \"cppvsdbg\",\n", .{});
            try writer.print("                \"console\": \"integratedTerminal\"\n", .{});
            try writer.print("            }}\n", .{});
            try writer.print("        }}", .{});
            
            break; // Only add one debug configuration
        }
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

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;