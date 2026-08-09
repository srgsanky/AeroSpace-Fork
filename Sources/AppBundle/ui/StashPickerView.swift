import AppKit
import HotKey
import SwiftUI

struct StashPickerCandidate: Identifiable {
    let windowId: UInt32
    let appName: String
    let title: String
    let workspaceName: String
    let icon: NSImage?

    var id: UInt32 { windowId }
}

@MainActor
final class StashPickerModel: ObservableObject {
    @Published var heading = "Stashed windows"
    @Published var candidates: [StashPickerCandidate] = []
    @Published var selectedWindowId: UInt32?
    @Published var emptyMessage: String?
    var showsWorkspace = false

    var selectedIndex: Int? {
        guard let selectedWindowId else { return nil }
        return candidates.firstIndex { $0.windowId == selectedWindowId }
    }

    func replaceCandidates(_ newCandidates: [StashPickerCandidate]) {
        let previousSelection = selectedWindowId
        let previousIndex = selectedIndex
        candidates = newCandidates
        if let previousSelection, newCandidates.contains(where: { $0.windowId == previousSelection }) {
            selectedWindowId = previousSelection
        } else if let previousIndex, !newCandidates.isEmpty {
            selectedWindowId = newCandidates[previousIndex % newCandidates.count].windowId
        } else {
            selectedWindowId = newCandidates.first?.windowId
        }
    }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    func select(windowId: UInt32) {
        if candidates.contains(where: { $0.windowId == windowId }) { selectedWindowId = windowId }
    }

    private func moveSelection(by offset: Int) {
        guard !candidates.isEmpty else { return }
        let current = selectedIndex ?? 0
        selectedWindowId = candidates[(current + offset + candidates.count) % candidates.count].windowId
    }
}

public final class StashPickerPanel: NSPanelHud {
    @MainActor public static let shared = StashPickerPanel()
    private let panelWidth: CGFloat = 680

    override private init() {
        super.init()
    }

    @MainActor
    func show(model: StashPickerModel, on monitor: Monitor) {
        let rowCount = max(1, min(model.candidates.count, 8))
        let height = model.emptyMessage == nil ? CGFloat(102 + rowCount * 54) : 104
        let hostingView = NSHostingView(rootView: StashPickerView(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: height)
        contentView = hostingView
        setFrame(frame(on: monitor, width: panelWidth, height: height), display: true)
        orderFrontRegardless()
    }

    @MainActor
    func reposition(on monitor: Monitor) {
        guard isVisible else { return }
        setFrame(frame(on: monitor, width: frame.width, height: frame.height), display: true)
    }

    private func frame(on monitor: Monitor, width: CGFloat, height: CGFloat) -> NSRect {
        let x = monitor.visibleRect.minX + (monitor.visibleRect.width - width) / 2
        let normalizedTop = monitor.visibleRect.minY + min(120, monitor.visibleRect.height * 0.12)
        let appKitY = mainMonitor.height - normalizedTop - height
        return NSRect(x: x, y: appKitY, width: width, height: height)
    }
}

@MainActor
final class StashPickerController {
    static let shared = StashPickerController()

    let model = StashPickerModel()
    private var scope: StashScope?
    private var previousMode: String?
    private var pickerHotkeys: [HotKey] = []
    private var emptyMessageTimer: Timer?
    private var refreshGeneration = UUID()

    var isOpen: Bool { scope != nil }

    func open(scope newScope: StashScope) async {
        if isOpen { await dismiss() }
        emptyMessageTimer?.invalidate()
        scope = newScope
        previousMode = activeMode
        configureHeading(for: newScope)
        await refreshCandidates()

        guard !model.candidates.isEmpty else {
            let workspaceName = scopeWorkspace?.name ?? focus.workspace.name
            model.emptyMessage = newScope.isAll
                ? "No stashed windows"
                : "No stashed windows on workspace \(workspaceName)"
            StashPickerPanel.shared.show(model: model, on: targetMonitor)
            scope = nil
            previousMode = nil
            emptyMessageTimer = .scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                Task.startUnstructured { @MainActor in
                    StashPickerPanel.shared.close()
                }
            }
            return
        }

        model.emptyMessage = nil
        setActiveModeHotkeysEnabled(false)
        installPickerHotkeys()
        StashPickerPanel.shared.show(model: model, on: targetMonitor)
    }

    func dismissIfOpen() async {
        if isOpen {
            await dismiss()
        } else {
            emptyMessageTimer?.invalidate()
            emptyMessageTimer = nil
            model.emptyMessage = nil
            StashPickerPanel.shared.close()
        }
    }

    func dismiss() async {
        guard isOpen || !pickerHotkeys.isEmpty || previousMode != nil else { return }
        refreshGeneration = UUID()
        emptyMessageTimer?.invalidate()
        emptyMessageTimer = nil
        uninstallPickerHotkeys()
        StashPickerPanel.shared.close()
        scope = nil
        model.emptyMessage = nil
        let mode = previousMode
        previousMode = nil
        setActiveModeHotkeysEnabled(true)
        await activateMode_nonCancellable(mode)
    }

