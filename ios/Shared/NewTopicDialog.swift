import NoteBankKit
import SwiftUI

private struct NewTopicDialog: View {
    let problem: (String) -> String?
    let create: (String) throws -> Void
    let close: () -> Void
    @State private var name = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    private func save() {
        do {
            try create(name)
            close()
        } catch {
            failure = errorMessage(error)
        }
    }

    var body: some View {
        let reason = problem(name)
        let shown = failure ?? (name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : reason)
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text("New Topic").font(.headline)
                TextField("Topic name", text: $name)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if reason == nil { save() } }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 40)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        if shown != nil { RoundedRectangle(cornerRadius: 10).strokeBorder(.red, lineWidth: 1.5) }
                    }
                if let shown {
                    Text(shown).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(16)
            Divider()
            HStack(spacing: 0) {
                Button(action: close) { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44) }
                Divider()
                Button(action: save) { Text("Create").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44) }
                    .disabled(reason != nil)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .containerRelativeFrame(.horizontal) { width, _ in width * 0.75 }
        .accessibilityAddTraits(.isModal)
        .onChange(of: name) { failure = nil }
        .onAppear { focused = true }
    }
}

private struct NewTopicPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let problem: (String) -> String?
    let create: (String) throws -> Void
    @State private var covered = false
    @State private var visible = false

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, on in
                if on {
                    withoutAnimation { covered = true }
                } else {
                    withAnimation(.easeIn(duration: 0.15)) { visible = false } completion: {
                        withoutAnimation { covered = false }
                    }
                }
            }
            // A clear full-screen cover is what can sit above a sheet (Item actions) as well as the home screen.
            .fullScreenCover(isPresented: $covered) {
                ZStack {
                    Color.black.opacity(visible ? 0.35 : 0).ignoresSafeArea()
                    if visible {
                        NewTopicDialog(problem: problem, create: create) { isPresented = false }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .presentationBackground(.clear)
                .onAppear { withAnimation(.easeOut(duration: 0.2)) { visible = true } }
            }
    }
}

extension View {
    func newTopicDialog(isPresented: Binding<Bool>, problem: @escaping (String) -> String?, create: @escaping (String) throws -> Void) -> some View {
        modifier(NewTopicPresenter(isPresented: isPresented, problem: problem, create: create))
    }
}
