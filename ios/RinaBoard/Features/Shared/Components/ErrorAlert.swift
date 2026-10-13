import SwiftUI

extension View {
    /// Presents a model's transient error string as a system alert.
    /// Dismissing clears the message through the binding, so `nil` stays the
    /// model's single "no error" state.
    func errorAlert(_ message: Binding<String?>) -> some View {
        #if targetEnvironment(macCatalyst)
        // Catalyst can create an accessible native alert whose window paints
        // entirely blank. Host the same error content in SwiftUI on the Mac.
        sheet(isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            VStack(alignment: .leading, spacing: 20) {
                Text("出错了")
                    .font(.headline)
                Text(message.wrappedValue ?? "")
                    .textSelection(.enabled)
                    .accessibilityIdentifier("error.message")
                HStack {
                    Spacer()
                    Button("好") { message.wrappedValue = nil }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("error.dismiss")
                }
            }
            .padding(24)
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 480, minHeight: 160)
        }
        #else
        alert("出错了", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
        #endif
    }
}
