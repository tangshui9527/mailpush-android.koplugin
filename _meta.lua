-- metadata for KOReader plugin loader
local _ = require("gettext")

return {
    name = "mailpush-android",
    fullname = _("MailPush (email to device)"),
    description = _([[Fetch ebook attachments from an IMAP mailbox directly into your library. Send an email to yourself, the device downloads it when you are online.]]),
}
