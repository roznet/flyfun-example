# Connecting an app to FlyFun Weather

This guide is for developers who want their own app to read a FlyFun Weather
user's flights and import them. It explains the OAuth 2.1 flow, the endpoints,
and what the bundled iOS sample (`flyfun-example`) does.

You connect to **`https://weather.flyfun.aero`** using **OAuth 2.1 with dynamic
client registration**. Your app authenticates *as the user who logs in* — it can
only ever see that user's own data, and only after they explicitly consent.

---

## What you can access

With a `flights:read` token you can call two endpoints:

| Endpoint | Returns |
|---|---|
| `GET /api/flights` | The user's flights — a JSON array of flight objects (`id`, `route_name`, `waypoints`, `departure_time`, `cruise_altitude_ft`, aircraft, briefing status…). Supports `past_limit` / `past_offset` paging (with an `X-Past-Total` response header). |
| `GET /api/flights/{flight_id}/export` | One flight as a **`FlightExchange`** envelope — the cross-app interchange format (`schema_version`, `route` with departure/destination/waypoints/coords/times/cruise altitude/aircraft type, `name`, `aircraft_registration`, and a `source` block). Returns `404` if the flight doesn't exist or isn't visible to the user, `422` if it has fewer than two waypoints. |

Both accept `Authorization: Bearer <access_token>`.

---

## The flow

```
your app                         weather.flyfun.aero
   │
   │ 1. GET /.well-known/oauth-authorization-server
   │─────────────────────────────────────────────▶   { authorization_endpoint,
   │◀─────────────────────────────────────────────     token_endpoint,
   │                                                    registration_endpoint, … }
   │ 2. POST /oauth/register  {client_name, redirect_uris, grant_types}
   │─────────────────────────────────────────────▶
   │◀─────────────────────────────────────────────   { client_id, client_secret }
   │
   │ 3. open /oauth/authorize?client_id&redirect_uri&response_type=code
   │        &code_challenge&code_challenge_method=S256&scope=flights:read&state
   │─────── (system browser) ──────────────────────▶  user logs in with Google,
   │                                                   approves the consent screen
   │◀────── redirect: {redirect_uri}?code=…&state=… ───
   │
   │ 4. POST /oauth/token  grant_type=authorization_code
   │        &code&redirect_uri&client_id&client_secret&code_verifier
   │─────────────────────────────────────────────▶
   │◀─────────────────────────────────────────────   { access_token, refresh_token, … }
   │
   │ 5. GET /api/flights        Authorization: Bearer <access_token>
   │ 5. GET /api/flights/{id}/export
```

### 1. Discovery (RFC 8414)
`GET https://weather.flyfun.aero/.well-known/oauth-authorization-server` returns the
endpoint URLs and `scopes_supported`. Read them from here rather than hardcoding.

### 2. Dynamic registration (RFC 7591)
`POST {registration_endpoint}` with JSON:
```json
{
  "client_name": "Your App (iOS)",
  "redirect_uris": ["net.example.yourapp://oauth-callback"],
  "grant_types": ["authorization_code", "refresh_token"]
}
```
Returns `client_id` + `client_secret`. Store them and reuse — register once, not per login.

> **Native apps & redirect URIs (RFC 8252).** Use a **private-use URI scheme**
> based on your bundle id (e.g. `net.example.yourapp://oauth-callback`), *not* a
> custom `https` URL unless you've set up universal links. The server allows
> private-use schemes for registration.

### 3. Authorization + PKCE (RFC 7636, S256 — required)
Generate a random `code_verifier`, compute `code_challenge = BASE64URL(SHA256(verifier))`,
and open `{authorization_endpoint}` in the system browser with `client_id`,
`redirect_uri`, `response_type=code`, `code_challenge`, `code_challenge_method=S256`,
`scope=flights:read`, and a random `state`. The user logs in with their FlyFun
(Google) account and approves a consent screen; the browser redirects back to your
`redirect_uri` with `?code=…&state=…`. **Verify `state` matches** what you sent.

### 4. Token exchange
`POST {token_endpoint}` (form-encoded, `client_secret_post`):
```
grant_type=authorization_code
code=<from step 3>
redirect_uri=net.example.yourapp://oauth-callback
client_id=<from step 2>
client_secret=<from step 2>
code_verifier=<from step 3>
```
Returns `{ access_token, token_type: "bearer", expires_in, refresh_token }`.
Refresh later with `grant_type=refresh_token` (the refresh token rotates on use).

### 5. Call the API
Send `Authorization: Bearer <access_token>` on the flight endpoints. On `401`,
refresh once; if that fails, send the user back through the flow.

---

## Access model — who can connect, and to what

- **Anyone can register a client.** Registration alone grants nothing.
- **The gate is the user.** No token is issued until a real FlyFun user logs in
  and approves the consent screen, so your app only ever reaches *that* user's
  data. The `/export` endpoint additionally respects each flight's visibility.
- **Scope.** Request `flights:read` — it's the least-privilege scope for this
  use case (flight list + export only).

---

## The iOS sample (`flyfun-example`)

A complete, dependency-free SwiftUI app that does the whole flow:

- `FlyFunConnect.swift` — the OAuth client: discovery, registration, PKCE,
  `ASWebAuthenticationSession` login, token exchange/refresh, and the
  `GET /api/flights` call. Tokens + client credentials live in the Keychain.
- `ContentView.swift` — a **Connect** button, the flight list, and a **Log out** button.

Notes:
- `ASWebAuthenticationSession` intercepts the `net.ro-z.flyfun-example://` redirect
  automatically — no `Info.plist` URL-scheme registration needed.
- Config (host, redirect URI, scope, client name) is at the top of `FlyFunConnect.swift`
  in `OAuthConfig`. Change `redirectURI` / `callbackScheme` to your bundle id when
  reusing this in your own app.

---

## Spec references
- RFC 8414 — OAuth 2.0 Authorization Server Metadata
- RFC 7591 — OAuth 2.0 Dynamic Client Registration
- RFC 7636 — PKCE
- RFC 8252 — OAuth 2.0 for Native Apps
