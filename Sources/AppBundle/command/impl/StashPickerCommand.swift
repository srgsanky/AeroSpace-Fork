import Common

struct StashPickerCommand: Command {
    let args: StashPickerCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let scope: StashScope = if args.all {
            .all
        } else if let workspaceName = args.workspaceName {
            .workspace(workspaceName.raw == "focused" ? focus.workspace : Workspace.get(byName: workspaceName.raw))
        } else {
            .workspace(focus.workspace)
        }
        await StashPickerController.shared.open(scope: scope)
        return .succ
    }
}
