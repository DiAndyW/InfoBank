import NoteBankKit
import SwiftUI

struct StorageFailureView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 12) {
            Text(storageOpenFailureMessage(error)).font(.headline)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
