import AppKit
import Common

struct MoveWorkspaceToMonitorCommand: Command {
    let args: MoveWorkspaceToMonitorCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let focusedWorkspace = target.workspace
        let prevMonitor = focusedWorkspace.workspaceMonitor

        switch args.target.val.resolve(target.workspace.workspaceMonitor, wrapAround: args.wrapAround) {
            case .success(let targetMonitor):
                if targetMonitor.monitorId_oneBased == prevMonitor.monitorId_oneBased {
                    return .succ
                }
                if args.swap && (monitors.count == 2 || args.target.val.directionOrNil != nil) {
                    guard focusedWorkspace.isVisible else {
                        return .fail(io.err("Can't swap invisible workspace '\(focusedWorkspace.name)'"))
                    }
                    let targetWorkspace = targetMonitor.activeWorkspace
                    if prevMonitor.swapActiveWorkspace(with: targetMonitor) {
                        return .succ
                    } else {
                        return .fail(io.err(
                            "Can't swap workspace '\(focusedWorkspace.name)' with workspace '\(targetWorkspace.name)'. workspace-to-monitor-force-assignment doesn't allow it",
                        ))
                    }
                } else if targetMonitor.setActiveWorkspace(focusedWorkspace) {
                    let stubWorkspace = getStubWorkspace(for: prevMonitor)
                    check(
                        prevMonitor.setActiveWorkspace(stubWorkspace),
                        "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(prevMonitor)",
                    )
                    return .succ
                } else {
                    return .fail(io.err(
                        "Can't move workspace '\(focusedWorkspace.name)' to monitor '\(targetMonitor.name)'. workspace-to-monitor-force-assignment doesn't allow it",
                    ))
                }
            case .failure(let msg):
                return .fail(io.err(msg))
        }
    }
}
