-- mailpush-android.koplugin
-- "Send an email -> device fetches the book over IMAP -> appears in KOReader"
--
-- Design based on:
--   * MailPush-for-Kindle (dpolarov) -- UID SEARCH / UID FETCH BODY.PEEK[] /
--     UID STORE \Seen-after-success / UIDVALIDITY protocol (Go reference impl)
--   * emailtokoreader.koplugin streaming fork (marinov752, MIT) -- streaming
--     IMAP literal parser and chunked base64-to-disk decoder, reused here
--
-- Platform: any KOReader >= 2023.x, primarily Android (Likebook K103, 8.1).

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local logger = require("logger")
local _ = require("gettext")

local imap = require("imap")
local attachment = require("attachment")

local plugin_root = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$") or ".")
local ca_bundle_path = plugin_root .. "/cacert.pem"

local DEFAULTS = {
    imap_server = "imap.gmail.com",
    imap_port = 993,
    use_ssl = true,
    -- emails per fetch run (newest first)
    max_emails = 20,
    -- per-attachment size cap in MB (decoded)
    max_attachment_mb = 30,
    -- mark processed mail as \Seen on the server
    mark_read = true,
    -- fetch automatically on KOReader start (and re-run when network comes up)
    fetch_on_start = true,
    -- require the mail to be addressed to this address (To/Cc/Delivered-To)
    allowed_email = "",
    -- saved attachments land here unless the user picks a folder
    download_path = "",
}

local plugin = WidgetContainer:extend{
    name = "mailpush_android",
    is_doc_only = false,
}

function plugin:init()
    -- Lives in the KOReader settings dir => survives plugin updates,
    -- and credentials are never hardcoded in the source tree (req: no secrets in code)
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/mailpush-android.lua")
    -- Persistent UID state: { uidvalidity = <n>, processed = { [uid] = true, ... } }
    self.state = LuaSettings:open(DataStorage:getSettingsDir() .. "/mailpush-android-state.lua")

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if self:getSetting("fetch_on_start") then
        UIManager:scheduleIn(5, function() self:checkInbox() end)
    end
end

-- ---------- settings helpers ----------

function plugin:getSetting(key)
    local v = self.settings:readSetting(key)
    if v ~= nil then return v end
    return DEFAULTS[key]
end

function plugin:setSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function plugin:getDownloadPath()
    local p = self:getSetting("download_path")
    if p and p ~= "" then return p end
    -- Fallback: KOReader data dir (always writable, incl. Android sandbox)
    return DataStorage:getDataDir() .. "/mailpush/"
end

function plugin:getAllowedExtensions()
    return self.settings:readSetting("allowed_extensions")
        or { "epub", "pdf", "mobi", "azw3", "cbz", "fb2", "djvu", "txt" }
end

-- ---------- menu ----------

function plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("mailpush_fetch", {
        category = "none",
        event = "MailPushFetch",
        title = _("MailPush: fetch new books"),
        general = true,
    })
end

function plugin:onMailPushFetch()
    self:checkInbox()
    return true
end

function plugin:addToMainMenu(menu_items)
    menu_items.mailpush_android = {
        text = _("MailPush (email to device)"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Fetch now"),
                callback = function() self:checkInbox() end,
            },
            {
                text_func = function()
                    local email = self:getSetting("email")
                    return _("Account: ") .. (email and email ~= "" and email or _("not set"))
                end,
                keep_menu_open = true,
                separator = true,
                callback = function(touchmenu_instance)
                    self:showSettingsDialog(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return _("Download folder: ") .. self:getDownloadPath()
                end,
                keep_menu_open = true,
                callback = function() self:chooseDownloadFolder() end,
            },
            {
                text = _("File types"),
                sub_item_table = self:genExtensionMenu(),
            },
            {
                text = _("Fetch on startup"),
                checked_func = function() return self:getSetting("fetch_on_start") end,
                callback = function()
                    self:setSetting("fetch_on_start", not self:getSetting("fetch_on_start"))
                end,
            },
            {
                text = _("Mark processed mail as read"),
                checked_func = function() return self:getSetting("mark_read") end,
                callback = function()
                    self:setSetting("mark_read", not self:getSetting("mark_read"))
                end,
            },
            {
                text = _("Reset processed-mail memory"),
                callback = function()
                    self.state:saveSetting("uids", nil)
                    self.state:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Processed-UID memory cleared. Already-downloaded mail will be re-checked (files are kept, duplicates get a number suffix)."),
                        timeout = 4,
                    })
                end,
            },
        },
    }
end

