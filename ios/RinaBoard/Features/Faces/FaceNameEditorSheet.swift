import SwiftUI

/// Native, asynchronous naming form shared by rename and editor-save.
/// A failure keeps the sheet and the user's text instead of dismissing it.
struct FaceNameEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// nil means success; otherwise the returned message stays in this sheet.
    let submit: @MainActor (String) async -> String?
    @State private var name: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(title: String, initialName: String,
         submit: @escaping @MainActor (String) async -> String?) {
        self.title = title
        self.submit = submit
        _name = State(initialValue: initialName)
    }

    private var cleaned: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !cleaned.isEmpty && cleaned.utf8.count <= 64 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                        .focused($nameFocused)
                        .disabled(isSubmitting)
                        .submitLabel(.done)
                        .onSubmit { save() }
                } footer: {
                    Text("名称最长 64 字节（约 21 个汉字），不能为空")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if isSubmitting {
                    Section { ProgressView() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid || isSubmitting)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .presentationDetents([.medium, .rinaTall])
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard isValid, !isSubmitting else { return }
        let submittedName = cleaned
        isSubmitting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            if let message = await submit(submittedName) {
                errorMessage = message
            } else {
                dismiss()
            }
        }
    }
}
