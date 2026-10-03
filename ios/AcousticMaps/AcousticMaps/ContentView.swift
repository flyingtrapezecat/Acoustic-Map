import SwiftUI

struct ContentView: View {
    @ObservedObject var connection: ConnectionTest
    @StateObject private var locationReader = LocationReader()
    @State private var tripActive = false
    @StateObject private var voice = VoiceStream()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AcousticMaps")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)

                Text(connection.instruction)
                    .font(.title2)

                Toggle("Trip Active", isOn: $tripActive)
                    .accessibilityLabel("Trip active")
                    .onChange(of: tripActive) { _, active in
                        if active {
                            locationReader.start()
                        } else {
                            locationReader.stop()
                        }
                    }

                Text(locationReader.status)
                
                Button {
                    Task {
                        await voice.startListening(connection: connection)
                    }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 30))
                        .frame(width: 84, height: 84)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .disabled(voice.isActive || voice.isPreparing)
                .accessibilityLabel("Speak destination")

                Text(voice.status)

                if !voice.partialText.isEmpty {
                    Text(voice.partialText)
                        .textSelection(.enabled)
                }

                if let error = voice.errorMessage {
                    Text("Voice error: \(error)")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let fix = locationReader.location {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latitude: \(fix.coordinate.latitude)")
                        Text("Longitude: \(fix.coordinate.longitude)")
                        Text("Accuracy: \(fix.horizontalAccuracy) meters")

                        // Check whether fresh readings are arriving.
                        Text(
                            "Reading time: \(fix.timestamp.formatted(date: .omitted, time: .standard))"
                        )

                        if let source = fix.sourceInformation {
                            Text(
                                "Simulated: \(source.isSimulatedBySoftware ? "Yes" : "No")"
                            )
                        } else {
                            Text("Simulated: unknown")
                        }

                        if let heading = locationReader.headingDegrees {
                            Text("Heading: \(heading) degrees")
                        } else {
                            Text("Heading: unavailable")
                        }

                        if fix.course >= 0 {
                            Text("Course: \(fix.course) degrees")
                        } else {
                            Text("Course: unavailable")
                        }

                        if fix.speed >= 0 {
                            Text("Speed: \(fix.speed) meters per second")
                        } else {
                            Text("Speed: unavailable")
                        }
                    }
                    .font(.body.monospacedDigit())
                }

                Button {
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
        
        .onAppear {
                    // Location callbacks send updates, including while locked.
                    locationReader.onUpdate = { fix, heading in
                        await connection.sendRealUpdate(
                            location: fix,
                            heading: heading
                        )
                    }
                }
            }
        }

#Preview {
    ContentView(connection: ConnectionTest())
}
