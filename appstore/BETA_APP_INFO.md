# Luche — Beta App Information for App Store Connect

Fields below map 1-to-1 to App Store Connect → TestFlight → "Test Information"
and the App Information sections you need filled before external testing
opens. Copy/paste the values straight in.

---

## App Information

| Field | Value |
|---|---|
| **App name** | Luche |
| **Subtitle** | Score freezing of gait |
| **Bundle ID** | `com.ilovemaggie.svet` |
| **Primary category** | Medical |
| **Secondary category** | Health & Fitness |
| **Primary language** | English (U.S.) |
| **Privacy policy URL** | https://www.getferal.ai/appprivacypolicy |
| **Marketing URL** *(optional)* | https://www.getferal.ai |
| **Support URL** | https://www.getferal.ai |
| **Contact email** | jacopo.razza@gmail.com |

---

## TestFlight → Test Information

### Beta App Description
> Luche scores freezing of gait, a Parkinson's symptom, from a turn-in-place
> test. Point the iPhone camera at the person walking, hit Start, and the
> bottom bar shows per-frame freezing probability live — no internet, no
> upload, all inference on the Neural Engine. Stop to save the session;
> previous sessions can be replayed and exported as PDF reports, JSON
> predictions, or a ZIP of the raw videos.

### What to Test
> 1. Tap **Start** on the home screen, hold the phone in landscape, film a
>    few seconds of someone walking or stepping in place. The colored bar at
>    the bottom should update within ~1 second per chunk.
> 2. Tap **Stop** to save. Open **Previous sessions** from the home screen
>    and tap a card to replay the recorded video.
> 3. Try **Export PDF** on a single card, then **Export all → Human-readable
>    PDF / Machine-readable JSON / Videos (ZIP)** from the toolbar.
> 4. Confirm the model loads with no internet (toggle airplane mode before
>    tapping Start — first-launch model load can take ~2 s, subsequent
>    launches are instant).
>
> Known limits: requires iPhone 16 or newer for real-time scoring; older
> devices will run but with noticeably slower inference.

### Feedback email
jacopo.razza@gmail.com

### Marketing URL *(optional)*
https://www.getferal.ai

### Privacy Policy URL
https://www.getferal.ai/appprivacypolicy

### License Agreement
Use Apple's standard EULA (default). No custom agreement needed.

---

## Beta App Review answers

These appear in the Beta App Review submission flow (the very first external
build of a new app needs human review, ~24 h).

| Question | Answer |
|---|---|
| **Sign-in required?** | Yes |
| **Demo account credentials** | _email:_ `<FILL IN>` · _password:_ `<FILL IN>` |
| **Notes for reviewer** | Sign in with the demo account above (account sign-in is handled by Clerk). After signing in, the app uses the rear camera to record short clips of a person performing a turn-in-place gait test; video inference runs on-device via Core ML and recorded frames are never uploaded. Open the app, tap **Start** in landscape orientation, and within ~1 second the bottom bar should fill with a colored gradient indicating the model's per-frame freezing probability. Tap **Stop** to save the session. |
| **Contact email** | jacopo.razza@gmail.com |

---

## App Privacy questionnaire

App Store Connect → App Privacy. Answer per data type:

| Data Type | Collected? | Linked to User? | Used for Tracking? | Purpose |
|---|---|---|---|---|
| **Camera (Photos/Video)** | Yes | No | No | App Functionality (on-device freeze-of-gait scoring; videos and per-frame predictions stay in the app sandbox until the user explicitly exports them) |
| **Device ID** | No | – | – | – |
| **User ID** | No | – | – | – |
| **Crash data** | No | – | – | – |
| **Performance data** | No | – | – | – |
| **Other diagnostic data** | No | – | – | – |
| **Contacts, Health & Fitness, Location, etc.** | No | – | – | – |

**Third-party SDKs**: none. No analytics, no ads, no crash reporters.

---

## Export compliance

| Question | Answer |
|---|---|
| Does your app use encryption? | Yes |
| Does it qualify for an exemption? | Yes — uses standard encryption only (HTTPS / CommonCrypto via system frameworks). No proprietary or non-standard encryption. |
| Required to comply with US export regulations? | No (exempt) |

---

## Age rating

Run through the questionnaire — every answer is **None / No** for this app.
Result: **4+**.

---

## Required selections in App Store Connect (dropdowns, toggles, checkboxes)

Every screen you'll click through during app creation + first build upload,
in order, with the exact value to pick.

### When creating the app (My Apps → + → New App)
| Field | Pick |
|---|---|
| Platforms | iOS (only) |
| Name | Luche |
| Primary language | English (U.S.) |
| Bundle ID | `com.ilovemaggie.svet` |
| SKU | `luche-ios-001` (any unique string, never shown to users) |
| User Access | Full Access |

