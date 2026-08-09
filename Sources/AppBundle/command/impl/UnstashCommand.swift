import Common

struct UnstashCommand: Command {
    let args: UnstashCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let windowId = args.windowId else { return .fail(io.err("--window-id is mandatory")) }
        guard let window = Window.get(byId: windowId) else {
            return .fail(io.err("Invalid <window-id> \(windowId) passed to --window-id"))
        }
        do {
            try await StashedWindows.restore(window)
            return .succ
        } catch {
            return .fail(io.err(error.localizedDescription))
        }
    }
}
