# Estimoto +

The customer companion to Estimoto. A separate mobile app for a saved garage, PDR/Collision estimates, repair updates and finding the right shop or technician.

Estimoto + now has a live customer API, dedicated Supabase Auth/PostgreSQL storage, and a production bridge to Estimoto shops. See [release status](docs/release-status.md) for the exact verified scope and remaining launch checks.

[Open Estimoto +](https://estimoto-plus-api.fly.dev/) · [Download the latest released Android beta](https://estimoto-plus-api.fly.dev/android/download) · [TestFlight status](docs/mobile-release.md)

<img src="docs/screenshots/garage-carsxe-web.png" alt="Estimoto Plus garage with a representative CarsXE Audi Q5 image and clearly labeled demo data" width="300">

## Explore the app

Install Flutter 3.44.1, then:

```sh
cd app
flutter pub get --enforce-lockfile
flutter run --dart-define=PLUS_DEMO=true
```

Select an iOS simulator, Android device or Chrome. The explicit demo has fictional vehicles, providers and timelines; changes reset when it reloads and no provider is contacted. To serve a static preview:

```sh
cd app
flutter build web --dart-define=PLUS_DEMO=true
python3 -m http.server 4318 --bind 127.0.0.1 --directory build/web
```

Open `http://127.0.0.1:4318`. Production customer sessions use the dedicated authenticated API; network errors never fall back to sample data.

## What is in this milestone

The local September 19 improvements add reminder urgency and completed-reminder
management, searchable service history, reliable receipt attachment while editing,
and contact options for the shop reviewing an estimate. See the
[implementation and validation notes](docs/qa/2026-09-19-feature-completion.md)
for scope and remaining release checks.

| Area | Implemented |
| --- | --- |
| Garage | Saved contact details, multiple vehicles, mileage and optional insurance; date/mileage reminders with overdue/due/upcoming status, editable dates and a completed list you can reopen; representative CarsXE photos or private camera/gallery uploads |
| Estimates | PDR/Collision tabs, guided required-photo capture, private readback, editable and deletable unshared drafts and photos, durable handoff to a selected Estimoto shop, reviewed estimate status and selected-shop contact options |
| Repairs | Shop-supplied timelines and update dates, request delivery/response status, cancellation |
| Find Help | Participating shops/techs and reviewed local businesses within 30 miles; up to 30 results, real shop artwork, contact details, mini profiles and vehicle-specific dedicated shops |
| Estibot | Guided estimate and routine-care topics, technician matching, saved-shop scheduling, private graph retrieval over service history, and labeled YouTube search links |
| My shops | Private shop contacts, reviewed customer-authorized scheduling requests that can be discarded or withdrawn, and explicit shop acceptance |
| Service history | Searchable repair, maintenance and modification records with category filters and newest-first ordering; editable costs, private receipt photos/PDFs from new or edited entries, shop and parts details, per-vehicle valuation history; optional aggregated contributions |
| Foundation | Separate `io.estimoto.plus` iOS/Android app, Supabase Auth client, customer ownership checks, migrations, durable request outbox and bridge contract |

Submitting a service request is not an appointment. A provider must confirm acceptance and schedule. Estibot presents a review screen before sharing contact and vehicle details.

## Run the API and checks

Use Python 3.13:

```sh
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.lock
```

Follow [backend configuration](backend/README.md) to start a persistent local service and [app configuration](app/README.md) to connect a device. All local configuration, tokens, databases and photo files stay outside version control. The app uses a publishable Auth key; bridge/server keys remain on the server.

From the repository root:

```sh
(cd backend && .venv/bin/python -m pytest -q)
(cd app && flutter analyze && flutter test)
backend/.venv/bin/python scripts/smoke_api.py --flutter-client
bash scripts/build_capture.sh
```

The socket smoke creates a temporary migrated database and a local fictional identity/provider server, exercises customer isolation and the Dart HTTP client, then restarts the API to verify persistence. It cleans up its temporary files and makes no production calls.

Before releasing a clean commit, run `python3 scripts/check_release.py --integration --output /tmp/plus-release-checks-<unique-name>` with the disposable PostgreSQL and original bridge environment described in [the audit closure record](docs/qa/2026-09-13-audit-closure.md). This runs the full backend suite with zero skipped tests, Flutter analysis/tests, capture-web tests/build, and all three socket smokes. GitHub Actions remains a separate check: its account billing lock must be resolved by the account owner before hosted CI can run.

## Customer launch

Demolition Dent is connected for PDR and collision in its saved ZIP 80221. PDR LINX is the second authorized participant; its account has no saved service ZIP, so its location routing awaits that information. The [launch record](docs/launch/2026-09-14-customer-launch.md) separates source tests, live API/browser checks, device proof and Apple review.

Physical-device capture, actual shop scheduling delivery and Apple external beta approval remain separate launch checks. CARFAX, push reminder delivery, automated phone/SMS booking and Google Play publication are not connected. Customer-reported records are not verified repair invoices. See the [automotive knowledge architecture](docs/automotive-knowledge.md) for the current graph, source attribution and optional aggregate sharing.

[Product design](docs/superpowers/specs/2026-09-13-estimoto-plus-design.md) · [Implementation plan](docs/superpowers/plans/2026-09-13-estimoto-plus-foundation.md)
