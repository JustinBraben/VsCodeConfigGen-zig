const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

// Public API for use in build.zig
pub fn generateVSCodeConfig(b: *std.Build, output_dir: ?[]const u8) !void {
    const allocator = b.allocator;
    const project_name = std.fs.path.basename(b.build_root.path orelse ".");
    
    // Use provided output_dir or default to .vscode
    const vscode_dir = output_dir orelse ".vscode";
    
    // Create .vscode directory
    std.fs.makeDirAbsolute(vscode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Extract build steps from the build graph
    var config = try extractBuildSteps(allocator, b, project_name);
    defer config.deinit();
    
    // Generate all VSCode configuration files
    try generateExtensionsJson(allocator, vscode_dir);
    try generateTasksJson(allocator, vscode_dir, &config);
    try generateLaunchJson(allocator, vscode_dir, &config);
    try generateSettingsJson(allocator, vscode_dir, &config);
    
    print("Generated VSCode configuration in: {s}\n", .{vscode_dir});
}

// Public API - add a build step that generates VSCode config
pub fn addVSCodeStep(b: *std.Build, output_dir: ?[]const u8) *std.Build.Step {
    const vscode_step = b.step("vscode", "Generate VSCode configuration files");
    
    const generate_step = VSCodeGenerateStep.create(b, output_dir);
    vscode_step.dependOn(&generate_step.step);
    
    return vscode_step;
}

const VSCodeConfig = struct {
    steps: ArrayList(BuildStep),
    project_name: []const u8,
    executables: ArrayList([]const u8),
    
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

fn extractBuildSteps(allocator: Allocator, b: *std.Build, project_name: []const u8) !VSCodeConfig {
    var config = VSCodeConfig{
        .steps = ArrayList(VSCodeConfig.BuildStep).init(allocator),
        .project_name = project_name,
        .executables = ArrayList([]const u8).init(allocator),
    };
    
    // Walk through the build graph to find steps and executables
    var step_iterator = b.top_level_steps.iterator();
    while (step_iterator.next()) |entry| {
        const step_name = entry.key_ptr.*;
        const step = entry.value_ptr.*;
        
        // Determine step type based on name and dependencies
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
            .description = try allocator.dupe(u8, step.description),
            .step_type = step_type,
        });
    }
    
    // Find executables by looking for CompileStep artifacts
    // Note: This is a simplified approach - in practice you might want to 
    // examine the actual install steps to find the real executable names
    try config.executables.append(try allocator.dupe(u8, project_name));
    
    return config;
}

// Custom build step for generating VSCode config
const VSCodeGenerateStep = struct {
    step: std.Build.Step,
    output_dir: ?[]const u8,
    
    pub fn create(b: *std.Build, output_dir: ?[]const u8) *VSCodeGenerateStep {
        const self = b.allocator.create(VSCodeGenerateStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "generate-vscode-config",
                .owner = b,
                .makeFn = make,
            }),
            .output_dir = output_dir,
        };
        return self;
    }
    
    fn make(step: *std.Build.Step, progress: std.Progress.Node) !void {
        _ = progress;
        const self: *VSCodeGenerateStep = @fieldParentPtr("step", step);
        try generateVSCodeConfig(step.owner, self.output_dir);
    }
};

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

    // Create debug configurations for each executable
    for (config.executables.items, 0..) |exe_name, i| {
        const comma = if (i < config.executables.items.len - 1) "," else "";
        
        try writer.print("        {{\n", .{});
        try writer.print("            \"name\": \"Debug {s}\",\n", .{exe_name});
        try writer.print("            \"type\": \"cppdbg\",\n", .{});
        try writer.print("            \"request\": \"launch\",\n", .{});
        try writer.print("            \"program\": \"${{workspaceFolder}}/zig-out/bin/{s}\",\n", .{exe_name});
        try writer.print("            \"args\": [],\n", .{});
        try writer.print("            \"stopAtEntry\": false,\n", .{});
        try writer.print("            \"cwd\": \"${{workspaceFolder}}\",\n", .{});
        try writer.print("            \"environment\": [],\n", .{});
        try writer.print("            \"preLaunchTask\": \"zig build\",\n", .{});
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
        try writer.print("        }}{s}\n", .{comma});
    }

    try writer.writeAll("    ]\n");
    try writer.writeAll("}\n");
}

