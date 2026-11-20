# Publishing Castnet

Where each part goes, what it costs, and what to change in Castnet afterwards. Fees and rules below are as of late 2026; check the stores' own pages before paying.

| Where | For | Cost | You upload | Review |
|---|---|---|---|---|
| **Chrome Web Store** | Chrome, Brave, Arc, Vivaldi (and Opera, Edge via "allow other stores") | US$5 once | `dist/store/castnet-chrome-<version>.zip` | Days to a few weeks (broad permissions get a closer look) |
| **Microsoft Edge Add-ons** | Edge | Free | the same zip | Usually days |
| **Firefox Add-ons (AMO)** | Firefox, Zen, LibreWolf, Floorp, Waterfox | Free | `dist/store/castnet-firefox-<version>.xpi` (+ source zip) | Signing in minutes; listed add-ons may get a human review later |
| **Safari** | Safari | Apple Developer Program, US$99/year | nothing: you sign and notarize the Mac app | Notarization takes minutes; no content review |

`node scripts/build-extensions.mjs` (also run by `scripts/build.sh`) writes the three files in `dist/store/`.

## Decide these first (they're hard to change later)

- **The IDs.** Castnet uses `app.castnet.mac` (app), `app.castnet.mac.safari` (Safari extension), `app.castnet.host` (browser ↔ app bridge) and `castnet@castnet.app` (Firefox add-on). Once you publish, the Firefox ID and the app's bundle ID must stay the same forever, or updates break. If you'd rather use your own domain (for example `com.yourname.castnet`), change them before the first upload.
- **The name.** I checked app stores and add-on stores and found no other "Castnet" there. That isn't a trademark search: before spending money on the brand, search your country's trademark office (for example USPTO, EUIPO or WIPO's Global Brand Database).
- **YouTube in the Chrome Web Store.** Google doesn't accept Chrome Web Store extensions that download YouTube videos (YouTube's terms forbid it, and the store enforces them). Mozilla currently lists video downloaders that handle YouTube, and Developer ID apps aren't content-reviewed. So the Chrome Web Store build needs YouTube hidden in the extension, with the Mac app's own *Add URL* still able to handle YouTube links. That's a small change to the store build only.
- **A privacy policy page.** The Chrome Web Store requires one because the extension handles cookies and page addresses; Mozilla asks for one too. Any public URL works (GitHub Pages is free). A starting text:

  > Castnet runs entirely on your Mac. The browser extension looks at the pages you visit to find videos and files, and sends the address, the request headers and the cookies for that site to the Castnet app on the same Mac, only so the app can download what you chose. Nothing is sent to the developer or any server the developer runs. Castnet has no analytics, ads or accounts. Settings stay on your Mac. Contact: <your email>.

- **Listing material**: a support email or site, screenshots (`docs/screenshots/`; the Chrome Web Store wants 1280×800 or 640×400), the 128-pixel icon (`extension/icons/icon128.png`), and for the Chrome Web Store a 440×280 promo tile.

## Chrome Web Store

