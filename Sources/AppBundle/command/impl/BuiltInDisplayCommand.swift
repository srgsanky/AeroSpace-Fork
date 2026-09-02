import Common

struct BuiltInDisplayCommand: Command {
    let args: BuiltInDisplayCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let request: BuiltInDisplayRequest = switch args.toggle {
            case .toggle: .toggle
            case .on: .on
            case .off: .off
        }
        let result = BuiltInDisplayController.shared.apply(request)
        switch result {
            case .changed(let isEnabled):
                return .succ(io.out("Built-in display is \(isEnabled ? "on" : "off")"))
            case .noOp(let isEnabled):
                return .succ(io.out("Built-in display is already \(isEnabled ? "on" : "off")"))
            case .refused(let message), .failed(let message):
                return .fail(io.err(message))
        }
    }
}
