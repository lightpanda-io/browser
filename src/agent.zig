pub const Agent = @import("agent/Agent.zig");
pub const ToolExecutor = @import("agent/ToolExecutor.zig");
pub const Terminal = @import("agent/Terminal.zig");
pub const Command = @import("agent/Command.zig");
pub const CommandExecutor = @import("agent/CommandExecutor.zig");
pub const Recorder = @import("agent/Recorder.zig");
pub const Verifier = @import("agent/Verifier.zig");
pub const SlashCommand = @import("agent/SlashCommand.zig");
pub const listModels = @import("agent/list_models.zig").run;

test {
    _ = Agent;
    _ = Command;
    _ = CommandExecutor;
    _ = Recorder;
    _ = Verifier;
    _ = SlashCommand;
}
