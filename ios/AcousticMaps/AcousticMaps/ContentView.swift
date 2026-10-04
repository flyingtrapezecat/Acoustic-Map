import SwiftUI
import CoreLocation

struct ContentView: View {
    @ObservedObject var connection: ConnectionTest
    @StateObject private var locationReader = LocationReader()
    @StateObject private var voice = VoiceStream()
    @State private var events = EventStream()
    @State private var offRouteShakes = 0
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
                            .transition(.move(edge: .top).combined(with: .opacity))
                        RouteMapView(routeLine: connection.routeLine, turns: connection.route,
                                     location: locationReader.location)
                            .frame(height: max(220, min(geometry.size.height * 0.39, 340)))
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
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
                            .buttonStyle(PressableButtonStyle())
                            .disabled(voice.isActive || voice.isPreparing || pendingCommand != nil)
                        }
                        .transition(.opacity)
                    } else {
                        Spacer(minLength: 24)
                        artwork
                            .frame(height: min(geometry.size.height * 0.40, 340))
                            .accessibilityHidden(true)
                        Text(currentState == "idle" ? "AcousticMaps" : currentState == "arrived" ? connection.instruction : stateLabel)
                            .font(.system(size: instructionSize, weight: .heavy, design: .rounded))
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
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
                            .transition(.move(edge: .bottom).combined(with: .opacity))
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
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isOnRoute)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: currentState)
                .animation(.easeInOut(duration: 0.25), value: voice.errorMessage ?? connection.errorMessage)
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
        .onChange(of: connection.state) { _, state in
            if state == "off_route" { offRouteShakes += 1 }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: voice.isActive)
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
            .buttonStyle(PressableButtonStyle())
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
            .buttonStyle(PressableButtonStyle())
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
                    .id(blobImage)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .modifier(Bobbing(amount: 5 * scale, fast: currentState == "thinking"))
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
                .id(blobImage)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .modifier(Bobbing(amount: 3, fast: currentState == "thinking"))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(stateLabel.uppercased())
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Color("Action"))
                    .contentTransition(.opacity)
                Text(displayedInstruction)
                    .font(.system(size: instructionSize, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: displayedInstruction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(currentState == "off_route" ? "AlertGround" : "CardGround"), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
        .animation(.easeInOut(duration: 0.3), value: currentState)
        .phaseAnimator([0.0, -10, 10, -6, 6, 0], trigger: offRouteShakes) { view, x in
            view.offset(x: x)
        } animation: { _ in .spring(response: 0.12, dampingFraction: 0.5) }
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
                    .background(ListeningRings(level: voice.level, active: voice.isActive, size: 44))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(voice.isActive ? "Stop listening" : "Speak your destination")
            .disabled(pendingCommand != nil || voice.isPreparing)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: searchFocused)
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
                .background(ListeningRings(level: voice.level, active: voice.isActive, size: 84))
                .overlay(ThinkingRing(active: currentState == "thinking", size: 84))
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(voice.isActive || voice.isPreparing || pendingCommand != nil)
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

/// Buttons press in slightly with a spring, so taps feel physical.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Rings around the mic button that swell with the voice level while listening.
struct ListeningRings: View {
    let level: Double
    let active: Bool
    let size: CGFloat
    @State private var breathe = false

    var body: some View {
        ZStack {
            ring(0)
            ring(1)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: level)
        .animation(.easeInOut(duration: 0.3), value: active)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ring(_ index: Int) -> some View {
        let grow: CGFloat = 1.12 + CGFloat(index) * 0.18 + CGFloat(level) * 0.35 + (breathe ? 0.04 : 0)
        let color: Color = Color("Action").opacity(index == 0 ? 0.45 : 0.25)
        return Circle()
            .stroke(color, lineWidth: 3)
            .frame(width: size, height: size)
            .scaleEffect(active ? grow : 1)
            .opacity(active ? 1 : 0)
    }
}

/// A spinning arc around the talk button while the server (or the agent) is thinking.
struct ThinkingRing: View {
    let active: Bool
    let size: CGFloat
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(Color("CompassGold"), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .frame(width: size + 14, height: size + 14)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: active)
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A gentle idle bob for the blob character (faster while thinking).
struct Bobbing: ViewModifier {
    let amount: CGFloat
    let fast: Bool
    @State private var up = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: reduceMotion ? 0 : (up ? -amount : amount))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: fast ? 0.5 : 1.4).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

#Preview {
    ContentView(connection: ConnectionTest())
}
