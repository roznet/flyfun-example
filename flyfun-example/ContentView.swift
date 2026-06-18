//
//  ContentView.swift
//  flyfun-example
//

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var auth

    var body: some View {
        NavigationStack {
            Group {
                switch auth.status {
                case .disconnected:
                    connectView
                case .connecting:
                    ProgressView("Connecting…")
                case .connected:
                    flightList
                }
            }
            .navigationTitle("FlyFun Flights")
            .toolbar {
                if auth.status == .connected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Log out", role: .destructive) { auth.logout() }
                    }
                }
            }
        }
    }

    // MARK: Disconnected

    private var connectView: some View {
        VStack(spacing: 24) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Connect to FlyFun Weather to import your flights.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { await auth.connect() }
            } label: {
                Text("Connect")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let error = auth.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    // MARK: Connected

    private var flightList: some View {
        List {
            if auth.flights.isEmpty {
                ContentUnavailableView("No flights", systemImage: "tray",
                                       description: Text("No upcoming flights found on your account."))
            } else {
                ForEach(auth.flights) { flight in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(flight.route_name).font(.headline)
                        Text(flight.departure_time).font(.subheadline).foregroundStyle(.secondary)
                        if let wp = flight.waypoints, !wp.isEmpty {
                            Text(wp.joined(separator: " → "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let error = auth.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .refreshable { await auth.loadFlights() }
    }
}

#Preview {
    ContentView().environment(AuthManager())
}
