# Prepared source — account deletion, data export and legal pages, September 19, 2026

This section describes source prepared on the `claude/app-feature-enhancement-uh7cqi` branch. It does **not** claim a deployment, a native build or a store submission; those are recorded when they happen.

Customers can now delete their account from Settings, which App Store Review Guideline 5.1.1(v) and Google Play's account-deletion policy require of any app with sign-in. `DELETE /v1/account` cancels open shop requests (delivering the cancellation to the bridge first, or refusing with a retryable 409 when the bridge is unreachable), erases every customer-owned row and private file in one transaction, invalidates the verified-session cache and, when `SUPABASE_SERVICE_ROLE_KEY` is set on the server, removes the Supabase Auth user. `GET /v1/account/export` returns a complete JSON copy of the account, offered in Settings as **Download my data**. Settings also links a new app-wide [privacy policy](https://estimoto-plus-api.fly.dev/privacy.html) and [terms of use](https://estimoto-plus-api.fly.dev/terms.html), open-source licenses and support email; the welcome screen links the two legal pages. The pages describe the current processors in source (Supabase, the Estimoto shop bridge, Resend, Nango, OpenStreetMap, Zippopotam.us, Google Maps, CarsXE and the optional assistant model) and should be reviewed by counsel before the store listing cites them.

Platform metadata: an iOS privacy manifest (`PrivacyInfo.xcprivacy`, no tracking, collected data types declared) is bundled by the Xcode project; `Info.plist` enables Files sharing for the export; the Android manifest declares `https`, `tel` and `mailto` intent queries so shop links, calls and support email open on Android 11+. Backend hardening: per-account caps (50 vehicles, 500 estimates, 500 reminders), pruning of rate counters older than 48 hours, and a JSON 500 handler that keeps the private no-store headers. The stale migration head in the backend README and API contract now reads `d9e4b82013c7`.

Verified locally on this branch: 450 backend tests passed with 37 environment-gated skips (the 6 receipt OCR/Places cases that need tesseract, poppler and a serialized SQLite writer failed identically before these changes and are unrelated); Flutter analysis clean and all app tests passed, including new Settings, welcome and repository tests. Not verified: a live deployment, `SUPABASE_SERVICE_ROLE_KEY` on the production machine, a native build, and store submission with the new privacy manifest.

Remaining before a public launch: set the service-role secret on Fly, deploy, resolve the GitHub Actions billing lock so hosted CI runs, obtain Apple external beta approval and Google Play publication, and prove physical-device capture and the first real shop handoff as listed below.

# Current web release — no safe-area insets around the capture dialog, September 15, 2026

The capture page at `/capture/` now vendors original Estimoto
`22f6e42d00ec34af9ad1dcaa98f465b310993454`. In landscape the dialog no longer
pads its top and bottom or the camera panel's bottom edge with the WebView's
reported safe-area insets, and the Plus page zeroes the dialog's insets outright
because the native host already keeps it clear of the system bars. The camera
and the 3D guide take the recovered height.

Source `5db87c00581ac37a28f8499391207a09ee15d385` is deployed on web; `/version`
reports it and `/ready` reports schema `d9e4b82013c7`. Capture source digests
verified, 19 capture-web tests and the capture and web builds passed, and the
served stylesheet hash matches the built artifact. Native installs load
`/capture/` from the API origin, so no native build was produced. GitHub Actions
did not run because of the existing account billing lock.

# Historical web release — cabin door panels and tighter landscape header, September 15, 2026

The capture page at `/capture/` now vendors original Estimoto
`466ff0e6c64761a92802f025bd4b7815aabe4f2f`. Dark inner door panels line the
cabin so the open-door interior views no longer show a bright bar behind the
seats, and in landscape the camera header is one row with the step strip
inline, giving the 3D guide and live camera more height.

Source `5c68d9883856b2167b2ba8fe62058ac325dd2255` is deployed on web; `/version`
reports it and `/ready` reports schema `d9e4b82013c7`. Capture source digests
verified, 19 capture-web tests and the capture and web builds passed, and the
served scene chunk hash matches the built artifact. Native installs load
`/capture/` from the API origin, so no native build was produced. GitHub Actions
did not run because of the existing account billing lock.

# Historical web release — closed greenhouse, clean panel edges and wheel wells, September 14, 2026

