//
//  flyfun_exampleApp.swift
//  flyfun-example
//
//  Created by Brice Rosenzweig on 18/06/2026.
//

import SwiftUI

@main
struct flyfun_exampleApp: App {
    @State private var auth = AuthManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
        }
    }
}