function plugin:genExtensionMenu()
    local items, seen = {}, {}
    local function add(ext)
        ext = ext:lower():match("^%.?(.+)$")
        if ext and not seen[ext] then
            seen[ext] = true
            local current = self:getAllowedExtensions()
            local enabled = false
            for _, e in ipairs(current) do
                if e:lower() == ext then enabled = true break end
            end
            table.insert(items, {
                text = "." .. ext,
                keep_menu_open = true,
                checked_func = function()
                    for _, e in ipairs(self:getAllowedExtensions()) do
                        if e:lower() == ext then return true end
                    end
                    return false
                end,
                callback = function()
                    local updated, was = {}, false
                    for _, e in ipairs(self:getAllowedExtensions()) do
                        if e:lower() == ext then was = true
                        else table.insert(updated, e) end
                    end
                    if not was then table.insert(updated, ext) end
                    self:setSetting("allowed_extensions", updated)
                end,
            })
        end
    end
    for _, e in ipairs({ "epub", "pdf", "mobi", "azw3", "azw", "cbz", "fb2", "djvu", "doc", "docx", "rtf", "txt", "html", "prc", "pdb" }) do
        add(e)
    end
    for _, e in ipairs(self:getAllowedExtensions()) do add(e) end
    return items
end

function plugin:chooseDownloadFolder()
    local DownloadMgr = require("ui/downloadmgr")
    local start_path = self:getDownloadPath()
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(start_path, "mode") then start_path = nil end
    DownloadMgr:new{
        title = _("Choose download folder"),
        onConfirm = function(path)
            self:setSetting("download_path", path)
            UIManager:show(InfoMessage:new{
                text = _("Download folder set to:\n") .. path,
                timeout = 3,
            })
        end,
    }:chooseDir(start_path)
end

