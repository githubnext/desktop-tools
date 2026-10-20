import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
public protocol FileDialogPathProviding: Sendable {
    func chooseFileDialogPath(_ request: FileDialogPathRequest) async throws -> DialogActionResult
}

extension DialogService: FileDialogPathProviding {
    public func chooseFileDialogPath(_ request: FileDialogPathRequest) async throws -> DialogActionResult {
        try await self.runDialogOperation(scope: Self.forcedDismissMutationScope, access: .write) {
            let choice = try FileDialogPathChoice(request.path)
            let candidates = try await self.targetedDialogCandidates(
                target: request.target,
                membership: .structuralMutation)
            guard candidates.count == 1, let candidate = candidates.first else {
                throw self.dialogCandidateRefusal(target: request.target, candidates: candidates)
            }
            guard self.isFileDialogElement(candidate.dialog) else {
                throw Self.attributedDialogActionFailure(
                    .preDispatchRefusal(
                        reason: .operationUnsupported,
                        message: "The dialog is not an Open or Save panel; no path was entered.",
                        hint: "Answer it with a button or field instead."),
                    target: candidate.target)
            }
            let plan = ForegroundDialogPlan(
                target: candidate.target,
                resolvedTarget: candidate.resolvedTarget,
                window: candidate.window,
                dialog: candidate.dialog)
            return try await self.executeFileDialogPath(choice, plan: plan, focus: request.focus)
        }
    }

    private func executeFileDialogPath(
        _ choice: FileDialogPathChoice,
        plan: ForegroundDialogPlan,
        focus: DialogForegroundFocusPolicy) async throws -> DialogActionResult
    {
        var sequence = DesktopActionSequenceAccumulator()
        do {
            try await self.revalidateDialogTarget(
                target: plan.target,
                retainedWindow: plan.window,
                retainedDialog: plan.dialog,
                operation: "file-dialog path")
            try await self.establishDialogWindowFocus(plan: plan, policy: focus)
            try self.requireFileDialogKeyboardFocus(plan, autoFocus: focus.autoFocus)

            let dialog = plan.dialog
            if let outcome = try await self.ensureFileDialogExpandedIfNeeded(dialog: dialog) {
                sequence.record(.outcome(outcome))
            }
            let isSavePanel = self.fileDialogNameField(in: dialog) != nil
            // A Save panel takes the name in its own field; an Open panel selects the file Go to Folder reveals.
            let destination = isSavePanel ? choice.directory : choice.path
            var method: String
            if destination == choice.directory, let pathField = self.fileDialogPathField(in: dialog) {
                method = "path_textfield"
                try sequence.record(.outcome(self.focusTextField(pathField)))
                try sequence.record(.outcome(self.setFileDialogField(pathField, to: destination)))
                try self.requireFileDialogKeyboardFocus(plan, autoFocus: focus.autoFocus)
                try sequence.record(.outcome(self.fileDialogGlobalInput(operation: "commit the path field") {
                    try self.syntheticInputDriver.tapKey(.return, modifiers: [])
                }))
                try await Task.sleep(for: .milliseconds(250))
                if self.fileDialogDirectory(in: dialog) != choice.directory {
                    method += "+go_to_folder"
                    try await self.goToFolder(destination, plan: plan, focus: focus, sequence: &sequence)
                }
            } else {
                method = "go_to_folder"
                try await self.goToFolder(destination, plan: plan, focus: focus, sequence: &sequence)
            }

            // Navigation can rebuild the panel's fields, so find the name field again.
            let nameField = isSavePanel ? self.fileDialogNameField(in: dialog) : nil
            if let fileName = choice.fileName, let nameField {
                try sequence.record(.outcome(self.focusTextField(nameField)))
                try sequence.record(.outcome(self.setFileDialogField(nameField, to: fileName)))
                try await Task.sleep(for: .milliseconds(150))
            }

            let directory = self.fileDialogDirectory(in: dialog)
            let name = nameField.flatMap { $0.value() as? String }
            let directoryVerified = directory == choice.directory
            let nameVerified = choice.fileName.map { name == $0 } ?? true
            // An Open panel's selection has no readback here, so choosing a file in one stays unverified.
            let verified = directoryVerified && nameVerified && (choice.fileName == nil || nameField != nil)

            var details = Self.dialogTargetDetails(plan.target)
            details.merge([
                "path": choice.path,
                "directory": choice.directory,
                "path_navigation_method": method,
                "panel": isSavePanel ? "save" : "open",
                "directory_readback": directory ?? "",
                "directory_verified": String(directoryVerified),
            ]) { _, new in new }
            if let fileName = choice.fileName {
                details["filename"] = fileName
                details["filename_readback"] = name ?? ""
                details["filename_verified"] = String(nameField != nil && nameVerified)
            }

            let resolution = sequence.successResolution()
            guard let accepted = resolution.outcome, let delivery = accepted.delivery else {
                throw DesktopActionFailure.indeterminate(
                    delivery: nil,
                    evidence: .completionUnknown,
                    unitCount: resolution.mutationDisposition.unitCount,
                    message: "File-dialog path entry finished without one canonical outcome.",
                    hint: "Observe the file dialog before retrying.")
            }
            let outcome: DesktopActionOutcome = verified
                ? .confirmedChange(delivery: delivery, unitCount: accepted.dispatchState.unitCount)
                : .dispatchedUnverified(
                    delivery: delivery,
                    evidence: .deliveryAccepted,
                    unitCount: accepted.dispatchState.unitCount)
            return DialogActionResult(
                success: true,
                action: .handleFileDialog,
                details: details,
                outcome: outcome,
                targetReceipt: plan.target.actionTargetReceipt,
                targetWindowIdentity: plan.target.identity,
                targetWindowBounds: plan.target.bounds,
                focusedElement: plan.target.focusedElement,
                resolvedTarget: plan.resolvedTarget)
        } catch {
            throw Self.preservingFileDialogFailure(error, after: sequence, target: plan.target)
        }
    }

