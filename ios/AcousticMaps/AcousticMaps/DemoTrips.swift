import SwiftUI
import CoreLocation
import AVFoundation

/// Real walks recorded on campus, replayed through the server's guidance and bundled
/// (DemoTrips.json, made by server/make_demo_trips.py) so anyone can watch one.
struct DemoTrip: Codable, Identifiable {
    struct Tick: Codable {
        let t: Double
        let lat: Double
        let lng: Double
        let state: String
        let say: String?
        let haptic: String?
    }

    let id: String
    let destination: String
    let note: String
    let date: String
    let duration_s: Double
    let distance_m: Double
    let arrived: Bool
    let route_line: [[Double]]
    let turns: [RoutePoint]
    let ticks: [Tick]

    var day: Date { Self.dateFormat.date(from: date) ?? Date() }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static let all: [DemoTrip] = {
        struct File: Codable { let trips: [DemoTrip] }
        guard let url = Bundle.main.url(forResource: "DemoTrips", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.trips
    }()
}

/// Plays a recorded walk back like the live app: the dot walks the real path, the
/// guidance card and blob change as the server spoke, optionally out loud.
struct TripReplayView: View {
    let trip: DemoTrip
    @State private var time = 0.0
    @State private var playing = false
    @State private var speed = 4.0
    @State private var speakAloud = true
    @State private var speaker = AVSpeechSynthesizer()
    @State private var haptics = HapticPlayer()
    @State private var lastSpoken = -1
    @State private var rate = 4.0          // eases toward `speed`, or real time while speaking
    private let frame = 1.0 / 30

    private var tickIndex: Int {
        trip.ticks.lastIndex { $0.t <= time } ?? 0
    }

    private var tick: DemoTrip.Tick { trip.ticks[tickIndex] }

    /// The last thing the server said by now (and its haptic).
    private var spoken: (index: Int, tick: DemoTrip.Tick)? {
        guard let index = trip.ticks[...tickIndex].lastIndex(where: { $0.say != nil }) else { return nil }
        return (index, trip.ticks[index])
    }

    /// Position between the once-a-second fixes, so the dot glides instead of jumping.
    private var location: CLLocation {
        let next = trip.ticks[min(tickIndex + 1, trip.ticks.count - 1)]
        let span = next.t - tick.t
        let f = span > 0 ? min(1, max(0, (time - tick.t) / span)) : 0
        return CLLocation(latitude: tick.lat + (next.lat - tick.lat) * f,
                          longitude: tick.lng + (next.lng - tick.lng) * f)
    }

    private var remaining: Int? {
        let line = trip.route_line.compactMap { $0.count == 2
            ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
        return RouteProgress.locate(location.coordinate, on: line).map { Int(($0.remainingMeters / 10).rounded() * 10) }
    }

    var body: some View {
        let sentence = spoken?.tick.say ?? "Ready to walk to \(trip.destination)."
        let card = GuidanceText.card(sentence: sentence, state: tick.state)
        let haptic = trip.ticks[...tickIndex].last(where: { $0.haptic != nil })?.haptic
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(GuidanceText.blob(state: tick.state, haptic: haptic)).resizable().scaledToFit()
                    .frame(width: 92, height: 70)
                    .id(GuidanceText.blob(state: tick.state, haptic: haptic))
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                    .modifier(Bobbing(amount: 2.5, fast: false))
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.label)
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .foregroundStyle(tick.state == "off_route" ? Color.red : Color("Action"))
                    Text(card.text)
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color(tick.state == "off_route" ? "AlertGround" : "CardGround"),
                        in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color("Ink"), lineWidth: 2.5))
            .animation(.easeInOut(duration: 0.3), value: card.text)
            .animation(.easeInOut(duration: 0.3), value: tick.state)

            RouteMapView(routeLine: trip.route_line, turns: trip.turns, location: location,
                         offRoute: tick.state == "off_route")
                .frame(minHeight: 220, maxHeight: .infinity)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(remaining.map { "\($0) m" } ?? "—")
                        .font(.system(.title3, design: .rounded, weight: .heavy))
                        .contentTransition(.numericText())
                    Text("\(Int(time) / 60):\(String(format: "%02d", Int(time) % 60)) of \(Int(trip.duration_s) / 60) min")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color("SecondaryText"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if time >= trip.duration_s { time = 0; lastSpoken = -1 }
                    if playing { speaker.stopSpeaking(at: .word) }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 68, height: 68)
                        .foregroundStyle(.white)
                        .background(Color("Action"), in: Circle())
                        .overlay(Circle().stroke(Color("Ink"), lineWidth: 2.5))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(playing ? "Pause replay" : "Play replay")
                Menu {
                    ForEach([1.0, 4.0, 8.0, 16.0], id: \.self) { value in
                        Button("\(Int(value))x") { speed = value }
                    }
                    Toggle("Speak instructions", isOn: $speakAloud)
                } label: {
                    Text("\(Int(speed))x")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color("Ink"), lineWidth: 2.5))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Slider(value: $time, in: 0...trip.duration_s) { editing in
                if editing {
                    playing = false
                    speaker.stopSpeaking(at: .immediate)
                } else {
                    lastSpoken = spoken?.index ?? -1   // don't replay the line we landed on
                }
            }
            .accessibilityLabel("Replay position")
        }
        .padding(20)
        .background(Color("Ground").ignoresSafeArea())
        .foregroundStyle(Color("Ink"))
        .tint(Color("Action"))
        .navigationTitle(trip.destination)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: spoken?.index) { _, index in
            guard playing, let index, index != lastSpoken else { return }
            lastSpoken = index
            let line = trip.ticks[index]
            if let haptic = line.haptic { try? haptics.play(haptic) }
            guard speakAloud, let sentence = line.say else { return }
            // queue, don't interrupt: cutting lines off is what sounded choppy
            speaker.speak(AVSpeechUtterance(string: sentence))
        }
        .task(id: playing) {
            guard playing else { return }
            try? AcousticAudioSession.configureAndActivate()
            rate = speed
            while playing {
                try? await Task.sleep(for: .seconds(frame))
                // ease to real time while a line is spoken, then back up to the chosen speed
                let target = speakAloud && speaker.isSpeaking ? min(speed, 1.25) : speed
                rate += (target - rate) * 0.08
                time = min(trip.duration_s, time + frame * rate)
                if time >= trip.duration_s { playing = false }
            }
        }
        .onDisappear {
            playing = false
            speaker.stopSpeaking(at: .immediate)
            haptics.stop()
        }
    }
}
