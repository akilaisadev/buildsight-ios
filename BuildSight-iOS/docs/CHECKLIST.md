# Project checklist (from the lecturer's list)

Status key: **Done** = built and checked in this build · **Done (limited)** = built, with a stated limit · **Open** = not finished.
No Apple Developer account is used anywhere in this project.

| # | Item | Status | What exists | Limit / evidence |
|---|---|---|---|---|
| 1 | Auth | Done | Email and password sign-in, session stored in the Keychain, Face ID / Touch ID unlock, password reset, expired-session handling, role-based permissions | Live smoke test passed (sign-in, refused wrong password, profile, membership). Face ID not tested on a real device |
| 2 | Settings / Profile | Done | Profile, Appearance (System / Light / Dark), notification preferences, permissions, Sync Center, Sign Out | Viewed in code; visual check pending |
| 3 | API | Done (limited) | Supabase REST: sign-in, profile, membership, records read, `upsert_record` write, evidence storage | Reads tested live. Writes, replays and conflicts tested locally (27 SQL rule checks) but not yet live |
| 4 | Dashboard | Done | Home: project header, open issues / inspections due / tasks today, action cards, site areas, Today's log | Counts are real data from the server |
| 5 | Push notifications | Done (limited, no developer account) | Local alerts for new items while the app is open (checked every minute), local reminders for tasks and inspections, in-app Notifications list | **No alerts when the app is closed.** Apple's push service needs a paid developer account, which this project does not use. Stated in the report |
| 6 | Face ID | Done (limited) | Face ID / Touch ID gate on sensitive actions and app unlock; password fallback | Not tested with a real Face ID device (the simulator needs enrolment) |
| 7 | Site evidence (issue) | Done | Capture photo with GPS, create an issue, on-device helmet/PPE check, human review (confirm / correct / dismiss) | Camera and GPS need a real iPhone |
| 8 | Activity timeline and site map | Done | Site Log (timeline with filters), map of GPS records with a no-location note | Map shows a site only once records have GPS; the demo project has none |
| 9 | Inspection | Done | Inspection checklist, progress saving, completion rules | Demo has no inspections yet |
| Adv 1 | Core ML | Done (limited) | On-device YOLOv8 model: helmet, no helmet, vest, gloves, no gloves | "No helmet" and "no gloves" are weak (AP about 0.1); used as review hints only |
| Adv 2 | MapKit + Core Location | Done | Map of real records with GPS; **geofencing**: each project's site location (from the database) is a monitored region, and arriving or leaving raises an alert (Settings → Site arrival alerts) | Verified in the simulator: moving onto the Colombo site logged "entered", moving away logged "left". Needs Always location access. Planner logic covered by 5 Swift Testing tests |
| Adv 3 | WidgetKit | Done (limited) | Home-screen flag widget (`BuildSightFlagWidget`) fed from the app through an App Group | Built into the app, not checked on a home screen yet |
| Adv 4 | QR codes | Done | Printable area QR codes (Settings → Area QR codes); "Scan area code" on the camera screen tags a photo to the area | QR text verified: a generated code decodes to the exact area link. Live camera scan needs a real iPhone |

## Not part of this build
- Remote push while the app is closed (needs a paid developer account).
- Real-device testing of camera, GPS, Face ID, widget and haptics.
- Live multi-device sync testing.