The capture page at `/capture/` now vendors original Estimoto
`894444b00c58f7ef96916ebb8c7de0daa52f61bb`. The 3D guide's cabin is one closed
loft with exact-edged glass panes, the hood and door are cut along mesh lines
with no sawtooth, wheel arches are exact circles with double-sided well liners
and tires flush with the fender lip, and the hood stops at the grille top.

Source `fd694d55330423f8284e67a782c8a490df1e6cf5` is deployed on web; `/version`
reports it and `/ready` reports schema `d9e4b82013c7`. Capture source digests
verified, 19 capture-web tests and the capture and web builds passed, and the
served scene chunk hash matches the built artifact. Native installs load
`/capture/` from the API origin, so no native build was produced. GitHub Actions
did not run because of the existing account billing lock.

# Historical web release — per-body 3D proportions, September 14, 2026

The capture page at `/capture/` now vendors original Estimoto
`d2089d8e432a991374e16868ad3b543e5cfa4ea3`. Each body style in the 3D guide has
its own tumblehome, beltline rise, roof drop, rocker height, cross-section
boxiness and nose drop, so sedans read as wedges, coupes as fastbacks and SUVs,
pickups and vans as upright boxes, with the hood and door still on their hinges.

Source `e4dc103e28c8b2381ce30ffa3f837e49b4988d0b` is deployed on web; `/version`
reports it and `/ready` reports schema `d9e4b82013c7`. Capture source digests
verified, 19 capture-web tests and the capture and web builds passed, and the
served scene chunk hash matches the built artifact. Native installs load
`/capture/` from the API origin, so no native build was produced. GitHub Actions
did not run because of the existing account billing lock.

# Historical web release — larger capture panels and connected 3D car, September 14, 2026

The capture page at `/capture/` now vendors original Estimoto
`1eb1cc8d77edd3a30955e8a4b374b3ada9fbc340`. The camera header collapses to one
row above the step strip, the 3D guide and live camera keep at least 18.5% and
47% of the viewport, and the controls scroll into reach on short screens. The
procedural car keeps its hood and driver door on their hinges and carries a
sloping nose. The page no longer requests a cover viewport, which had added a
blank safe-area band under the native app bar, and the Plus-only short-portrait
re-layout for the old camera structure is removed.

Source `36a637dd275fd11361e590193484320c38dde77d` is deployed on web; `/version`
reports it and `/ready` reports schema `d9e4b82013c7`. The first deploy attempt
failed in the Fly release step because the release machine could not resolve
the database hostname; the retry with the same image completed. Capture source
digests verified, 19 capture-web tests and the capture and web builds passed,
and the served `/capture/` index, JavaScript and CSS hashes match the built
artifacts. Native installs load `/capture/` from the API origin, so no native
build was produced. GitHub Actions did not run because of the existing account
billing lock; the checks above ran locally.

# Historical web release — capture layout and VIN guide, September 14, 2026

The customer capture page at `/capture/` now vendors original Estimoto
`5cfb2a9348db7c37dfaf5b42d8631b73a58ac691`. The guided camera splits the leftover
height 30/70 between the 3D guide and the live camera in portrait and gives the
camera 70% of the width at full height in landscape, so the shutter and upload
controls stay on screen. A step strip lists every view with a saved check, jumps
to a tapped view, and uploads a chosen photo straight to that view. The VIN
marker and close-up sit on the latch-side door jamb beside the driver's seat.

Source `4eec3c79034e1a76291c2ea96667628d27aeac72` is deployed on web; `/version`
reports it and `/ready` reports schema `d9e4b82013c7`. Capture source digests
verified, 19 capture-web tests and the capture and web builds passed, and the
served `/capture/` index, JavaScript and CSS hashes match the built artifacts.
Native Android and iOS load `/capture/` from the API origin, so build 15 and
iOS 14 installs receive this layout without a new native build. No native
artifacts were produced. GitHub Actions did not run because of the existing
account billing lock; the checks above ran locally.

# Historical web and Android release — build 15, September 14, 2026

Settings includes Nango (Google Calendar) and Gmail icons under Connections. Both
are explicitly **Not configured**, as requested. Gmail is described only for
car-service appointments, estimates and receipts. This update adds no Gmail
backend, authorization flow or mailbox access.

