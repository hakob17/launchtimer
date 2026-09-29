# Launch Timer

An iPhone performance timer — 0–60, 0–100 km/h, 60–130, ⅛ and ¼ mile, 60–0 braking — with a
live dashboard on the car's screen (the Tesla browser, or any car with one).

| Path | What |
|---|---|
| `Core/LaunchEngine.swift` | Run detection and timing. Pure Swift, no iOS APIs. |
| `Core/Runs.swift` | Splits, results, units. |
| `Core/DemoDrive.swift` | A simulated drive for the in-app demo. |
| `Sources/` | The SwiftUI app: sensors, dashboard, runs, car pairing. |
| `docs/car/` | The car page (GitHub Pages). `?preview` shows it with fake data. |
| `tests/main.swift` | Simulated drives against the engine. |

## How the timing works

GPS reports speed about once a second; the accelerometer 100 times a second but drifts. The
engine finds "forward" from the first moments of a launch (so any mount angle works), integrates
the acceleration along it, and fits `speed(t) = v₀ + s·∫a − b·t` to the GPS readings by weighted
least squares with priors on scale and bias, plus a search for the GPS delay. A launch starts at
zero and a stop ends at zero, which pins `v₀`. The bias is re-learned whenever the car stands still.

```
swiftc -O Core/*.swift tests/main.swift -o build/engine-test && build/engine-test
```

The simulations (rigid mount, noisy sensors, GPS up to 0.3 s late, engine vibration) land within
0.05 s on 0–60 and within 1 m on 60–0. Real drives will be worse; that needs testing in a car.

## Car screen

The phone sends small JSON messages (`live` 10×/s, `runs`) through the HotspotNav relay
(`wss://teslanav-relay…/ws?room=CODE&role=phone|car`), which forwards phone → car and car → phone.

## Build

```
xcodegen generate && open LaunchTimer.xcodeproj
```

## Leaderboard

`api/` is a Cloudflare Worker with a D1 database (`launchtimer-api.hakob-hakobyan173.workers.dev`).
The server recomputes every posted time from the run's speed trace, refuses physically impossible
runs, slopes over 1% and demo runs, and marks posts signed with an Apple App Attest key as verified.
Driver names are generated; car makes/models come from NHTSA's vPIC; entries can be reported
(hidden after 3 reports) and hidden per device.

```
cd api && npx wrangler d1 migrations apply launchtimer --local && node test.mjs && node test-attest.mjs
npx wrangler deploy
```
