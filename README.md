# MailPush for KOReader (Android & everywhere)

**Send an email with an ebook attached → your device downloads it automatically the next time it is online.**

A native [KOReader](https://github.com/koreader/koreader) plugin that turns any IMAP
mailbox into a private "Send-to-Device" address — a self-hosted, private alternative
to Amazon's `@kindle.com` push service. No extra server program, no VPS required,
nothing to run on your computer. Just email.

```
Phone / PC                                    E-reader
┌──────────────┐   email + EPUB attachment   ┌─────────────────────┐
│ Mail client  │ ──────────────────────────► │ your IMAP mailbox   │
└──────────────┘                             └──────────┬──────────┘
                                                        │ IMAPS (993)
                                                        ▼
                                             ┌─────────────────────┐
                                             │ KOReader + MailPush │
                                             │ downloads new books │
                                             └─────────────────────┘
```

## Features

- **Pure Lua, native KOReader plugin** — runs anywhere KOReader runs, tested on
  Android 8.1 e-ink devices (Likebook K103) but not Android-specific
- **IMAP over TLS with certificate verification** — ships with a Mozilla CA bundle;
  server certificates are actually validated (most KOReader network code skips this)
- **Safe dedup, no lost books** — fetches use `BODY.PEEK[]`, and a message is marked
  `\Seen` (and recorded by UID) **only after** every attachment was downloaded.
  A disconnect mid-download never loses a book — it is simply retried next time.
- **UIDVALIDITY-aware** — local UID state is automatically invalidated if the server
  renumbers messages
- **Streaming, constant-memory MIME parser** — base64 payloads are decoded to disk
  in aligned 8 KB chunks, so a 30 MB book never sits in RAM (e-ink devices have
  512 MB); nested `multipart/*` boundaries are handled recursively
- **Multiple attachments per email**, configurable file-type whitelist
  (epub, pdf, mobi, azw3, cbz, fb2, djvu, txt, …)
- **Recipient filter** — e.g. only accept mail addressed to
  `you+koreader@gmail.com`, so the same mailbox can serve other purposes
- **Hardened filenames** — path traversal (`../../etc/passwd`), control characters
  and Windows-hostile characters are sanitized; duplicate names get ` (1)` suffixes
- **Size cap** — attachments larger than the configured limit (default 30 MB) are
  discarded with a notice instead of filling your device
- **Fetch when online, honestly** — no fake background polling (Android would kill
  it anyway). On launch it fetches if online; if offline it registers with
  KOReader's NetworkMgr and **re-runs automatically the moment connectivity returns**
- **Manual "Fetch now"** menu action, also exposed via KOReader Dispatcher so you
  can bind it to a gesture, a key, or a profile
- **No hardcoded credentials** — the account is stored in KOReader's settings
  directory on the device (`settings/mailpush-android.lua`), never in the code

## Installation

1. Grab the repository (or a release) as a folder named `mailpush-android.koplugin`
   containing `main.lua`, `imap.lua`, `attachment.lua`, `encoding.lua`,
   `filesystem.lua`, `manifest.lua`, `_meta.lua` and `cacert.pem`
2. Copy it to the KOReader **plugins** directory:

   | Platform | Path |
   |---|---|
   | Android | `/sdcard/koreader/plugins/` |
   | Kindle | `/mnt/us/koreader/plugins/` |
   | Kobo | `/.adds/koreader/plugins/` |
   | PocketBook | `/applications/koreader/plugins/` |
   | Linux | `~/.config/koreader/plugins/` |

3. Restart KOReader

### On Android (adb)

```sh
adb push mailpush-android.koplugin /sdcard/koreader/plugins/
adb shell am force-stop org.koreader.launcher
```

## Configuration

Open **Tools → MailPush (email to device) → Account** and fill in:

| Field | Example | Notes |
|---|---|---|
| Email account | `you@163.com` | the mailbox the device logs into |
| Password | *app password / 授权码* | **never** your real password |
| IMAP server | `imap.163.com` | see table below |
| IMAP port | `993` | TLS port |
| Only accept mail addressed to | `you+koreader@gmail.com` | optional recipient filter |

Other menu options:

- **Download folder** — pick any folder via KOReader's folder chooser
  (defaults to the KOReader data directory, always writable on Android)
- **File types** — per-extension whitelist
- **Fetch on startup** — automatic fetch ~5 s after KOReader opens
- **Mark processed mail as read** — on by default
- **Reset processed-mail memory** — clears the UID state (downloaded files are kept)

### Provider cheat sheet

| Provider | IMAP server | Port | Password to use |
|---|---|---|---|
| Gmail | `imap.gmail.com` | 993 | App password (needs 2FA) |
| Outlook | `outlook.office365.com` | 993 | App password |
| QQ 邮箱 | `imap.qq.com` | 993 | 授权码（设置→账户→开启 IMAP） |
| 163 网易邮箱 | `imap.163.com` | 993 | 授权码（设置→POP3/IMAP→开启） |
| iCloud | `imap.mail.me.com` | 993 | App-specific password |
| ProtonMail | via ProtonMail Bridge | 1143 | Bridge password |

> **NetEase (163/126) note:** these servers reject every command after login with
> `Unsafe Login` unless the client sends an IMAP `ID` command first. This plugin
> sends one automatically.

### Typical setup (one mailbox, zero cost)

1. Enable IMAP on your mailbox and generate an app password
2. Configure the plugin on the device
3. Email books as attachments to that address (send to yourself)
4. Open KOReader — new books appear in the download folder

Optional: use plus-addressing (`you+koreader@gmail.com`) as the recipient filter so
only "book deliveries" are processed.

## How it works (protocol)

Per fetch run, after `LOGIN` and `ID`:

1. `SELECT INBOX` — capture `UIDVALIDITY`; if it changed since last run, the local
   processed-UID table is cleared
2. `UID SEARCH UNSEEN` — candidate messages, newest first, capped (default 20)
3. For each candidate not already in the local processed table:
   `UID FETCH <uid> BODY.PEEK[HEADER]` — cheap recipient-filter check (optional)
   `UID FETCH <uid> BODY.PEEK[]` — full message, streamed with exact literal
   byte-accounting through the MIME parser to disk
4. Only if the whole message streamed without error:
   `UID STORE <uid> +FLAGS.SILENT (\Seen)` **and** record the UID locally

Crash at any point before step 4 → nothing is marked, the mail is retried on the
next fetch. Files are written as `.tmp` and atomically renamed on success.

## Testing

`tests/logic_test.lua` is a self-contained logic test for the MIME parser and
filename sanitizer (KOReader modules are stubbed):

```sh
lua tests/logic_test.lua   # any Lua 5.1+; needs `base64` CLI for fixtures
```

It covers: byte-exact base64 streaming decode, path-traversal sanitization,
oversize-attachment abort, duplicate-name handling.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Login failed` | Using the account password instead of an app password/授权码; IMAP not enabled in the mailbox settings |
| `Unsafe Login` (NetEase) | Server requires IMAP `ID` — this plugin handles it; make sure you run a current version |
| `Connection failed` | Wrong server/port, or the device is offline. Gmail is unreachable from mainland China without a proxy |
| Nothing downloaded but "checked" ran | Recipient filter doesn't match the To/Cc address; extension not whitelisted; attachment over the size cap |
| Where did the file go? | Check **Download folder** in the menu; default is the KOReader data dir |
| Fetch never happens on Android | It runs when KOReader starts or when you invoke Fetch now — there is deliberately no background service |

## Privacy & security

- Your credentials live only on the device, in `koreader/settings/mailpush-android.lua`
- TLS peer certificates are verified against the bundled Mozilla CA store
  (`cacert.pem`); consider refreshing it occasionally
- The mailbox is read-only for this plugin: nothing is deleted, mail is only
  flagged `\Seen`

## Credits

- Streaming MIME/literal parsing adapted from
  [marinov752/emailtokoreader.koplugin](https://github.com/marinov752/emailtokoreader.koplugin)
  ([dumpster-dev original](https://github.com/dumpster-dev/emailtokoreader.koplugin), MIT)
- UID-based fetch/flag protocol after
  [dpolarov/MailPush-for-Kindle](https://github.com/dpolarov/MailPush-for-Kindle)

## License

MIT — see [LICENSE](LICENSE).
