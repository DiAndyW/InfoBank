import SwiftUI

@main
struct NewTopicChecksApp: App {
    var body: some Scene { WindowGroup { NewTopicFixture() } }
}

struct NewTopicFixture: View {
    @State private var naming = false
    @State private var created: [String] = []

    var body: some View {
        VStack {
            Button("New Topic…") { naming = true }
            Text("Created: \(created.joined(separator: ","))")
        }
        .newTopicDialog(isPresented: $naming) { name in
            name.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a name" : name.lowercased() == "old" ? "An archived Topic has that name." : nil
        } create: { name in
            if name == "broken" { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't save the Topic"]) }
            created.append(name)
        }
    }
}
