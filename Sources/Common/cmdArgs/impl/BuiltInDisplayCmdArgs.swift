public struct BuiltInDisplayCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .builtInDisplay,
        help: built_in_display_help_generated,
        flags: [:],
        posArgs: [ArgParser(\.toggle, parseToggleEnum)],
    )

    public var toggle: ToggleEnum = .toggle
}