    /// Opens Go to Folder, fills its field, and commits it while the retained panel keeps keyboard focus.
    private func goToFolder(
        _ path: String,
        plan: ForegroundDialogPlan,
        focus: DialogForegroundFocusPolicy,
        sequence: inout DesktopActionSequenceAccumulator) async throws
    {
        let before = self.collectTextFields(from: plan.dialog)
        try self.requireFileDialogKeyboardFocus(plan, autoFocus: focus.autoFocus)
        try sequence.record(.outcome(self.fileDialogGlobalInput(operation: "open Go to Folder") {
            try self.syntheticInputDriver.hotkey(keys: ["cmd", "shift", "g"], holdDuration: 0.05)
        }))
        try await Task.sleep(for: .milliseconds(300))
        let added = self.collectTextFields(from: plan.dialog).filter { field in
            !before.contains { Self.sameElement($0, field) }
        }
        if added.count == 1, let field = added.first,
           field.isAttributeSettable(named: AXAttributeNames.kAXValueAttribute)
        {
            try sequence.record(.outcome(self.setFileDialogField(field, to: path)))
        } else {
            try sequence.record(.outcome(self.fileDialogGlobalInput(operation: "select Go to Folder text") {
                try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.05)
            }))
            try await Task.sleep(for: .milliseconds(75))
            try sequence.record(.outcome(self.typeTextValue(path, delay: 5000)))
        }
        try sequence.record(.outcome(self.fileDialogGlobalInput(operation: "commit Go to Folder") {
            try self.syntheticInputDriver.tapKey(.return, modifiers: [])
        }))
        try await Task.sleep(for: .milliseconds(450))
    }

    private func setFileDialogField(_ field: Element, to value: String) throws -> DesktopActionOutcome {
        if field.isAttributeSettable(named: AXAttributeNames.kAXValueAttribute),
           field.setValue(value, forAttribute: AXAttributeNames.kAXValueAttribute)
        {
            return .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
        }
        var sequence = DesktopActionSequenceAccumulator()
        try sequence.record(.outcome(self.fileDialogGlobalInput(operation: "select the field text") {
            try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.05)
        }))
        usleep(75000)
        try sequence.record(.outcome(self.typeTextValue(value, delay: 5000)))
        guard let outcome = sequence.successResolution().outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Typing into the file-dialog field finished without one canonical outcome.",
                hint: "Observe the file dialog before retrying.")
        }
        return outcome
    }

    private func requireFileDialogKeyboardFocus(_ plan: ForegroundDialogPlan, autoFocus: Bool) throws {
        do {
            try Task.checkCancellation()
            try self.focusService.requireDialogGlobalKeyboardFocus(
                target: plan.target,
                retainedWindow: plan.window,
                dialog: plan.dialog)
        } catch {
            throw Self.dialogWindowFocusFailure(autoFocus: autoFocus, cause: error)
        }
    }

    private func fileDialogPathField(in dialog: Element) -> Element? {
        self.collectTextFields(from: dialog).first { $0.attribute(Attribute<String>("AXIdentifier")) == "PathTextField" }
    }

    private func fileDialogNameField(in dialog: Element) -> Element? {
        self.collectTextFields(from: dialog).first {
            $0.attribute(Attribute<String>("AXIdentifier")) == "saveAsNameTextField"
        }
    }

    /// The panel's current directory, read from its path field; nil when the panel doesn't expose one.
    private func fileDialogDirectory(in dialog: Element) -> String? {
        guard let value = self.fileDialogPathField(in: dialog)?.value() as? String, value.hasPrefix("/") else {
            return nil
        }
        return FileDialogPathChoice.canonical(value)
    }
}

struct FileDialogPathChoice: Equatable {
    let path: String
    let directory: String
    let fileName: String?

    /// An existing directory is chosen as the panel's directory; anything else names a file in an existing one.
    init(_ path: String) throws {
        let canonical = Self.canonical(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue {
            self.init(path: canonical, directory: canonical, fileName: nil)
            return
        }
        // A missing file's symlinks don't resolve, so resolve its folder on its own.
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let parent = Self.canonical(url.deletingLastPathComponent().path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/",
              FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "The path's folder \(parent) doesn't exist; no path was entered.",
                hint: "Choose a path inside an existing folder.")
        }
        self.init(path: (parent as NSString).appendingPathComponent(name), directory: parent, fileName: name)
    }

    init(path: String, directory: String, fileName: String?) {
        self.path = path
        self.directory = directory
        self.fileName = fileName
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
