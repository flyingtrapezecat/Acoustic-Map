import SwiftUI

struct ContentView: View {
    @ObservedObject var connection: ConnectionTest
    @StateObject private var locationReader = LocationReader()
    @StateObject private var voice = VoiceStream()
    @State private var destination = ""
    @State private var pendingCommand: String?
    @State private var showDiagnostics = false
    @State private var showPastTrips = false
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .title) private var instructionSize = 28

    private var currentState: String {
        if voice.isActive || voice.isPreparing { return "listening" }
        if pendingCommand != nil { return "thinking" }
        return connection.state
    }

    private var isOnRoute: Bool {
        ["navigating", "off_route"].contains(connection.state)
            || (!connection.routeLine.isEmpty && !["idle", "arrived"].contains(connection.state))
    }

    private var stateLabel: String {
        switch currentState {
        case "listening": return voice.isPreparing ? "Getting ready" : "Listening"
        case "thinking": return "Finding your way"
        case "navigating": return "On your way"
        case "off_route": return "Let's get back on track"
        case "arrived": return "You've arrived"
        default: return "Your walking companion"
        }
    }

    private var blobImage: String {
        switch currentState {
        case "thinking": return "BlobThinking"
        case "off_route": return "BlobScared"
        case "arrived": return "BlobHappy"
        case "navigating":
            return connection.lastHaptic == "turn_left" ? "BlobPointLeft" : "BlobPointRight"
        default: return "BlobNeutral"
        }
    }

    private var displayedInstruction: String {
        if currentState == "listening" {
            return voice.partialText.isEmpty ? "I'm listening." : voice.partialText
        }
        if pendingCommand != nil {
            return locationReader.location == nil ? "Finding your location..." : "Finding your way..."
        }
        return connection.instruction
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    destinationField
                    if isOnRoute {
                        guidancePanel
                        RouteMapView(routeLine: connection.routeLine, turns: connection.route,
                                     location: locationReader.location)
                            .frame(height: max(220, min(geometry.size.height * 0.39, 340)))
                        HStack {
                            Text("Walking to \(connection.destinationName.isEmpty ? "your destination" : connection.destinationName)")
                                .font(.system(.body, design: .rounded, weight: .bold))
                            Spacer(minLength: 12)
                            talkButton
                            Spacer(minLength: 12)
                            Button { submit("cancel") } label: {
                                Text("End trip")
                                    .font(.system(.body, design: .rounded, weight: .bold))
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 44)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 22))
                                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
                            }
                            .disabled(connection.isSending || voice.isActive || voice.isPreparing || pendingCommand != nil)
                        }
                    } else {
                        Spacer(minLength: 24)
                        artwork
                            .frame(height: min(geometry.size.height * 0.40, 340))
                            .accessibilityHidden(true)
                        Text(currentState == "idle" ? "AcousticMaps" : currentState == "arrived" ? connection.instruction : stateLabel)
                            .font(.system(size: instructionSize, weight: .heavy, design: .rounded))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        if currentState == "listening", !voice.partialText.isEmpty {
                            Text(voice.partialText)
                                .font(.system(.body, design: .rounded))
                                .multilineTextAlignment(.center)
                        }
                        if currentState == "arrived" {
                            Text("Where do you want to go next?")
                                .font(.system(.body, design: .rounded, weight: .semibold))
                            talkButton
                        } else if currentState == "idle", connection.instruction != "Where to?" {
                            Text(connection.instruction)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .multilineTextAlignment(.center)
                        }
                        Spacer(minLength: 24)
                    }
                    if let error = voice.errorMessage ?? connection.errorMessage {
                        Text(error)
                            .font(.system(.body, design: .rounded))
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(Color("AlertGround"), in: RoundedRectangle(cornerRadius: 22))
                    }
                    if locationReader.location == nil {
                        Text(locationReader.status)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(Color("SecondaryText"))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color("Ground").ignoresSafeArea())
        .foregroundStyle(Color("Ink"))
        .tint(Color("Action"))
        .sheet(isPresented: $showDiagnostics) { diagnostics }
        .sheet(isPresented: $showPastTrips) { pastTrips }
        .task(id: pendingCommand) {
            guard pendingCommand != nil else { return }
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            pendingCommand = nil
            connection.errorMessage = "Location is unavailable. Check location permission and try again."
        }
        .onAppear {
            locationReader.onUpdate = { fix, heading in
                guard !connection.isSending else { return }
                let command = pendingCommand
                await connection.sendRealUpdate(location: fix, heading: heading, transcript: command)
                if command != nil { pendingCommand = nil }
            }
            locationReader.start()
        }
    }

    private var header: some View {
        HStack {
            Button { showPastTrips = true } label: {
                Text("See past trips")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
            }
            Spacer()
            if isOnRoute {
                Label(gpsGood ? "GPS good" : "GPS weak", systemImage: "circle.fill")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(gpsGood ? .green : Color("SecondaryText"))
            }
            Button { showDiagnostics = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Open diagnostics")
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, geometry.size.height * 360 / 382)
            let scale = width / 360
            ZStack(alignment: .topLeading) {
                Image("CompassOpen").resizable().frame(width: width, height: width * 382 / 360)
                Image(blobImage).resizable()
                    .frame(width: 157 * scale, height: 116 * scale)
                    .offset(x: 78 * scale, y: 165 * scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var gpsGood: Bool {
        guard let fix = locationReader.location else { return false }
        return fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 25
            && abs(fix.timestamp.timeIntervalSinceNow) < 15
    }

    private var guidancePanel: some View {
        HStack(spacing: 12) {
            Image(blobImage).resizable().scaledToFit()
                .frame(width: 100, height: 80)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(stateLabel.uppercased())
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Color("Action"))
                Text(displayedInstruction)
                    .font(.system(size: instructionSize, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(currentState == "off_route" ? "AlertGround" : "CardGround"), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
        .accessibilityElement(children: .combine)
    }

    private var destinationField: some View {
        HStack(spacing: 12) {
            TextField("Where to?", text: $destination)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .focused($searchFocused)
                .submitLabel(.go)
                .onSubmit { submitDestination() }
                .accessibilityLabel("Destination")
            if searchFocused && !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { submitDestination() } label: {
                    Image(systemName: "arrow.right")
                        .font(.title3.bold())
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Find walking route")
                .disabled(connection.isSending || pendingCommand != nil || voice.isActive || voice.isPreparing)
            }
            Button {
                searchFocused = false
                if voice.isActive { voice.stop() }
                else { Task { await voice.startListening(connection: connection) } }
            } label: {
                Image(systemName: voice.isActive ? "stop.fill" : "mic.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(voice.isActive ? Color("Ink") : .white)
                    .background(Color(voice.isActive ? "CompassGold" : "Action"), in: Circle())
                    .overlay(Circle().stroke(Color("Ink"), lineWidth: 2))
            }
            .accessibilityLabel(voice.isActive ? "Stop listening" : "Speak your destination")
            .disabled(connection.isSending || pendingCommand != nil || voice.isPreparing)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
    }

    private var talkButton: some View {
        VStack(spacing: 10) {
            Button {
                searchFocused = false
                Task { await voice.startListening(connection: connection) }
            } label: {
                Group {
                    if voice.isPreparing {
                        ProgressView().tint(Color("Ink"))
                    } else {
                        Image(systemName: voice.isActive ? "waveform" : "mic.fill")
                            .font(.system(size: 30, weight: .semibold))
                    }
                }
                .frame(width: 84, height: 84)
                .foregroundStyle(voice.isActive ? Color("Ink") : .white)
                .background(Color(voice.isActive ? "CompassGold" : "Action"), in: Circle())
                .overlay(Circle().stroke(Color("Ink"), lineWidth: 2.5))
            }
            .buttonStyle(.plain)
            .disabled(voice.isActive || voice.isPreparing || pendingCommand != nil || connection.isSending)
            .accessibilityLabel(voice.isActive ? "Listening" : "Speak destination or command")
        }
    }

    private func submitDestination() {
        let text = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        connection.destinationName = text
        submit("take me to \(text)")
    }

    private var pastTrips: some View {
        NavigationStack {
            List {
                if connection.pastTrips.isEmpty {
                    Text("Your completed walks will appear here.")
                        .foregroundStyle(Color("SecondaryText"))
                }
                ForEach(connection.pastTrips) { trip in
                    Button {
                        destination = trip.destination
                        showPastTrips = false
                        searchFocused = true
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(trip.destination).font(.system(.title3, design: .rounded, weight: .bold))
                            Text(trip.date, style: .date)
                            Text("\(max(1, Int(trip.duration / 60))) min walk")
                                .foregroundStyle(Color("SecondaryText"))
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Past trips")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPastTrips = false }
                }
            }
        }
        .tint(Color("Action"))
    }

    private func submit(_ command: String) {
        guard !connection.isSending, pendingCommand == nil,
              !voice.isActive, !voice.isPreparing else { return }
        searchFocused = false
        pendingCommand = command
        locationReader.start()
        if let fix = locationReader.location, abs(fix.timestamp.timeIntervalSinceNow) < 15 {
            Task {
                await connection.sendRealUpdate(
                    location: fix, heading: locationReader.headingDegrees, transcript: command
                )
                pendingCommand = nil
            }
        }
    }

    private var diagnostics: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    Text(voice.status)
                    Text(voice.audioDiagnostics.isEmpty ? "No recording yet." : voice.audioDiagnostics)
                    if !voice.partialText.isEmpty { Text(voice.partialText) }
                }
                Section("Location") {
                    Text(locationReader.status)
                    if let fix = locationReader.location {
                        Text("Latitude: \(fix.coordinate.latitude)")
                        Text("Longitude: \(fix.coordinate.longitude)")
                        Text("Accuracy: \(fix.horizontalAccuracy) m")
                    }
                }
                Section("Haptics") {
                    ForEach(["tick", "turn_left", "turn_right", "off_route", "arrived"], id: \.self) { name in
                        Button(name.replacingOccurrences(of: "_", with: " ")) {
                            connection.handleReply(ServerReply(say: nil, haptic: name, state: nil, route: nil))
                        }
                    }
                    if let error = connection.hapticError { Text(error) }
                }
                Section("Server") {
                    Button("Send test update") {
                        Task { await connection.sendFakeUpdate() }
                    }
                    .disabled(connection.isSending || voice.isActive)
                    Text(connection.rawReply).textSelection(.enabled)
                }
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showDiagnostics = false }
                }
            }
        }
    }
}

#Preview {
    ContentView(connection: ConnectionTest())
}
