import SwiftUI
import CoreLocation

struct ContentView: View {
    @ObservedObject var connection: ConnectionTest
    @StateObject private var locationReader = LocationReader()
    @StateObject private var voice = VoiceStream()
    @State private var events = EventStream()
    @State private var destination = ""
    @State private var pendingCommand: String?
    @State private var showDiagnostics = false
    @State private var showPastTrips = false
    @State private var offRouteShakes = 0
    @State private var blobPopped = false
    @FocusState private var searchFocused: Bool
    @AppStorage("AcousticMaps.hapticsOff") private var hapticsOff = false
    @Namespace private var mascot
    @ScaledMetric(relativeTo: .title) private var instructionSize = 26

    private let walkingSpeed = 1.3

    private var currentState: String {
        if voice.isActive || voice.isPreparing { return "listening" }
        if pendingCommand != nil { return "thinking" }
        return connection.state
    }

    private var isOnRoute: Bool {
        ["navigating", "off_route"].contains(connection.state)
            || (!connection.routeLine.isEmpty && !["idle", "arrived"].contains(connection.state))
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

    /// What the big title says when not on a trip.
    private var stageTitle: String {
        switch currentState {
        case "listening": return voice.isPreparing ? "Getting ready" : "Listening"
        case "thinking": return "Finding your route"
        case "arrived":
            return connection.destinationName.isEmpty ? "You made it" : "You made it to \(connection.destinationName)"
        default: return "AcousticMaps"
        }
    }

    private var stageSubtitle: String? {
        switch currentState {
        case "arrived": return "Where do you want to go next?"
        case "idle":
            return connection.instruction == "Where to?"
                ? "Tap the microphone and say where you want to go." : connection.instruction
        default: return nil
        }
    }

    /// The guidance card: a small label ("IN 40 M", "OFF ROUTE") over the instruction.
    private var card: (label: String, text: String) {
        let sentence = connection.instruction
        if currentState == "listening" {
            return ("LISTENING", voice.partialText.isEmpty ? "I'm listening." : voice.partialText)
        }
        if currentState == "thinking" || sentence.hasPrefix("Okay, let me check") {
            return ("ONE MOMENT", sentence.hasPrefix("Okay") ? "Let me check." : "Finding your way...")
        }
        return GuidanceText.card(sentence: sentence, state: currentState)
    }

    private var remaining: (meters: Int, minutes: Int)? {
        let line = connection.routeLine.compactMap { $0.count == 2
            ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        guard let fix = locationReader.location,
              let progress = RouteProgress.locate(fix.coordinate, on: line) else { return nil }
        let meters = Int((progress.remainingMeters / 10).rounded() * 10)
        return (meters, max(1, Int((progress.remainingMeters / walkingSpeed / 60).rounded(.up))))
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            destinationField
            if isOnRoute {
                tripView
            } else {
                stage
            }
            if let error = voice.errorMessage ?? connection.errorMessage {
                Text(error)
                    .font(.system(.body, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color("AlertGround"), in: RoundedRectangle(cornerRadius: 22))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if locationReader.location == nil {
                Text(locationReader.status)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Color("SecondaryText"))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.6, dampingFraction: 0.82), value: isOnRoute)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: currentState)
        .animation(.easeInOut(duration: 0.25), value: voice.errorMessage ?? connection.errorMessage)
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
        .onChange(of: currentState) { old, new in
            if new == "off_route" { offRouteShakes += 1 }
            // the blob pops out of the compass when it opens, and on arrival
            if (old == "idle" && new == "listening") || new == "arrived" {
                blobPopped = true
                Task {
                    try? await Task.sleep(for: .milliseconds(380))
                    blobPopped = false
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: voice.isActive)
        .sensoryFeedback(.success, trigger: connection.arrivals)
        .onAppear {
            events.start(connection: connection)
            locationReader.onUpdate = { fix, heading in
                guard !connection.isSending else { return }
                let command = pendingCommand
                await connection.sendRealUpdate(location: fix, heading: heading, transcript: command)
                if command != nil { pendingCommand = nil }
            }
            locationReader.start()
        }
    }

    // MARK: - Not on a trip: the big compass

    private var stage: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            ZStack {
                CompassView(open: currentState != "idle", blob: currentState == "idle" ? nil : blobImage,
                            blobPopped: blobPopped, spinning: currentState == "thinking", namespace: mascot)
                    .matchedGeometryEffect(id: "compass", in: mascot)
                    .modifier(Bobbing(amount: 4, fast: currentState == "thinking"))
                    .frame(maxHeight: 300)
                ConfettiBurst(trigger: connection.arrivals)
            }
            Text(stageTitle)
                .font(.system(size: instructionSize + 2, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityAddTraits(.isHeader)
            if currentState == "listening" {
                WaveformBars(level: voice.level)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if let subtitle = stageSubtitle {
                Text(subtitle)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color("SecondaryText"))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
        }
        .frame(maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: - On a trip: card, map, bottom bar

    private var tripView: some View {
        VStack(spacing: 14) {
            guidanceCard
                .transition(.move(edge: .top).combined(with: .opacity))
            RouteMapView(routeLine: connection.routeLine, previousLine: connection.previousRouteLine,
                         turns: connection.route, location: locationReader.location,
                         offRoute: currentState == "off_route")
                .frame(minHeight: 200, maxHeight: .infinity)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            bottomBar
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var guidanceCard: some View {
        let offRoute = currentState == "off_route"
        return HStack(spacing: 12) {
            Image(blobImage).resizable().scaledToFit()
                .matchedGeometryEffect(id: "blob", in: mascot)
                .frame(width: 92, height: 70)
                .id(blobImage)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .modifier(Bobbing(amount: 2.5, fast: currentState == "thinking"))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.label)
                    .font(.system(.caption, design: .rounded, weight: .heavy))
                    .foregroundStyle(offRoute ? Color.red : Color("Action"))
                    .contentTransition(.opacity)
                Text(card.text)
                    .font(.system(size: instructionSize - 6, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color(offRoute ? "AlertGround" : "CardGround"), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color("Ink"), lineWidth: 2.5))
        .animation(.easeInOut(duration: 0.3), value: card.text)
        .animation(.easeInOut(duration: 0.3), value: offRoute)
        .phaseAnimator([0.0, -10, 10, -6, 6, 0], trigger: offRouteShakes) { view, x in
            view.offset(x: x)
        } animation: { _ in .spring(response: 0.12, dampingFraction: 0.5) }
        .accessibilityElement(children: .combine)
    }

    private var bottomBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(remaining.map { "\($0.meters) m" } ?? "—")
                    .font(.system(.title3, design: .rounded, weight: .heavy))
                    .contentTransition(.numericText())
                Text(remaining.map { "about \($0.minutes) min" } ?? "")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color("SecondaryText"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut, value: remaining?.meters)
            .accessibilityElement(children: .combine)
            talkButton
            Button { submit("cancel") } label: {
                Text("End trip")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(voice.isActive || voice.isPreparing || pendingCommand != nil)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Header and search

    private var header: some View {
        HStack(spacing: 8) {
            Button { showPastTrips = true } label: {
                Text("See past trips")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color("Ink"), lineWidth: 2.5))
            }
            .buttonStyle(PressableButtonStyle())
            Spacer()
            if isOnRoute, !gpsGood {
                Label("GPS weak", systemImage: "location.slash")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(Color("SecondaryText"))
                    .transition(.opacity)
            }
            Button { showDiagnostics = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Open diagnostics")
            if isOnRoute {
                // the compass flies up here when a trip starts
                CompassView(open: true, blob: nil)
                    .matchedGeometryEffect(id: "compass", in: mascot)
                    .frame(width: 52, height: 56)
            }
        }
        .frame(height: 56)
    }

    private var gpsGood: Bool {
        guard let fix = locationReader.location else { return false }
        return fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 25
            && abs(fix.timestamp.timeIntervalSinceNow) < 15
    }

    private var destinationField: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                TextField(currentState == "arrived" ? "Where to next?" : "Where to?", text: $destination)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .focused($searchFocused)
                    .submitLabel(.go)
                    .onSubmit { submitDestination() }
                    .accessibilityLabel("Destination")
                    .opacity(voice.isActive ? 0 : 1)
                if voice.isActive {
                    // live transcript while listening
                    Text(voice.partialText.isEmpty ? "Listening..." : voice.partialText.prefix(1).uppercased() + voice.partialText.dropFirst())
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: voice.partialText)
                }
            }
            if searchFocused && !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { submitDestination() } label: {
                    Image(systemName: "arrow.right")
                        .font(.title3.bold())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PressableButtonStyle())
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Find walking route")
                .disabled(pendingCommand != nil || voice.isActive || voice.isPreparing)
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
                    .background(ListeningRings(level: voice.level, active: voice.isActive && !isOnRoute, size: 44))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(voice.isActive ? "Stop listening" : "Speak your destination")
            .disabled(pendingCommand != nil || voice.isPreparing)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.white, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: searchFocused)
    }

    private var talkButton: some View {
        Button {
            searchFocused = false
            if voice.isActive { voice.stop() }
            else { Task { await voice.startListening(connection: connection) } }
        } label: {
            Group {
                if voice.isPreparing {
                    ProgressView().tint(Color("Ink"))
                } else {
                    Image(systemName: voice.isActive ? "waveform" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, isActive: voice.isActive)
                }
            }
            .frame(width: 68, height: 68)
            .foregroundStyle(voice.isActive ? Color("Ink") : .white)
            .background(Color(voice.isActive ? "CompassGold" : "Action"), in: Circle())
            .overlay(Circle().stroke(Color("Ink"), lineWidth: 2.5))
            .background(ListeningRings(level: voice.level, active: voice.isActive, size: 68))
            .overlay(ThinkingRing(active: currentState == "thinking", size: 68))
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(voice.isPreparing || pendingCommand != nil)
        .accessibilityLabel(voice.isActive ? "Stop listening" : "Speak destination or command")
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
                if !DemoTrip.all.isEmpty {
                    Section {
                        ForEach(DemoTrip.all) { trip in
                            NavigationLink {
                                TripReplayView(trip: trip)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(trip.destination).font(.system(.title3, design: .rounded, weight: .bold))
                                    Text(trip.note)
                                    Text("\(trip.day.formatted(date: .abbreviated, time: .shortened)) · "
                                         + "\(Int(trip.distance_m)) m · \(max(1, Int(trip.duration_s / 60))) min")
                                        .foregroundStyle(Color("SecondaryText"))
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    } header: {
                        Text("Demo walks: tap to replay")
                    } footer: {
                        Text("Recorded on campus and replayed with the guidance the app spoke.")
                    }
                }
                Section("Your trips") {
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
                    Toggle("Haptics on (turn off to test the mic)", isOn: Binding(
                        get: { !hapticsOff }, set: { hapticsOff = !$0 }))
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
