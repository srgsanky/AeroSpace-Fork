import Common

struct StashCommand: Command {
    let args: StashCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let window: Window?
        if let windowId = args.windowId {
            window = Window.get(byId: windowId)
            if window == nil { return .fail(io.err("Invalid <window-id> \(windowId) passed to --window-id")) }
        } else if let windowId = env.windowId {
            window = Window.get(byId: windowId)
            if window == nil { return .fail(io.err("Invalid <window-id> \(windowId) specified in \(AEROSPACE_WINDOW_ID) env variable")) }
        } else if let workspaceName = env.workspaceName {
            window = Workspace.get(byName: workspaceName).toLiveFocus().windowOrNil
        } else {
            window = focus.windowOrNil
        }
        guard let window else { return .fail(io.err(noWindowIsFocused)) }
        do {
            _ = try await StashedWindows.stash(window, failIfNoop: args.failIfNoop)
            return .succ
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
    }
}
