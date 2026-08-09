public struct StashPickerCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .stashPicker,
        help: stash_picker_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
            "--all": trueBoolFlag(\.all),
        ],
        posArgs: [],
        conflictingOptions: [["--workspace", "--all"]],
    )

    public var all: Bool = false
}
