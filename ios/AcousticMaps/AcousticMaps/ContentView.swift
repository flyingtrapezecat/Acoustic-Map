import SwiftUI

struct ContentView: View {
    @ObservedObject var connection: ConnectionTest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AcousticMaps")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)

                Text(connection.instruction)
                    .font(.title2)

                Button {
                    // waits for server without freezing the screen
                    Task {
                        await connection.sendFakeUpdate()
                    }
                } label: {
                    Label(
                        connection.isSending
                            ? "Sending..."
                            : "Send Test Update",
                        systemImage: "paperplane.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(connection.isSending)
                .accessibilityLabel("Send test update to server")

                if let error = connection.errorMessage {
                    Text("Error: \(error)")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                Text("Raw Server Reply")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text(connection.rawReply)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView(connection: ConnectionTest())
}
