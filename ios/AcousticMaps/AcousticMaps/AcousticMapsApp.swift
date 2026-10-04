//
//  AcousticMapsApp.swift
//  AcousticMaps
//
//  Created by Sophia Lu on 10/3/26.
//

import SwiftUI

@main
struct AcousticMapsApp: App {
    // keep one connection object for the app's lifetime
    @StateObject private var connection = ConnectionTest()

    init() {
        try? AcousticAudioSession.configureAndActivate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(connection: connection)
        }
    }
}