function plugin:showSettingsDialog(touchmenu_instance)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    local function show_error(text)
        UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
    end
    local function save()
        local fields = dialog:getFields()
        local trim = function(s) return (s or ""):match("^%s*(.-)%s*$") end
        local email = trim(fields[1])
        local password = fields[2] or ""
        local server = trim(fields[3])
        local port = tonumber(trim(fields[4]))
        local allowed = trim(fields[5])

        if email == "" then return show_error(_("Email must not be empty.")) end
        if password == "" then return show_error(_("Password must not be empty.")) end
        if server == "" then return show_error(_("IMAP server must not be empty.")) end
        if not port or port < 1 or port > 65535 then
            return show_error(_("Port must be a number 1-65535."))
        end

        self:setSetting("email", email)
        self:setSetting("password", password)
        self:setSetting("imap_server", server)
        self:setSetting("imap_port", port)
        self:setSetting("use_ssl", port ~= 143)
        self:setSetting("allowed_email", allowed)

        UIManager:close(dialog)
        if touchmenu_instance then touchmenu_instance:updateItems() end
        UIManager:show(InfoMessage:new{ text = _("Settings saved."), timeout = 2 })
    end

    dialog = MultiInputDialog:new{
        title = _("MailPush settings"),
        fields = {
            { description = _("Email account"), text = self:getSetting("email") or "",
              hint = "you@gmail.com" },
            { description = _("Password / app password"), text = self:getSetting("password") or "",
              text_type = "password" },
            { description = _("IMAP server"), text = self:getSetting("imap_server"),
              hint = "imap.gmail.com" },
            { description = _("IMAP port (993 = TLS)"), text = tostring(self:getSetting("imap_port")),
              input_type = "number", hint = "993" },
            { description = _("Only accept mail addressed to (optional)"),
              text = self:getSetting("allowed_email") or "",
              hint = "you+koreader@gmail.com" },
        },
        buttons = {
            { { text = _("Cancel"), id = "close",
                callback = function() UIManager:close(dialog) end },
              { text = _("Save"), is_enter_default = true, callback = save } },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------- fetch ----------

function plugin:checkInbox()
    local email = self:getSetting("email")
    local password = self:getSetting("password")
    if not email or email == "" or not password or password == "" then
        UIManager:show(InfoMessage:new{
            text = _("MailPush is not configured.\nTools > MailPush > Account"),
            timeout = 4,
        })
        return
    end

    -- If offline: ask NetworkMgr to turn on WiFi / re-run us when online.
    -- This is the reliable "fetch when connected" mechanism on Android --
    -- no fake background polling, we simply run whenever we are online.
    if NetworkMgr:willRerunWhenOnline(function() self:checkInbox() end) then
        return
    end

    UIManager:show(InfoMessage:new{ text = _("MailPush: checking inbox..."), timeout = 2 })

    UIManager:scheduleIn(0.5, function()
        local ok, result = pcall(function() return self:runFetch() end)
        if not ok then
            logger.warn("MailPush fetch failed:", result)
            UIManager:show(InfoMessage:new{
                text = _("MailPush error: ") .. tostring(result), timeout = 6 })
            return
        end
        if result.downloaded > 0 then
            local msg = _("MailPush: downloaded ") .. result.downloaded .. _(" file(s)")
            if result.skipped_size > 0 then
                msg = msg .. "\n" .. result.skipped_size .. _(" skipped (too large)")
            end
            UIManager:show(InfoMessage:new{ text = msg, timeout = 6 })
            -- refresh file manager if open
            pcall(function()
                local FileManager = require("apps/filemanager/filemanager")
                if FileManager.instance then FileManager.instance:onRefresh() end
            end)
        elseif result.checked > 0 then
            UIManager:show(InfoMessage:new{ text = _("MailPush: no new books."), timeout = 3 })
        end
        -- silent when nothing was checked (offline error already surfaced)
    end)
end

function plugin:runFetch()
    local cfg = {
        imap_server = self:getSetting("imap_server"),
        imap_port = self:getSetting("imap_port"),
        use_ssl = self:getSetting("use_ssl"),
        email = self:getSetting("email"),
        password = self:getSetting("password"),
        ca_bundle_path = ca_bundle_path,
    }

    local conn, err = imap.connect(cfg)
    if not conn then error(_("Connection failed: ") .. tostring(err)) end

    local result = { checked = 0, downloaded = 0, skipped_size = 0 }
    local success, run_err = pcall(function()
        local ok = imap.login(conn, cfg.email, cfg.password)
        if not ok then error(_("Login failed")) end
        -- required by NetEase/163, harmless elsewhere
        imap.sendID(conn)

        local uidvalidity = imap.selectInbox(conn)
        logger.info("MailPush UIDVALIDITY:", uidvalidity)

        -- UID state handling (MailPush protocol):
        -- UIDVALIDITY change => UIDs may have been reassigned => forget old state.
        local saved_uv = self.state:readSetting("uidvalidity")
        if saved_uv ~= uidvalidity then
            self.state:saveSetting("uids", {})
            self.state:saveSetting("uidvalidity", uidvalidity)
            self.state:flush()
        end
        local processed = self.state:readSetting("uids") or {}

        local uids = imap.uidSearchUnseen(conn)
        -- newest first, limited
        local max_emails = tonumber(self:getSetting("max_emails")) or 20
        local ordered = {}
        for i = #uids, math.max(1, #uids - max_emails + 1), -1 do
            table.insert(ordered, uids[i])
        end

        local mark_read = self:getSetting("mark_read")
        local max_bytes = (tonumber(self:getSetting("max_attachment_mb")) or 30) * 1024 * 1024
        local allowed_email = self:getSetting("allowed_email") or ""
        local exts = self:getAllowedExtensions()
        local download_path = self:getDownloadPath()

        for _, uid in ipairs(ordered) do
            result.checked = result.checked + 1
            if processed[tostring(uid)] then
                logger.info("MailPush: uid", uid, "already processed, skipping")
            else
                local downloaded, size_skipped = self:processMessage(
                    conn, uid, download_path, exts, max_bytes, allowed_email)
                result.downloaded = result.downloaded + downloaded
                if size_skipped then result.skipped_size = result.skipped_size + 1 end

                -- Record as processed only after the full message streamed
                -- successfully (crash mid-stream => not marked => retried later)
                if downloaded > 0 or size_skipped then
                    if mark_read then imap.storeSeen(conn, uid) end
                    processed[tostring(uid)] = true
                    self.state:saveSetting("uids", processed)
                    self.state:flush()
                end
            end
        end
    end)

    pcall(function() imap.logout(conn) end)
    if not success then error(run_err) end
    return result
end

-- Fetch one message (streaming), filter by recipient, save attachments.
-- Returns: downloaded_count, size_skipped
function plugin:processMessage(conn, uid, download_path, exts, max_bytes, allowed_email)
    -- 1) cheap header-only fetch for the recipient filter
    if allowed_email ~= "" then
        local headers = imap.fetchHeaders(conn, uid)
        if headers and not self:recipientMatches(headers, allowed_email) then
            logger.info("MailPush: uid", uid, "filtered out by recipient")
            return 0, false
        end
    end

    -- 2) full body, streamed
    local stream_iter, ferr = imap.fetchBodyStream(conn, uid)
    if not stream_iter then error(_("Fetch failed: ") .. tostring(ferr)) end

    local tick_cb = function() UIManager:forceRePaint() end
    local ok, downloaded, size_skipped = pcall(
        attachment.process_stream, stream_iter, download_path, tick_cb, exts, max_bytes)
    if not ok then
        -- rethrow parser errors but distinguish IO/limit issues
        error(downloaded)
    end
    return downloaded or 0, size_skipped or false
end

function plugin:recipientMatches(headers, allowed)
    local filter = allowed:lower()
    for hdr in headers:gmatch("[Tt]o:%s*([^\r\n]+)") do
        if hdr:lower():find(filter, 1, true) then return true end
    end
    for hdr in headers:gmatch("[Cc][Cc]:%s*([^\r\n]+)") do
        if hdr:lower():find(filter, 1, true) then return true end
    end
    for hdr in headers:gmatch("[Dd]elivered%-[Tt]o:%s*([^\r\n]+)") do
        if hdr:lower():find(filter, 1, true) then return true end
    end
    return false
end

return plugin
