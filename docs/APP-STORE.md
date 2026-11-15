# App Store listing — Currawong 1.0.0

The text entered in App Store Connect, field by field. It makes claims about
the app, so a change to what the app does is a change here in the same PR
(`APP-38`). Two rules from `APP-25` item 5 hold throughout: never write "no
account required", and keep the privacy claim and the licence disclosure as
two separate statements.

Character counts are measured against Apple's limit.

## App Information

*General ▸ App Information*

### Name (9 / 30)

`Currawong`

If the name is taken on the store, **Currawong Radio** is the fallback.

### Subtitle (29 / 30)

`AllStarLink, EchoLink and M17`

Names all three networks. The words it no longer carries (ham, radio) moved to Keywords.

### Primary category

`Utilities`

This matches LSApplicationCategoryType in project.yml. Leave the secondary category empty.

### Content rights

`Yes, it contains third-party content, and I have the necessary rights.`

The M17 reflector list is DVRef's data, used under CC BY 4.0.

## Age Rating

*General ▸ App Information ▸ Age Rating*

### Age Suitability URL

`https://charlesmartin.au/currawong/age-suitability.html`

The questionnaire calculates **13+**. Answer yes where it asks about users communicating with people they don't know.

## App Privacy

*General ▸ App Privacy*

### Privacy Policy URL

`https://charlesmartin.au/currawong/privacy.html`

### Data collection

`No, we do not collect data from this app.`

Answer this for every category. The reasoning is in APP-25 item 5.

## Pricing and Availability

*General ▸ Pricing and Availability*

### Price

`Free`

### Availability

`All countries or regions, except China mainland`

China mainland removes VoIP-style apps that lack a local licence. Excluding it avoids a takedown.

## Version page

*Distribution ▸ iOS App / macOS App ▸ 1.0.0*

### Promotional Text (133 / 170)

```text
Talk on AllStarLink, EchoLink and M17 from your iPhone, iPad or Mac. Open source, fast, and simple to get listening and transmitting.
```

### Description (2109 / 4000)

```text
Currawong connects your iPhone, iPad or Mac to the amateur radio networks that run over the internet: AllStarLink nodes, EchoLink stations and M17 reflectors. Pick a destination, connect, and hold the button to talk.

Currawong is built to get you on the air quickly. It covers what you need to listen and transmit, without a wall of settings to work through first. The first launch asks for your callsign and nothing else.

FINDING SOMEWHERE TO GO
• AllStarLink: type a node number and Currawong looks up the address. Connect with a node secret, or through Web Transceiver using your allstarlink.org login.
• EchoLink: browse and search the station directory. Currawong finds a public proxy for you, or uses your own if you run one.
• M17: choose a reflector and module from the published reflector list.
Save any of them as a channel and it's one tap away next time.

TRANSMITTING
• Hold the on-screen button to transmit, and let go to stop.
• A transmit watchdog ends any over that runs too long: one minute by default, three at most. It can't be switched off.
• Transmit also stops if you leave the app, lock the screen, or a call comes in.
• After each over, one word tells you how your audio level was: too quiet, good, hot or clipping.

AUDIO AND CONTROL
• Transmit and receive level meters, with microphone and receive gain controls.
• A DTMF keypad for node commands, with a built-in command reference.
• Receive continues with the screen locked.
• If a connection fails, Currawong says what to check.

YOUR LICENCE
Currawong does not verify licences. Transmitting on amateur frequencies requires a licence in your country. Your callsign is sent with every transmission and identifies you as responsible for it. Each network issues its own account or credentials.

PRIVACY
Currawong has no accounts and no server of its own, so nothing you type reaches us. Your channels, callsign and credentials stay on your device, with secrets kept in the Keychain.

OPEN SOURCE
Currawong and its protocol libraries are open source under the Apache 2.0 licence. Source code and support: charlesmartin.au/currawong
```