Source `af950bd002f4ad0ea2189116a3865e80b803a617` is deployed on web and the permanent
Android link. Seven Settings tests, Flutter analysis, 19 capture-web tests and
web/APK/AAB builds passed. The served web bundle and public APK hashes match;
the exact public APK installed over build 14, and both icons were verified in
Settings on a 320x640 Android emulator. Schema remains `d9e4b82013c7`.

[Build-15 evidence](releases/2026-09-14-build15.json) ·
[Phone screenshot](qa/build15/settings.png) ·
[Download latest Android](https://estimoto-plus-api.fly.dev/android/download)

iOS remains on build 14. GitHub Actions did not execute because of the existing
account billing lock; the checks above ran locally. No new invite email was sent.

# Historical release — build 14, September 14, 2026

Web/API and native build 14 use `2390c5ed418a6c2d5db6e98b1424354848ce9176`; schema `d9e4b82013c7`. [Verification](qa/2026-09-14-build14-verification.md) · [Artifacts and provider state](releases/2026-09-14-build14.json).

The Repairs page shows receipt tasks and parts alongside recorded totals, with source links and no double counting. Main Refresh updates details and totals changed on the server. All 254 Flutter tests passed; analysis clean; 27 focused backend receipt tests passed. Signed Android and live web hashes are verified, including native addition/deletion refresh checks and complete synthetic QA cleanup.

Android build 14 is published; iOS 14 is VALID and available internally, with external review blocked by an earlier build. Google Places activation still requires Google Cloud verification, and public-provider New York coverage remains unreliable. Original Estimoto is separately released as build 233.

## Historical release — build 12, September 14, 2026

Web/API and signed native build 12 use `c66ecb4c8b2a47da572bd9659825dd14b6c2a79f`. `/ready` reports schema `d9e4b82013c7`; served JavaScript and public APK hashes match the release artifacts. [Verification](qa/2026-09-14-build12-verification.md) · [Artifacts and provider state](releases/2026-09-14-build12.json).

Receipt PDF/photo totals populate empty Recorded costs, with existing-value protection and explicit replacement review. Dynamic vehicle, ZIP and name search controls are published to Android and internally to iOS. Backend 471 passed / 7 optional skips, Flutter 252 passed, analysis clean and capture-web 19 passed.

Open delivery gates: Google Cloud account verification and Places activation (New York public search still fails); external Apple beta review; physical-device proof. These are not source/test closure claims.

## Historical updates before build 12

# Find Help update — September 14, 2026

Web/API source `1e199ac` is deployed with dynamic vehicle matching, separate
ZIP/name search, expanded public listings and official Bluewater/EuroWerkz
profiles. [Verification and remaining coverage blocker](qa/2026-09-14-discovery-coverage.md).
Public-provider nationwide reliability remains open; native UI builds are pending.

# Current web/API release — September 14, 2026

The approved CRUD closure is deployed from `a01ee14` and the service is healthy
at schema `b7f2c9d4e1a0`. Recent main commits were preserved.
[Final verification and distribution limits](qa/2026-09-14-crud-final-verification.md).
Native downloads remain on the previous build 11; the evidence below is historical.

# Live customer preview — build 11, September 14, 2026

Estimoto + build 11 is live on web and the permanent Android download, from
`9c53dd85889938dd40a8195b89dc4a43bc98f4f9`. Receipt photo/PDF controls are directly on
Add service history, with a fixed Save button and an inline saved-entry receipt
editor. Request help cards, shop profiles, Settings and the updated logo remain.
iOS build 11 is VALID internally; external review remains pending.

[Download latest Android](https://estimoto-plus-api.fly.dev/android/download) ·
[Mobile delivery](mobile-release.md) · [Build-11 evidence](releases/2026-09-14-build11.json) ·
[Audit follow-up](qa/2026-09-13-audit-closure.md)

## Delivered surfaces

| Surface | Verified state |
| --- | --- |
| Customer API/web | `/version` matched `9c53dd8`; `/ready` is ready at schema `a63e90b72d14`. Served JavaScript matches the local build. |
| Android customer app | Signed 0.1.0 (11); exact public APK installed over build 10 on an emulator. Native PDF selection, live private upload, render, cancellation and reopened history verified. |
| iOS customer app | Build 11 VALID, exact 592-character notes and both groups verified. Internal IN_BETA_TESTING; external READY_FOR_BETA_SUBMISSION. Build 2 review preserved. |
| Repository | `main` includes receipt flow and release source `9c53dd8`; no force-push. |
| Hosted CI | [Run 34817696365](https://github.com/JamesMcDaniel04/Estimoto-plus/actions/runs/34817696365) has no executed steps; check `103891868936` confirms the existing billing block. Local verification is separate. |
| Original Estimoto mobile | Separate build 232, source `a0a2af9cfb8c88cb3b7eb9860a42554dcf57714f`, shipped with 38 exact-tab tests and external approval. Its approval does not approve Plus. |

## Customer editing after build 11

Reminders, estimate drafts and their photos, scheduling requests, service
history entries and valuation lookups can now be edited, withdrawn or deleted
from the app; shared estimates and confirmed appointments stay locked.
Reminders: tap to edit or delete, and Undo after marking one complete.
Estimates: edit details, delete the draft and remove saved photos while the
draft is unshared; afterwards the options menu explains the lock. Scheduling
requests: discard unsent drafts (including an interrupted device draft) and
withdraw sent ones, which turns the shop's confirmation link into a 410 with no
message to the shop. Service history: edit any field with receipts kept and the
private graph re-projected. Vehicle value: past lookups are kept per vehicle
(50 most recent), shown newest first and deletable. Estibot: conversations can
be cleared and an unanswered question offers the technician search. Demo:
drafts accept photos through the simple picker, the sample calendar can be
disconnected, and the guided camera reports a typed unavailable code.
Backend migration `b7f2c9d4e1a0` adds `vehicle_valuation_history`.

## Build 11 validation

All 227 app tests and analysis passed, plus 15 focused backend receipt/PDF tests,
one Chrome picker test, 19 capture-web tests and its build. The native live upload
used a scoped synthetic customer and a labeled PDF, with one record/attachment,
exact byte matching and rejected anonymous access. Cleanup removed the account,
vehicle, history, file and derived data; old-token reads and writes returned 401.
Web demo checks verified visible controls, the inline save and return to history.
No real customer mailbox, physical-device or shop-contact result is claimed.

## Historical build 10

[Build 10](releases/2026-09-14-build10.json) restored the network Request help
card action and included Settings, with 217 app tests and its own delivery proof.
Its source `6268375` and earlier records remain historical. The delivered invite
uses the same permanent URL, which now serves build 11; no duplicate email was sent.

## What changed in build 9

Tapping a shop card opens its profile. Call, Website, Google Maps/reviews,
dedicated-shop saving and available request/contact actions are in the profile.
The generated content-hashed brand asset refreshes older browser artwork. See the
[build-9 notes](releases/0.1.0-9-beta-notes.md).

The returning browser displayed the new logo without clearing its cache. Web demo
QA opened a card, its profile and the saved PDR-shop choice; native Android demo
QA saved PDR from the profile choice dialog and saw “Your dedicated shop: PDR”
on the returned list. Both demo sessions were left at welcome and the owned QA
browser tab was closed. The real-owner code tab and user preview were preserved.
No new Auth account,
shop outreach or live customer mutation was used for build-9 checks. These demo
checks do not establish a live customer's saved-shop or request outcome.

Android build 11 uses the same permanent URL already present in the delivered
build-8 invite. No duplicate email was sent.

## What changed in build 8

Find Help now returns a curated list capped at 30 combined results within the
existing approximate 30-mile ZIP-centered radius. Live checks returned **26
reviewed independent businesses plus participating Demolition Dent**. All 27
had website/phone fields and loadable artwork: 26 logos and one owner-published
shop photo. All images decoded successfully; all 26 independent image digests
matched their fixed filenames. Mini profiles expose official business details
and review provenance. Google Maps opens for current reviews; unconfirmed numeric
ratings are not shown. This review does not rate workmanship or establish
appointment availability. Coverage is not exhaustive.

The darker sky-blue icon uses a white E, a smaller navy plus and a separate green
dot above-left of the plus. Unavailable/deleted records keep back navigation;
demo phone scheduling exposes the reviewed call action; demo valuation shows
explicitly fictional local values. Calendar setup suggests a validated device
IANA zone only for an unconfigured preference, preserves saved choices and uses
Denver time in the demo. Late-night availability, email validation and Estibot
capability copy are corrected.

Authentication now pools Supabase connections and briefly caches verified
GET/HEAD identities for at most 15 seconds, never beyond JWT expiry. Writes verify
fresh and invalidate cached reads. Errors and raw tokens are not cached. Production
interactive docs are disabled, main pages have HSTS/frame protection, and web
entry responses require revalidation. Guided capture retains same-origin embedding.

Existing private garage/photos, guided PDR/Collision evidence and VIN confirmation,
reviewed estimate/request handoff, service history/costs/receipts, explicit CarsXE
valuation and saved-shop scheduling remain available. Private evidence is not
public shop artwork; recorded spending is not added to market value. Shop
acceptance, bridge receipt, processing completion and a quoted amount remain
separate states. See the [API contract](api-contract.md) and
[automotive knowledge architecture](automotive-knowledge.md).

## Verification and its boundaries

The complete clean gate ran on `47f8eedfb749509d8540e8468b1cf0eada639308`:
**410 backend tests, zero skipped; 208 Flutter tests and clean analysis; 19
capture-web tests and a successful build; all API/pure-Dart, discovery and
calendar socket smokes**. All 34 previously gated backend cases ran using isolated
PostgreSQL and actual original bridge source. The test cluster was stopped and
removed. Source remained clean and unchanged during that run.

Build 8 (`e5d0e4a`) added only the Android publisher's repository-rename redirect
fix and its regression. Its 16 focused tests passed; these overlap other tests
and are not added to the full-suite total. The full gate was not rerun on that
publisher-only follow-up. Exact SHAs, bounds and evidence hashes are in the
[build-8 record](releases/2026-09-14-build8.json).

Build 9 passed **209 Flutter tests with clean analysis** and **19 capture-web
tests plus its build**. Its backend files are unchanged from build 8, so the full
backend/socket gate remains the `47f8eed` evidence above; it was not rerun as a
new build-9 gate.

Build-8 live checks passed 20 surface checks, including production docs 404s,
security/revalidation headers, shell 304, capture bytes, authentication 401s and
the disabled production dev-session route. Synthetic browser QA rendered all 27
shop images and a mini profile. Its native Android QA loaded the live directory,
displayed Bronco's Muffler's real logo and opened its mini profile. No shop was
contacted and no request was created. These historical signed-in checks remain
build-8 evidence; build-9 browser/native checks above used demo mode.

The build-9 live check at 06:39:10 UTC confirmed the deployed source, ready schema,
JavaScript bytes and exact brand image digest. The returning-browser check then
verified that the new artwork rendered without a cache clear. Raw logs and
screenshots stay private.

The build-8 synthetic QA account was globally signed out, then its Auth account,
profile and rate rows were removed. Other customer-owned tables were confirmed
empty before cleanup. The old token received 401 on a write and a subsequent GET;
the real customer account was untouched. No private files were uploaded. Native
Android displayed the ended-session screen, then signing out returned to welcome.

A fresh requested Android invite was sent once. Resend accepted it at
06:16:05 UTC and provider readback confirmed **delivered** at 06:16:26 UTC on
September 14. It contains the permanent URL that served the verified build-8
APK at delivery and now serves build 9. Recipient opening, installation on the
user's device and normal sign-in code entry are not established by delivery. A normal sign-in code was requested
through the UI; real inbox/code-entry completion is still pending.

## Remaining checks

- GitHub account billing must be resolved before hosted CI can run.
- Plus external TestFlight approval is unverified. Build-9 Apple readback at
  06:44:57 UTC confirmed internal testing and preserved build 2 `WAITING_FOR_REVIEW`.
- Real mailbox/code-entry completion and physical iOS/Android installation,
  camera, receipt and interrupted-picker behavior remain unverified.
- The first real customer-to-shop handoff and actual shop acceptance remain
  unverified. No automated test is counted as a real shop send.
- Google Calendar customer connection remains disabled pending verified provider
  setup. Demo/local checks do not prove a real Google event.
- PDR LINX location/service ZIP information is still required for routing.
  Google Play, CARFAX, push delivery, automated phone/SMS booking and corpus-wide
  model training are not connected.

The customer sharing target remains September 14 at 2 p.m. America/Denver.
The [September 13 readiness snapshot](launch/2026-09-14-customer-launch.md) and
[build-7 evidence](releases/2026-09-13-build7.json) and
[build-8 evidence](releases/2026-09-14-build8.json) retain earlier milestones,
including their then-current follow-up states.