    func restoreSelectedInLightSession() async {
        guard let guardToken = RunSessionGuard.isServerEnabled else {
            await dismiss()
            return
        }
        try? await runLightSession(.hotkeyBinding, guardToken) {
            await self.restoreSelected()
        }
    }

    private func restoreSelected() async {
        guard let id = model.selectedWindowId, let window = Window.get(byId: id), window.isStashed else {
            await refreshCandidates()
            return
        }
        do {
            try await StashedWindows.restore(window)
            await dismiss()
        } catch {
            await refreshCandidates()
        }
    }

    func refreshAfterWindowClosed() async {
        guard isOpen else { return }
        await refreshCandidates()
        if model.candidates.isEmpty { await dismiss() }
    }

    func reconcileAfterDisplayChange() async {
        guard isOpen else { return }
        guard !monitors.isEmpty else {
            await dismiss()
            return
        }
        await refreshCandidates()
        if model.candidates.isEmpty {
            await dismiss()
        } else {
            StashPickerPanel.shared.reposition(on: targetMonitor)
        }
    }

    private func refreshCandidates() async {
        guard let scope else { return }
        let generation = UUID()
        refreshGeneration = generation
        var result: [StashPickerCandidate] = []
        for window in StashedWindows.candidates(scope) {
            let title = (try? await window.getTitle(.nonCancellable)) ?? ""
            guard generation == refreshGeneration else { return }
            guard window.isStashed else { continue }
            let icon = NSRunningApplication(processIdentifier: window.app.pid)?.icon
            result.append(StashPickerCandidate(
                windowId: window.windowId,
                appName: window.app.name ?? "Unknown application",
                title: title,
                workspaceName: window.nodeWorkspace?.name ?? "",
                icon: icon,
            ))
        }
        model.replaceCandidates(result)
        if StashPickerPanel.shared.isVisible {
            StashPickerPanel.shared.show(model: model, on: targetMonitor)
        }
    }

    private func configureHeading(for scope: StashScope) {
        switch scope {
            case .workspace(let workspace):
                model.heading = "Stashed windows — workspace \(workspace.name)"
                model.showsWorkspace = false
            case .all:
                model.heading = "Stashed windows — all workspaces"
                model.showsWorkspace = true
        }
    }

    private var scopeWorkspace: Workspace? {
        guard let scope else { return nil }
        if case .workspace(let workspace) = scope { return workspace }
        return nil
    }

    private var targetMonitor: Monitor {
        scopeWorkspace?.workspaceMonitor ?? focus.workspace.workspaceMonitor
    }

    private func installPickerHotkeys() {
        uninstallPickerHotkeys()
        let mapping = config.keyMapping.resolve()
        let actions: [(Key?, @MainActor () -> Void)] = [
            (mapping["j"], { StashPickerController.shared.model.selectNext() }),
            (.downArrow, { StashPickerController.shared.model.selectNext() }),
            (mapping["k"], { StashPickerController.shared.model.selectPrevious() }),
            (.upArrow, { StashPickerController.shared.model.selectPrevious() }),
            (.return, {
                Task.startUnstructured { @MainActor in
                    await StashPickerController.shared.restoreSelectedInLightSession()
                }
            }),
            (.escape, {
                Task.startUnstructured { @MainActor in
                    await StashPickerController.shared.dismiss()
                }
            }),
        ]
        pickerHotkeys = actions.compactMap { key, action in
            key.map { key in
                HotKey(key: key, modifiers: [], keyDownHandler: {
                    Task.startUnstructured { @MainActor in action() }
                })
            }
        }
    }

    private func uninstallPickerHotkeys() {
        for hotkey in pickerHotkeys { hotkey.isEnabled = false }
        pickerHotkeys = []
    }
}

extension StashScope {
    fileprivate var isAll: Bool {
        if case .all = self { true } else { false }
    }
}

private struct StashPickerView: View {
    @ObservedObject var model: StashPickerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let emptyMessage = model.emptyMessage {
                Text(emptyMessage)
                    .font(.headline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityLabel(emptyMessage)
            } else {
                Text(model.heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.candidates) { candidate in
                                candidateRow(candidate)
                                    .id(candidate.id)
                            }
                        }
                    }
                    .onChange(of: model.selectedWindowId) { id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                Text("j/↓ next    k/↑ previous    enter restore    esc cancel")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func candidateRow(_ candidate: StashPickerCandidate) -> some View {
        let selected = candidate.windowId == model.selectedWindowId
        return HStack(spacing: 12) {
            if let icon = candidate.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 32, height: 32)
            }
            Text(candidate.appName)
                .fontWeight(.semibold)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            Text(candidate.title.isEmpty ? "Untitled window" : candidate.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
            if model.showsWorkspace {
                Text(candidate.workspaceName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(selected ? Color.accentColor.opacity(0.35) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.select(windowId: candidate.windowId) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.appName), \(candidate.title), workspace \(candidate.workspaceName)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text("Restore")) {
            model.select(windowId: candidate.windowId)
            Task.startUnstructured { @MainActor in
                await StashPickerController.shared.restoreSelectedInLightSession()
            }
        }
    }
}
