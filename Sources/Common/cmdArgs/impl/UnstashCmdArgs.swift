public struct UnstashCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .unstash,
        help: unstash_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [],
    )
}

func parseUnstashCmdArgs(_ args: StrArrSlice) -> ParsedCmd<UnstashCmdArgs> {
    parseSpecificCmdArgs(UnstashCmdArgs(rawArgs: args), args)
        .filter("Mandatory option is not specified (--window-id)") { $0.windowId != nil }
}
