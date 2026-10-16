# Specter login without the stats.fm mobile app

A set of small PowerShell scripts to sign in to the **Specter** desktop app
(stats.fm) on Windows **without the stats.fm mobile app**. Specter's only login
is a QR/webcode flow that needs the phone app to approve it; if you can't use the
phone app, these let you sign in with your own stats.fm account directly.

> **Disclaimer.** Unofficial. Not affiliated with, endorsed by, or supported by
> stats.fm / StatsFM B.V. It only ever uses **your own** stats.fm account on
> software **you** installed — it does not bypass payment, access anyone else's
> data, or touch stats.fm's servers beyond a normal login. It relies on
> undocumented app internals and **may break at any time**. Use at your own risk;
> see the warranty disclaimer in [LICENSE](LICENSE).

Specter has no username/password login — its QR flow exists only to copy your
**stats.fm access token** onto the machine. So "logging in" really means
reproducing the state a successful login leaves on disk. These scripts do that.

## Install

Clone the repo (or download the ZIP from GitHub), then run the scripts from the
folder:

```powershell
git clone https://github.com/Lukas200301/specter-login-helper.git
cd specter-login-helper
pwsh -File .\specter-login.ps1
```

## The core insight

A logged-in Specter leaves two things behind:

1. A **Windows Credential Manager** entry holding the token, named
   `Specter_ABCDEFGHIJKLMNOPQRST12345678_authToken`.
2. The flag `"flutter.loggedIn":true` in
   `%APPDATA%\stats.fm\Specter\shared_preferences.json`.

That credential name is not a guess. Specter bundles the `flutter_secure_storage`
plugin, which prefixes every key with a compile-time constant. The constant
(`Specter_ABCDEFGHIJKLMNOPQRST12345678_`) was extracted directly from
`flutter_secure_storage_windows_plugin.dll`, so the name is exact. The plugin
build Specter uses stores each secret as a Credential Manager "generic
credential"; newer builds use an encrypted file but still fall back to reading
this same credential, so writing it works for every build.

The whole job is therefore: **get your token, then write those two things.**

---

## Scripts

| Script | Purpose |
|---|---|
| `specter-login.ps1` | One-shot: open browser → you sign in → capture token → inject. No installs. |
| `specter-link.ps1` | Writes the credential + `loggedIn` flag from a token. Supports `-Revert`. |
| `specter-get-token.ps1` | Reads the token out of a machine that is already logged in. |
| `specter-diagnose.ps1` | Read-only inspection of Specter's storage. |

> Run everything as the **same Windows user** that runs Specter, with **Specter
> closed**. PowerShell 7 (`pwsh`) or Windows PowerShell 5.1 both work.

---

## `specter-login.ps1` — how the token is captured

```powershell
pwsh -File .\specter-login.ps1
```

1. **Find a browser.** Looks for `msedge.exe` then `chrome.exe` in the standard
   install paths. Edge ships with Windows 11, so nothing needs installing.

2. **Launch it with a remote-control port:**
   ```
   msedge.exe --remote-debugging-port=9222 --user-data-dir=<temp profile> https://stats.fm/login
   ```
   - `--remote-debugging-port=9222` enables the **Chrome DevTools Protocol
     (CDP)** — the channel DevTools and automation tools use to inspect a page.
     This is how a plain script can later read what's inside the browser.
   - `--user-data-dir=<temp>` starts a throwaway profile. Browsers refuse remote
     debugging on your normal profile for security, so a separate profile is
     mandatory; it also keeps your real sessions untouched and is deleted at the
     end.

3. **You sign in.** The window opens on stats.fm's login; you click *Continue
   with Spotify / Apple* and authenticate. The script waits.