fn generateSettingsJson(allocator: Allocator, output_dir: []const u8, config: *const VSCodeConfig) !void {
    _ = config; // Currently unused, but could be used for project-specific settings
    
    const settings_content =
        \\{
        \\    "debug.allowBreakpointsEverywhere": true,
        \\    "zig.buildOnSave": false,
        \\    "zig.buildFilePath": "${workspaceFolder}/build.zig",
        \\    "zig.zigPath": "zig",
        \\    "files.associations": {
        \\        "*.zig": "zig"
        \\    },
        \\    "editor.formatOnSave": true,
        \\    "editor.insertSpaces": true,
        \\    "editor.tabSize": 4
        \\}
        \\
    ;

    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, "settings.json" });
    defer allocator.free(file_path);

    const file = try std.fs.createFileAbsolute(file_path, .{});
    defer file.close();

    try file.writeAll(settings_content);
}

// For standalone usage
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        print("Usage: {s} <project_directory>\n", .{args[0]});
        print("This will generate VSCode config in <project_directory>/.vscode/\n", .{});
        return;
    }

    const project_dir = args[1];
    const vscode_dir = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, ".vscode" });
    defer allocator.free(vscode_dir);

    // Create a minimal Build instance for compatibility
    // Note: This is a simplified version for standalone usage
    print("Generating VSCode configuration for project in: {s}\n", .{project_dir});
    print("Output directory: {s}\n", .{vscode_dir});
    
    // For standalone usage, we'll create a simplified config
    const project_name = std.fs.path.basename(project_dir);
    var config = VSCodeConfig{
        .steps = ArrayList(VSCodeConfig.BuildStep).init(allocator),
        .project_name = project_name,
        .executables = ArrayList([]const u8).init(allocator),
    };
    defer config.steps.deinit();
    defer config.executables.deinit();
    
    // Add common build steps
    try config.steps.append(.{
        .name = try allocator.dupe(u8, "build"),
        .description = try allocator.dupe(u8, "Build the project"),
        .step_type = .build,
    });
    try config.steps.append(.{
        .name = try allocator.dupe(u8, "run"),
        .description = try allocator.dupe(u8, "Run the project"),
        .step_type = .run,
    });
    try config.steps.append(.{
        .name = try allocator.dupe(u8, "test"),
        .description = try allocator.dupe(u8, "Run tests"),
        .step_type = .@"test",
    });
    
    try config.executables.append(try allocator.dupe(u8, project_name));
    
    // Create .vscode directory
    std.fs.makeDirAbsolute(vscode_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Generate all VSCode configuration files
    try generateExtensionsJson(allocator, vscode_dir);
    try generateTasksJson(allocator, vscode_dir, &config);
    try generateLaunchJson(allocator, vscode_dir, &config);
    try generateSettingsJson(allocator, vscode_dir, &config);
    
    print("Successfully generated VSCode configuration!\n", .{});
}

test "vscode config generation" {
    // Basic test to ensure the module compiles and basic functions work
    const testing = std.testing;
    var config = VSCodeConfig{
        .steps = ArrayList(VSCodeConfig.BuildStep).init(testing.allocator),
        .project_name = "test_project",
        .executables = ArrayList([]const u8).init(testing.allocator),
    };
    defer config.steps.deinit();
    defer config.executables.deinit();
    
    try config.steps.append(.{
        .name = try testing.allocator.dupe(u8, "test"),
        .description = try testing.allocator.dupe(u8, "Run tests"),
        .step_type = .@"test",
    });
    
    try testing.expect(config.steps.items.len == 1);
    try testing.expectEqualStrings("test", config.steps.items[0].name);
}