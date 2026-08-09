import Common

struct AccentCommand: Command {
    let args: AccentCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }

        switch window.windowParentCases {
            case .tilingContainer, .floatingWindowsContainer:
                break
            case .macosFullscreenWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosMinimizedWindowsContainer,
                 .macosPopupWindowsContainer,
                 .stashedWindowsContainer,
                 .unbound:
                return .fail(io.err(window.isStashed ? stashedWindowCommandError(window) : "Can't accent macOS minimized, fullscreen, hidden, popup, or unbound windows"))
        }

        if window.isAccent {
            do {
                try await window.returnToTiling(on: target.workspace, .nonCancellable)
            } catch {
                return .fail(io.err(bugPrompt()))
            }
        } else {
            if !window.isFloating {
                window.bindAsFloatingWindow(to: target.workspace)
            }
            window.isAccent = true
        }
        return .succ
    }
}
