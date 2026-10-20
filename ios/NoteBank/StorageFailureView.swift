import SwiftUI

struct StorageFailureView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 12) {
            Text("NoteBank couldn't open its storage").font(.headline)
            Text(error.localizedDescription).font(.subheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
