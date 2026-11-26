import AppKit
import Foundation
import MSnipCore

/// 翻译设置窗：一键从兼容协议服务端 `/v1/models` 拉取模型列表并下拉选择
extension TranslationSettingsWindow {
    func onFetchModelsClicked() {
        commitCurrentFormEdits()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let prof = draft.profiles[selectedIndex]
        fetchModelsBtn.isEnabled = false
        testStatusLabel.setTextWithTooltip("正在拉取服务端模型列表…", color: GeekTheme.inkSecondary)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fetchModelsBtn.isEnabled = true }
            do {
                let models = try await LLMModelFetcher.fetchModels(profile: prof)
                self.testStatusLabel.setTextWithTooltip("✓ 已拉取 \(models.count) 个可用模型，请选择", color: GeekTheme.emerald)
                self.presentFetchedModelsMenu(models, currentModel: prof.model)
            } catch {
                self.testStatusLabel.setTextWithTooltip("✗ \(error.localizedDescription)", color: GeekTheme.amber)
            }
        }
    }

    private func presentFetchedModelsMenu(_ models: [String], currentModel: String) {
        let menu = NSMenu()
        let limit = 60
        for id in models.prefix(limit) {
            let item = NSMenuItem(title: id, action: #selector(onPickedFetchedModel(_:)), keyEquivalent: "")
            item.representedObject = id
            item.state = (id == currentModel) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        if models.count > limit {
            menu.addItem(.separator())
            let more = NSMenuItem(title: "共 \(models.count) 个模型（已显示前 \(limit) 项，其余可直接输入）", action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelInputBox.bounds.height + 3), in: modelInputBox)
    }

    @objc private func onPickedFetchedModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String,
              draft.profiles.indices.contains(selectedIndex) else { return }
        modelField.stringValue = modelID
        commitCurrentFormEdits()
        persistDraft()
        testStatusLabel.setTextWithTooltip("✓ 已选择模型：\(modelID)", color: GeekTheme.emerald)
    }

    func popAddProviderMenu() {
        commitCurrentFormEdits()
        ProviderAddAndPresetPopover.shared.showAddService(anchoredTo: addBtn) { [weak self] created in
            guard let self else { return }
            self.draft.profiles.append(created)
            self.selectedIndex = self.draft.profiles.count - 1
            self.isAdvancedExpanded = (created.kind == .customWebhook)
            self.persistDraft()
            self.refreshTopBarPopups()
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
            self.loadSelectedProfileIntoForm()
        }
    }

    func removeSelectedProvider() {
        guard draft.profiles.count > 1, draft.profiles.indices.contains(selectedIndex) else { NSSound.beep(); return }
        draft.profiles.remove(at: selectedIndex)
        selectedIndex = max(0, min(selectedIndex, draft.profiles.count - 1))
        if !draft.profiles.contains(where: { $0.id == draft.activeProfileID }) { draft.activeProfileID = draft.profiles.first?.id }
        isAdvancedExpanded = false
        persistDraft(); refreshTopBarPopups(); tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func onSelectLLMProtocolIndex(_ idx: Int) {
        let kinds = TranslationProviderKind.llmProtocolCases
        guard kinds.indices.contains(idx), draft.profiles.indices.contains(selectedIndex) else { return }
        commitCurrentFormEdits()
        let nextKind = kinds[idx]
        var p = draft.profiles[selectedIndex]
        guard p.kind != nextKind else { return }
        // 切换「接口格式」绝不擅自改写用户的接口地址、密钥、模型或预设归属
        p.kind = nextKind
        draft.profiles[selectedIndex] = p
        persistDraft()
        loadSelectedProfileIntoForm()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    func onSelectKindIndex(_ kIdx: Int) {
        guard draft.profiles.indices.contains(selectedIndex), TranslationProviderKind.allCases.indices.contains(kIdx) else { return }
        commitCurrentFormEdits()
        let newKind = TranslationProviderKind.allCases[kIdx]
        let tpl = TranslationProviderProfile.makePreset(newKind)
        var p = draft.profiles[selectedIndex]
        p.kind = newKind
        if p.endpoint.isEmpty { p.endpoint = tpl.endpoint }
        if p.model.isEmpty { p.model = tpl.model }
        if p.customBodyTemplate.isEmpty { p.customBodyTemplate = tpl.customBodyTemplate }
        if p.customResponsePath.isEmpty { p.customResponsePath = tpl.customResponsePath }
        draft.profiles[selectedIndex] = p
        loadSelectedProfileIntoForm()
    }

    func popLLMPresetMenu(from anchor: NSView) {
        commitCurrentFormEdits()
        let currentEndpoint = draft.profiles.indices.contains(selectedIndex) ? draft.profiles[selectedIndex].endpoint : ""
        ProviderAddAndPresetPopover.shared.showLLMPresetPicker(anchoredTo: anchor, currentEndpoint: currentEndpoint) { [weak self] preset in
            guard let self, self.draft.profiles.indices.contains(self.selectedIndex) else { return }
            self.commitCurrentFormEdits()
            var p = self.draft.profiles[self.selectedIndex]
            if preset == .customOpenAI {
                // 切换为「自定义 / 中转站」：完整保留当前「接口格式」，仅清理旧官网预设预填的地址与默认模型
                if let prevOfficial = LLMQuickPreset.match(endpoint: p.endpoint) {
                    p.endpoint = ""
                    if p.model == prevOfficial.defaultModel { p.model = "" }
                    if p.name == prevOfficial.shortName { p.name = preset.shortName }
                }
            } else {
                p.kind = preset.providerKind
                p.name = preset.shortName
                p.endpoint = preset.baseURL
                p.model = preset.defaultModel
            }
            self.draft.profiles[self.selectedIndex] = p
            self.persistDraft()
            self.loadSelectedProfileIntoForm()
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
            if preset == .customOpenAI && p.endpoint.isEmpty { self.window?.makeFirstResponder(self.endpointField) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === endpointField,
              draft.profiles.indices.contains(selectedIndex),
              draft.profiles[selectedIndex].kind.isLLMProtocol else { return }
        let ep = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = LLMQuickPreset.match(endpoint: ep)
        llmPresetPill.customDisplayTitle = matched?.shortName ?? "自定义 / 中转站"
        let hasLink = (matched?.consoleURL != nil)
        presetGetKeyBtn.isHidden = !hasLink
        let fullW = formScrollView.bounds.width - 114
        llmPresetPill.frame.size.width = hasLink ? (fullW - 94) : fullW
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if activeTab == .ocrAndLatex {
            commitOCRAndLatexEdits(); saveOCRAndLatexConfigs()
        } else if activeTab == .translation {
            commitCurrentFormEdits(); persistDraft()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        commitCurrentFormEdits(); commitOCRAndLatexEdits()
        persistDraft(); saveOCRAndLatexConfigs()
    }
}