1. Go to the [Chrome Web Store developer dashboard](https://chrome.google.com/webstore/devconsole), sign in with a Google account that has 2-Step Verification, pay the one-time US$5 fee, and verify your contact email. Fill in the trader declaration (it's shown to EU users).
2. **New item → upload** `dist/store/castnet-chrome-<version>.zip`. This copy has no `key` field, so the store gives the extension its own ID. **Copy that ID now** (32 letters, shown on the item page).
3. **Store listing**: name *Castnet: Video & Download Catcher*, the description, category *Tools*, language, icon, screenshots, promo tile.
4. **Privacy practices**:
   - Single purpose: *Finds videos and files on web pages and sends them to the Castnet app on your Mac for download.*
   - Remote code: *No*.
   - Data: Castnet sends nothing to you, so declare no collection, tick the three certifications, and paste your privacy policy URL.
   - Permission justifications (paste these):

     | Permission | Why |
     |---|---|
     | `webRequest` | Recognizes video, audio and stream files from the page's network responses on any site |
     | `webNavigation` | Knows when a page finished loading, to get a fresh link when a download's link expired |
     | `tabs` | Reads the tab's title and address to name downloads, and opens the page again in the background to renew expired links |
     | `cookies` | Gives the site's cookies to the Castnet app so downloads that need a signed-in session work |
     | `downloads` | Hands normal browser downloads to Castnet (you can turn this off) |
     | `nativeMessaging` | Talks to the Castnet app on the Mac |
     | `contextMenus` | Adds "Download with Castnet" to the right-click menu |
     | `storage` | Remembers settings and which sites Castnet is turned off for |
     | `notifications` | Says when a download couldn't start |
     | `alarms` | Checks once a minute for downloads waiting for a fresh link |
     | Access to all sites | Videos can be on any website |

5. **Distribution**: Public (or Unlisted while testing), then **Submit for review**.
6. Rebuild the Mac app so the store copy is allowed to talk to it (you can do this as soon as you have the ID):
   ```bash
   CHROME_EXTENSION_IDS=<store-id> ./scripts/make-dmg.sh
   ```
   Several IDs are comma-separated (add the Edge one below). Without this, the store version shows "Castnet app isn't installed".
7. Every update: raise the version, rebuild, upload the new zip on the item's **Package** tab.

### Microsoft Edge Add-ons

Register (free) at [Microsoft Partner Center](https://partner.microsoft.com/dashboard/microsoftedge/overview), create a new extension, upload the same zip, and fill in the same listing and privacy answers. Edge gives yet another ID: add it to `CHROME_EXTENSION_IDS`, for example `CHROME_EXTENSION_IDS=<chrome-id>,<edge-id>`.

## Firefox Add-ons (Firefox, Zen and the other Firefox-based browsers)

Make a free account at [addons.mozilla.org Developer Hub](https://addons.mozilla.org/developers/). Mozilla signs every add-on; regular Firefox only installs signed ones permanently. There are two ways, and you can do both.

**A. Signed, but not listed (fastest, recommended first).** In the Developer Hub choose **Submit a New Add-on → On your own**, upload `dist/store/castnet-firefox-<version>.xpi`. It goes through automatic checks only, and you download the signed `.xpi` (usually within minutes). Then build the Mac app with it:
```bash
SIGNED_XPI=~/Downloads/castnet-1.5.0.xpi ./scripts/make-dmg.sh
```
The build refuses an unsigned file. With the signed add-on inside, Castnet's setup window switches every Firefox-family browser to one click: no `about:config`, no developer pages, and it stays installed after restarts.

**B. Listed on addons.mozilla.org (a public page people can find).** Choose **On this site**, upload the same `.xpi`.
- When asked whether you need to submit source code, answer **yes**, because `background.bundle.js` is generated. Upload `dist/store/castnet-extension-source-<version>.zip`; its `BUILD.txt` tells reviewers how to rebuild it.
- Fill in the summary (up to 250 characters), description, categories (*Download Management*), support email, license and privacy policy.
- The add-on already declares in its manifest that it collects no data, which new Firefox add-ons are required to state.
- Signing is quick. A human reviewer may look later and can ask questions by email.

Command-line alternative for both: create API keys under **Tools → Manage API Keys**, then from `dist/extensions/firefox` run `npx web-ext lint`, and `npx web-ext sign --channel=unlisted` (or `--channel=listed`) with `--api-key` and `--api-secret`. Every update needs a higher version number and a new signature. The add-on ID `castnet@castnet.app` must never change.

## Safari

Safari extensions ship inside a Mac app, and Castnet's already does (`Castnet.app/Contents/PlugIns/CastnetSafari.appex`). Today it's ad-hoc signed, which is why Safari only runs it with *Allow unsigned extensions* turned on. Signing it with your Apple Developer ID removes that step for everyone.

1. Join the [Apple Developer Program](https://developer.apple.com/programs/) (US$99/year).
2. Create a **Developer ID Application** certificate: Xcode → Settings → Accounts → *Manage Certificates* → **+**, or on developer.apple.com under Certificates. It needs the Account Holder role, and lands in your keychain.
3. Create an app-specific password for your Apple Account at [account.apple.com](https://account.apple.com), then save it for the notary tool once:
   ```bash
   xcrun notarytool store-credentials castnet --apple-id you@example.com --team-id TEAMID --password abcd-efgh-ijkl-mnop
   ```
4. Build, sign and notarize in one go:
   ```bash
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=castnet ./scripts/make-dmg.sh
   ```
   It signs the app, its helpers and the Safari extension with the hardened runtime, sends the DMG to Apple, and staples the result. Add `CHROME_EXTENSION_IDS` and `SIGNED_XPI` on the same line once you have them.
5. What your users do: open the DMG, drag Castnet to Applications, open it once, then in Safari open **Settings → Extensions**, turn on **Castnet**, and allow it on every website. There's no Gatekeeper warning, and no developer setting.

**Why not the Mac App Store?** App Review doesn't accept apps that download media from services like YouTube without the rights holder's permission (guideline 5.2.3), or apps that download and run new code (guideline 2.5.2: Castnet keeps its site-support component up to date by itself). The App Store also requires the whole app to run in a sandbox, which its download engine doesn't. Developer ID distribution has none of these limits.

## Release checklist

1. Raise the version in `app/Sources/CastnetCore/Util.swift`, `app/Sources/castnet-host/main.swift` and `extension/manifest.json` (keep them the same).
2. `./test/run-all.sh`, then `node test/e2e.mjs <tmp>` and `./test/dmg-test.sh dist/Castnet-<version>.dmg`.
3. Upload the new Chrome zip (Chrome Web Store, Edge), sign the new `.xpi` on AMO.
4. Build the release:
   ```bash
   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=castnet \
   CHROME_EXTENSION_IDS=<chrome-id>,<edge-id> SIGNED_XPI=<signed.xpi> \
   CASTNET_UPDATE_URL=https://…/castnet-update.json ./scripts/make-dmg.sh
   ```
5. Put the DMG online and update the JSON feed (`{"version":"1.6.0","url":"https://…/Castnet-1.6.0.dmg"}`), so installed copies show *Update available*.
