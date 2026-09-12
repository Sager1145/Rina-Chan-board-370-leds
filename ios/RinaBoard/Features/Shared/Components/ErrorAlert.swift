import SwiftUI

extension View {
    /// Presents a model's transient error string as a system alert.
    /// Dismissing clears the message through the binding, so `nil` stays the
    /// model's single "no error" state.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("出错了", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
