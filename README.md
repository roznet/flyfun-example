# flyfun-example

A small, dependency-free SwiftUI iOS app that connects to
[**FlyFun Weather**](https://weather.flyfun.aero) and imports a user's flights.

It's a working reference for the OAuth 2.1 flow third-party apps use to read a
FlyFun user's flights: discovery, dynamic client registration, PKCE, login via
`ASWebAuthenticationSession`, token exchange/refresh, and the `GET /api/flights`
call. Tap **Connect**, log in with your FlyFun (Google) account, approve the
consent screen, and the app lists your flights.

## Source

- `flyfun-example/FlyFunConnect.swift` — the OAuth client and API calls.
- `flyfun-example/ContentView.swift` — Connect button, flight list, Log out.

Open `flyfun-example.xcodeproj` in Xcode and run.

## Integration guide

See [**INTEGRATION.md**](INTEGRATION.md) for the full walkthrough of the OAuth
flow, the available endpoints, and the access model — everything you need to
connect your own app to FlyFun Weather.