### App Information → General Information
| Field | Pick |
|---|---|
| Subtitle | Score freezing of gait |
| Privacy Policy URL | https://www.getferal.ai/appprivacypolicy |
| Category — Primary | Medical |
| Category — Secondary | Health & Fitness |
| Content Rights — Contains, shows, or accesses third-party content? | No |
| Age Rating | Click "Edit", answer **None / No** to every question → result is 4+ |

### Pricing and Availability
| Field | Pick |
|---|---|
| Price | Free |
| Availability | All countries and regions |
| Pre-Orders | Off |
| Distribute on Apple Vision Pro | Off |

### App Privacy → Data Types
Click **Get Started**.

1. "Does this app collect any data?" → **Yes**.
2. Tick only **Camera (Photos / Video)** under "User Content".
3. For Camera, then click through:
   | Question | Answer |
   |---|---|
   | Is this data collected from this app? | Yes |
   | Is this data linked to the user's identity? | No |
   | Is this data used for tracking purposes? | No |
   | Purposes (pick at least one) | App Functionality |
4. Save. Privacy "card" should now show: *Data Not Linked to You — User Content (Photos or Videos)*.

### TestFlight → Test Information
| Field | Value |
|---|---|
| Beta App Description | (paste from this doc) |
| Feedback Email | jacopo.razza@gmail.com |
| Marketing URL | https://www.getferal.ai |
| Privacy Policy URL | https://www.getferal.ai/appprivacypolicy |
| License Agreement | Use Apple's standard EULA |

### TestFlight → External Testing → Submit for Beta App Review
| Field | Pick |
|---|---|
| Sign-in required? | Yes |
| Demo account credentials | enter the demo email + password (see Beta App Review answers above) |
| What's New in This Build | "Initial TestFlight build." |
| Notes for Review | (paste the "Notes for reviewer" line from above) |
| Contact info — First/Last/Email/Phone | your real details |

### Per-build (after each Xcode upload)

#### Encryption / Export Compliance
You'll be prompted in App Store Connect (or Xcode can answer it for you via
`ITSAppUsesNonExemptEncryption` in Info.plist):

| Question | Pick |
|---|---|
| Does your app use encryption? | **Yes** (HTTPS / Apple system frameworks count) |
| Does your app qualify for any exemptions? | **Yes** — *Uses encryption that is exempt because it only uses encryption provided by Apple's operating system* |
| Required to comply with U.S. export regulations? | No (exempt) |

To pre-answer this in the build itself and skip the App Store Connect prompt
forever, add this key to `Info.plist` (already done if you want me to):
```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```
*Setting it to `false` is correct here — Apple treats "uses only standard
system encryption" as equivalent to "no non-exempt encryption" for this flag.*

### iOS / device support
| Field | Pick |
|---|---|
| Minimum iOS version | 17.0 *(matches `IPHONEOS_DEPLOYMENT_TARGET` in project.yml)* |
| Devices | iPhone (the project sets `TARGETED_DEVICE_FAMILY: "1"`) |
| Supported orientations | Landscape Left, Landscape Right *(already locked in Info.plist)* |
| Required Capabilities (Info.plist) | none beyond default |

### Things you can leave blank or skip

- App Review Information → "Notes for App Review" (only required at full
  release, not TestFlight)
- In-App Purchases (none)
- Subscriptions (none)
- Game Center (off)
- App Clips (none)
- Family Sharing (skip)
- Volume Purchase Program (skip)
- Russian or Chinese localizations (skip unless you need them)

---

## App Store description *(later, when going live; not required for TestFlight)*

### Promotional Text *(170 chars)*
> Score freezing of gait — a Parkinson's symptom — from a turn-in-place test. Real-time on iPhone, fully on-device, no internet required.

### Description
> Luche scores freezing of gait (FOG) from short videos of a person performing a turn-in-place test. Aimed at clinicians and researchers tracking the motor symptoms of Parkinson's disease.
>
> Open the app, tap Start, point the camera at the person walking. A colored bar at the bottom of the screen shows the model's per-frame freezing probability in real time. Tap Stop and the recording is saved as a session — replay the video, export a clean PDF report with a per-frame fog graph, or export every session at once as PDF, JSON, or a ZIP of videos.
>
> All inference runs on-device using a fine-tuned V-JEPA 2.1 vision transformer compiled to Core ML. Recordings, scores, and metadata never leave the phone unless you explicitly share them.
>
> • Real-time scoring on iPhone 16 and newer
> • Fully on-device — no internet, no account
> • Replay any saved session
> • Export per-session PDF reports, all-session PDF (with TOC links), JSON, or ZIP of videos
> • Privacy-first: nothing leaves the device until you tap Share

### Keywords *(100-char limit, comma-separated, no spaces after commas)*
> parkinsons,freezing,gait,FOG,clinical,medical,video,gait analysis,neurology,research

### Support URL
https://www.getferal.ai

### Marketing URL
https://www.getferal.ai