4. **Capture the token.** stats.fm's own JavaScript stores the token in a
   **cookie named `identityToken`** (a JWT) and reads it back with
   `Cookies.get("identityToken")` to send as `Authorization: Bearer …`, which
   means it is readable by JavaScript. So, in a loop every 1.5 s, the script:
   - calls `http://localhost:9222/json` to list open tabs and finds the one
     whose URL contains `stats.fm`;
   - opens a **WebSocket** to that tab's DevTools endpoint (via .NET's
     `ClientWebSocket`, built into PowerShell — no library needed);
   - sends one CDP command, `Runtime.evaluate` with expression `document.cookie`,
     which runs that JS *inside the page* and returns the result;
   - scans for `identityToken=…`, URL-decodes it, and checks it looks like a JWT
     (three dot-separated parts, > 40 chars).

   It keeps polling because `document.cookie` is irrelevant while you're on
   Spotify's domain mid-login; the `identityToken` only appears once you land
   back on `stats.fm`.

5. **Clean up and inject.** Once it has the token it closes the browser, deletes
   the temp profile, and calls `specter-link.ps1 -Token <captured token>`.

Nothing is installed, nothing of yours is touched, and the token never leaves
your machine.

---

## `specter-link.ps1` — how the token is written

```powershell
pwsh -File .\specter-link.ps1 -Token "<token>"   # inject
pwsh -File .\specter-link.ps1 -Revert            # undo
```

1. **Writes the credential.** Calls the Windows API `CredWriteW` (reached from
   PowerShell via a small `Add-Type` C# shim) to create a **generic credential**
   named `Specter_VGhpcyBpcyB0aGUgcHJlZml4IGZv_authToken`, with:
   - the credential blob = the token as **UTF-8 bytes plus a trailing `\0`** (the
     plugin's C++ reads the blob as a C-string, so the null terminator must be
     present);
   - persistence = **Local Machine** (matching a real login, confirmed via
     `cmdkey /list`).

   Windows encrypts that blob at rest, tied to your user account — which is why
   it only works when run as the same Windows user that runs Specter.

2. **Sets the flag.** Merges `"flutter.loggedIn":true` into
   `shared_preferences.json` (preserving other settings like theme), written as
   **UTF-8 without a BOM** — Windows PowerShell 5.1's default BOM would break
   Flutter's JSON parser.

3. **`-Revert`** does the inverse: `CredDeleteW` removes the credential and sets
   `loggedIn` back to `false`.

On next start, Specter reads the credential, sees `loggedIn=true`, sets the
token as its Bearer, calls the stats.fm API, and shows you as logged in.

It also accepts the token via the `SPECTER_TOKEN` environment variable as a
fallback to `-Token`.

---

## Helper scripts

### `specter-get-token.ps1`
On a machine already logged in, `CredReadW`s the same credential and copies the
token to the clipboard (`-Show` also prints it). This is how the token can be
moved manually between two machines without the browser flow.

### `specter-diagnose.ps1`
Read-only. Prints the storage folder, any stored files, the
`shared_preferences.json` contents, and whether the credential exists. Useful
for confirming which storage format a given Specter build uses.

---

## Caveat: token lifetime

The browser flow yields stats.fm's **web** `identityToken`, a shorter-lived JWT
than the long-lived token the phone app hands to the desktop. Everything works
identically, but the web token may expire sooner. If Specter logs you out after
a while, just re-run `specter-login.ps1` — it re-links in a few seconds.

---

## Requirements

- Windows 10/11, with **Microsoft Edge** or **Google Chrome** installed.
- **PowerShell 7** (`pwsh`) or Windows PowerShell 5.1.
- Run as the same Windows user that runs Specter, with Specter closed.

Tested with Specter
[V1.0.0-B9](https://github.com/statsfm/specter-releases/releases/tag/V1.0.0-B9).
Other builds may use a different storage format or key prefix — run
`specter-diagnose.ps1` to check.

## License

[MIT](LICENSE). Provided "as is", without warranty of any kind.

Not affiliated with stats.fm / StatsFM B.V. "stats.fm" and "Specter" belong to
their respective owners. Album artwork and listening data are provided by
Spotify AB.
