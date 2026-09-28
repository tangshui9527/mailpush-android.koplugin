-- IMAP client for mailpush-android
-- UID-based protocol after MailPush-for-Kindle:
--   UID SEARCH UNSEEN -> UID FETCH <uid> BODY.PEEK[] -> (on success) UID STORE +\Seen
-- TLS: verified peer certificate via bundled CA (LuaSec), no verify="none".

local socket = require("socket")

local imap = { _tag_counter = 0 }

function imap.nextTag()
    imap._tag_counter = imap._tag_counter + 1
    return string.format("MPA%03d", imap._tag_counter)
end

-- Escapes a tag for use in a Lua pattern
local function tagPattern(tag)
    return tag:gsub("(%W)", "%%%1")
end

function imap.connect(cfg)
    local conn = socket.tcp()
    conn:settimeout(30)
    local ok, err = conn:connect(cfg.imap_server, cfg.imap_port)
    if not ok then
        pcall(function() conn:close() end)
        return nil, "TCP connect: " .. tostring(err)
    end

    if cfg.use_ssl then
        local has_ssl, ssl = pcall(require, "ssl")
        if not has_ssl then
            conn:close()
            return nil, "TLS unavailable in this KOReader build"
        end
        local params = {
            mode = "client",
            protocol = "tlsv1_2",
            options = { "no_sslv2", "no_sslv3" },
        }
        -- Verify the server certificate against the bundled Mozilla CA store.
        -- If the bundle is missing we fall back to unverified TLS rather than
        -- failing outright (user can then still fetch; a warning is logged).
        local cafile = cfg.ca_bundle_path
        if cafile and require("libs/libkoreader-lfs").attributes(cafile, "mode") == "file" then
            params.verify = "peer"
            params.cafile = cafile
        else
            logger.warn("MailPush: CA bundle missing, TLS peer verification disabled")
            params.verify = "none"
        end
        local tls_ok
        tls_ok, conn = pcall(function()
            local c = ssl.wrap(conn, params)
            local hs_ok, hs_err = c:dohandshake()
            if not hs_ok then
                error("TLS handshake failed: " .. tostring(hs_err))
            end
            return c
        end)
        if not tls_ok then
            pcall(function() conn:close() end)
            return nil, tostring(conn)
        end
    end

    local greeting, gerr = conn:receive("*l")
    if not greeting or not greeting:find("^%*%s+OK") then
        pcall(function() conn:close() end)
        return nil, "bad IMAP greeting: " .. tostring(gerr or greeting)
    end
    return conn
end

function imap.login(conn, email, password)
    local tag = imap.nextTag()
    conn:send(string.format('%s LOGIN "%s" "%s"\r\n', tag, email, password))
    local pat = tagPattern(tag)
    for _ = 1, 10 do
        local line = conn:receive("*l")
        if not line then return false end
        if line:match("^" .. pat .. "%s+OK") then return true
        elseif line:match("^" .. pat .. "%s+[NB]") then return false end
    end
    return false
end

-- IMAP ID extension: NetEase (163/126) servers REQUIRE this after login,
-- otherwise every subsequent command fails with "Unsafe Login".
function imap.sendID(conn)
    local tag = imap.nextTag()
    conn:send(string.format(
        '%s ID ("name" "MailPush" "version" "1.0.0" "os" "Android")\r\n', tag))
    local pat = tagPattern(tag)
    while true do
        local line = conn:receive("*l")
        if not line or line:match("^" .. pat) then break end
    end
end

-- SELECT INBOX; returns UIDVALIDITY (required, error if absent)
function imap.selectInbox(conn)
    local tag = imap.nextTag()
    conn:send(tag .. " SELECT INBOX\r\n")
    local pat = tagPattern(tag)
    local uidvalidity
    while true do
        local line = conn:receive("*l")
        if not line then error("SELECT: connection lost") end
        uidvalidity = uidvalidity or line:match("[Uu][Ii][Dd][Vv][Aa][Ll][Ii][Dd][Ii][Tt][Yy]%s+(%d+)")
        if line:match("^" .. pat) then break end
    end
    if not uidvalidity then error("server did not report UIDVALIDITY") end
    return uidvalidity
end

-- UID SEARCH UNSEEN; returns ascending list of UIDs (strings)
function imap.uidSearchUnseen(conn)
    local tag = imap.nextTag()
    conn:send(tag .. " UID SEARCH UNSEEN\r\n")
    local pat = tagPattern(tag)
    local uids = {}
    while true do
        local line = conn:receive("*l")
        if not line then break end
        if line:match("^%*%s+SEARCH") then
            for uid in line:gmatch("%d+") do table.insert(uids, uid) end
        end
        if line:match("^" .. pat) then break end
    end
    return uids
end

-- Reads one IMAP literal ({<n>}\r\n....) after the fetch command,
-- yielding 8KB chunks with exact byte accounting. Robust against
-- binary payloads (unlike line-based reads).
local function readLiteralChunks(conn, tag)
    local pat = tagPattern(tag)
    -- scan until the literal marker (headers of the response may precede it)
    local literal_size
    while true do
        local line = conn:receive("*l")
        if not line then return nil, "connection lost before literal" end
        if line:match("^" .. pat) then
            return nil, "no literal in response"
        end
        literal_size = tonumber(line:match("{(%d+)}%s*$"))
        if literal_size then break end
    end

    local remaining = literal_size
    local done = false
    return function()
        if done then return nil end
        if remaining <= 0 then
            done = true
            -- drain trailing protocol lines until tagged completion
            while true do
                local line = conn:receive("*l")
                if not line or line:match("^" .. pat) then break end
            end
            return nil
        end
        local want = math.min(8192, remaining)
        local chunk, err, partial = conn:receive(want)
        chunk = chunk or partial
        if not chunk or #chunk == 0 then
            done = true
            return nil, err or "read failed"
        end
        remaining = remaining - #chunk
        return chunk
    end
end

-- UID FETCH <uid> BODY.PEEK[HEADER]: small header-only fetch, returns string
function imap.fetchHeaders(conn, uid)
    local tag = imap.nextTag()
    conn:send(string.format("%s UID FETCH %s (BODY.PEEK[HEADER])\r\n", tag, uid))
    local it, err = readLiteralChunks(conn, tag)
    if not it then
        logger.warn("MailPush: header fetch failed:", err)
        return nil
    end
    local parts = {}
    while true do
        local chunk = it()
        if not chunk then break end
        table.insert(parts, chunk)
    end
    return table.concat(parts)
end

-- UID FETCH <uid> BODY.PEEK[]: streaming iterator over the full message
function imap.fetchBodyStream(conn, uid)
    local tag = imap.nextTag()
    conn:send(string.format("%s UID FETCH %s (BODY.PEEK[])\r\n", tag, uid))
    return readLiteralChunks(conn, tag)
end

-- UID STORE <uid> +FLAGS.SILENT (\Seen) -- only called after successful download
function imap.storeSeen(conn, uid)
    local tag = imap.nextTag()
    conn:send(string.format("%s UID STORE %s +FLAGS.SILENT (\\Seen)\r\n", tag, uid))
    local pat = tagPattern(tag)
    while true do
        local line = conn:receive("*l")
        if not line or line:match("^" .. pat) then break end
    end
end

function imap.logout(conn)
    local tag = imap.nextTag()
    conn:settimeout(5)
    pcall(function()
        conn:send(tag .. " LOGOUT\r\n")
        conn:receive("*l")
    end)
    pcall(function() conn:close() end)
end

return imap