Changed since 0.2.1: the Bluetooth push-to-talk and headset-button lines are gone (APP-41), the watchdog is one to three minutes (APP-45), the lock-screen Live Activity line is replaced, and the audio verdict (APP-48) and plain connection failures (APP-47) are added.

### Keywords (97 / 100)

```text
ham,amateur,radio,repeater,reflector,node,PTT,push to talk,VoIP,callsign,IAX2,Codec2,hamradio,ASL
```

The app name and the subtitle's words are already indexed, so the three network names are not repeated here.

### Support URL

`https://charlesmartin.au/currawong/#support`

### Marketing URL

`https://charlesmartin.au/currawong/`

### Version

`1.0.0`

Matches CFBundleShortVersionString in project.yml on the v1.0.0-rc branch.

### Copyright

`2026 Charles Patrick Martin`

### What's New in This Version

None.

App Store Connect does not ask for this on an app's first version.

## Screenshots

*Distribution ▸ version page ▸ Previews and Screenshots*

### Files

```text
build/screenshots/iPhone-17-Pro-Max/   iPhone 6.9"   1320 x 2868
build/screenshots/iPhone-17-Pro/       iPhone 6.3"   1206 x 2622
build/screenshots/iPad-Pro-13-inch-M5/ iPad 13"      2064 x 2752
build/screenshots/macos/               Mac           2560 x 1600
```

Three scenes in each folder, light and dark: channels, receiving, transmitting. They were captured on 14 November and nothing merged since changes what they show. Regenerate with **make screenshots** if a bugfix touches the UI.

## App Review Information

*Distribution ▸ version page ▸ App Review Information*

### Sign-in required

`Unchecked`

M17 reflectors need no credentials, so a reviewer can test the whole app without an account.

### Notes (1240 / 4000)

```text
Currawong is an amateur radio client. It connects to AllStarLink, EchoLink and M17 networks run by the amateur radio community. AllStarLink and EchoLink need credentials issued to licensed operators. M17 does not, so it is the easiest mode to review.

To test: the first launch asks for a callsign. Enter APPTEST. Tap Add channel, choose M17, and pick reflector M17-CBR, module A. This reflector is run by the developer and is not linked to any radio transmitter. Connect, and hold the push-to-talk button to transmit. The first time you transmit, a notice explains that the app does not check licences. You can choose "Listen only" at that notice and still test everything except transmitting.

Holding the on-screen button is the only way to transmit. Transmission stops when the button is released, when the app leaves the foreground, and after a time limit of at most three minutes.

Background mode: "audio" keeps received audio playing with the screen locked, as a radio would. The app deliberately does not use CallKit or the VoIP background mode: this is a half-duplex radio link, not a telephone call.

The app collects no data. It has no analytics and no server of its own. Audio goes only to the node or reflector the user chose.
```

Check the M17-CBR dashboard around the time you submit, so module A is quiet. Changed since 0.2.1: the callsign is asked at first launch and is APPTEST, and only the audio background mode is declared.

### Version release

`Manually release this version`

## TestFlight

*TestFlight ▸ Test Information, and each build's What to Test*

### Beta App Description (209 / 4000)

```text
Currawong connects an iPhone, iPad or Mac to an amateur radio node or reflector: AllStarLink, EchoLink or M17. You need your own licence and callsign to transmit, and credentials for whichever network you use.
```

### What to Test (636 / 4000)

```text
Give your callsign, add a channel (pick the network, then a reflector, a station or a node), connect, and hold the PTT button. Check that the status panel agrees with what you actually hear, and tell me when it does not.

The most useful thing you can report is a transmission that did not stop when you let go. The transmit watchdog will end it, but it should never have to.

Known and not worth reporting:
• The on-screen button is the only way to transmit. There is no Bluetooth or headset button.
• A Bluetooth headset used for audio may stop carrying it after keying.
• The first transmit after a pause takes about a second to key.
```

### Feedback email

Kept out of this file; it is on the copy sheet.
