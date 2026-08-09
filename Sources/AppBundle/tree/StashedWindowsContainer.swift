/// Workspace-owned windows that are deliberately excluded from visible layout and focus navigation.
///
/// Stash membership is structural. Physical corner parking is only a presentation detail and must
/// never be used as the source of truth for whether a window is stashed.
final class StashedWindowsContainer: TreeNode, NonLeafTreeNodeObject {
    @MainActor
    init(parent: Workspace) {
        super.init(parent: parent, adaptiveWeight: 1, index: INDEX_BIND_LAST)
    }
}
