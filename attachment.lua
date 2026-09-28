-- Streaming MIME attachment processor for mailpush-android
-- Adapted from emailtokoreader.koplugin streaming fork (marinov752, MIT).
-- Changes: per-attachment size cap (decoded), returns (count, size_skipped).

local mime = require("mime")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local encoding = require("encoding")
local filesystem = require("filesystem")

local attachment = {}

local function percent_decode(str)
    return (str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Reads a MIME header parameter, including RFC 2231 forms
local function header_param(block, param)
    local prefix = "[;%s]" .. param
    local value = block:match(prefix .. '%s*=%s*"([^"]*)"')
        or block:match(prefix .. '%s*=%s*([^%s;"]+)')
    if value then return value end
    value = block:match(prefix .. "%*%s*=%s*\"?[^'\"%s]*'[^']*'([^%s;\"]+)")
    if value then return percent_decode(value) end
    local parts, i = {}, 0
    while true do
        local section = prefix .. "%*" .. i
        local encoded = block:match(section .. '%*%s*=%s*"?([^%s;"]+)')
        if encoded then
            if i == 0 then encoded = encoded:gsub("^[^']*'[^']*'", "") end
            table.insert(parts, percent_decode(encoded))
        else
            local plain = block:match(section .. '%s*=%s*"([^%s;"]*)"')
                or block:match(section .. '%s*=%s*([^%s;"]+)')
            if not plain then break end
            table.insert(parts, plain)
        end
        i = i + 1
    end
    if #parts > 0 then return table.concat(parts) end
end

local function decode_quoted_printable(line)
    return (line:gsub("=(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- stream_iter: 8KB chunks of the raw message (exact literal accounting)
-- tick_cb: e-ink repaint hook
-- allowed_extensions: {"epub", "pdf", ...}
-- max_bytes: decoded size cap per attachment
-- Returns: downloaded_count, size_skipped(bool)
function attachment.process_stream(stream_iter, download_path, tick_cb, allowed_extensions, max_bytes)
    local allowed_set = {}
    for _, ext in ipairs(allowed_extensions or {}) do
        local key = tostring(ext):lower():match("^%.?(.+)$")
        if key then allowed_set[key] = true end
    end
    max_bytes = max_bytes or (30 * 1024 * 1024)

    local state = "SEARCHING"
    local boundaries = {}

    local header_lines = {}
    local current_filename = nil
    local is_quoted_printable = false
    local pending_newline = false
    local bytes_written = 0
    local current_too_big = false

    local chunks, chunks_len = {}, 0
    local b64_leftover = ""
    local out_file, tmp_path, final_path = nil, nil, nil

    local downloaded_count = 0
    local size_skipped = false
    local lines_processed = 0

    local function abort_current()
        if out_file then
            pcall(function() out_file:close() end)
            out_file = nil
        end
        if tmp_path then pcall(function() os.remove(tmp_path) end) end
        tmp_path, final_path = nil, nil
        current_filename = nil
        current_too_big = false
        bytes_written = 0
        state = "SEARCHING"
    end

    local function finalize_attachment()
        if out_file then
            if not current_too_big and (chunks_len > 0 or #b64_leftover > 0) then
                local final_string = b64_leftover .. table.concat(chunks)
                local pad = #final_string % 4
                if pad > 0 then
                    final_string = final_string .. string.rep("=", 4 - pad)
                end
                local decode_ok, decoded = pcall(mime.unb64, final_string)
                if decode_ok and decoded and #decoded > 0 then
                    if bytes_written + #decoded > max_bytes then
                        current_too_big = true
                    else
                        out_file:write(decoded)
                    end
                end
            end
            out_file:close()
            out_file = nil
            if current_too_big then
                if tmp_path then os.remove(tmp_path) end
                size_skipped = true
                logger.warn("MailPush: attachment over limit, discarded:", current_filename)
            elseif tmp_path and final_path then
                local ok = os.rename(tmp_path, final_path)
                if ok then
                    downloaded_count = downloaded_count + 1
                else
                    os.remove(tmp_path)
                end
            end
        end
        header_lines = {}
        current_filename = nil
        is_quoted_printable = false
        pending_newline = false
        current_too_big = false
        bytes_written = 0
        chunks, chunks_len = {}, 0
        b64_leftover = ""
        tmp_path, final_path = nil, nil
    end

    local function process_line(line)
        lines_processed = lines_processed + 1
        if tick_cb and lines_processed % 250 == 0 then tick_cb() end

        line = line:gsub("\r$", "")

        -- 1) collect boundary definitions wherever they appear
        local new_boundary = line:match('boundary="([^"]+)"') or line:match('boundary=([^%s;]+)')
        if new_boundary then boundaries["--" .. new_boundary] = true end

        -- 2) boundary line
        if line:sub(1, 2) == "--" and (boundaries[line] or boundaries[line:match("^(.-)%-%-$") or ""]) then
            finalize_attachment()
            state = "HEADERS"

        -- 3) headers
        elseif state == "HEADERS" then
            if line ~= "" then
                table.insert(header_lines, line)
            else
                local header_block = " " .. table.concat(header_lines, " ")
                local transfer_encoding = (header_block:lower():match("content%-transfer%-encoding:%s*([%w%-]+)") or "7bit")
                local fname = header_param(header_block, "filename") or header_param(header_block, "name")

                if fname then
                    local ok, decoded_name = pcall(encoding.decode_rfc2047, fname)
                    if ok and decoded_name then fname = decoded_name end
                end

                if fname then
                    local ext = fname:match("%.([^%.]+)$")
                    if not (ext and allowed_set[ext:lower()]) then fname = nil end
                end

                if fname then
                    current_filename = encoding.safe_filename(fname)
                    filesystem.mkdir_p(download_path)
                    final_path = filesystem.unique_filepath(download_path .. "/" .. current_filename)
                    tmp_path = final_path .. ".tmp"
                    out_file = io.open(tmp_path, "wb")
                    if not out_file then
                        logger.warn("MailPush: cannot write", tmp_path)
                        state = "SEARCHING"
                    else
                        bytes_written = 0
                        if transfer_encoding == "base64" then
                            state = "BODY_BASE64"
                        else
                            is_quoted_printable = transfer_encoding == "quoted-printable"
                            state = "BODY_TEXT"
                        end
                    end
                else
                    state = "SEARCHING"
                end
            end

        -- 4) base64 payload, streamed to disk in aligned chunks
        elseif state == "BODY_BASE64" then
            local clean = line:gsub("%s+", "")
            if clean ~= "" and clean:match("^[A-Za-z0-9+/=]+$") then
                table.insert(chunks, clean)
                chunks_len = chunks_len + #clean
                if chunks_len >= 8192 then
                    local combined = b64_leftover .. table.concat(chunks)
                    chunks, chunks_len = {}, 0
                    local safe_len = math.floor(#combined / 4) * 4
                    if safe_len > 0 then
                        local chunk_to_decode = combined:sub(1, safe_len)
                        b64_leftover = combined:sub(safe_len + 1)
                        local decode_ok, decoded = pcall(mime.unb64, chunk_to_decode)
                        if decode_ok and decoded and #decoded > 0 and out_file then
                            bytes_written = bytes_written + #decoded
                            if bytes_written > max_bytes then
                                current_too_big = true
                                abort_current()
                            else
                                out_file:write(decoded)
                            end
                        end
                    else
                        b64_leftover = combined
                    end
                end
            end

        -- 5) text / quoted-printable payload
        elseif state == "BODY_TEXT" then
            local soft_break = false
            if is_quoted_printable then
                line = line:gsub("[ \t]+$", "")
                if line:sub(-1) == "=" then
                    soft_break = true
                    line = line:sub(1, -2)
                end
                line = decode_quoted_printable(line)
            end
            bytes_written = bytes_written + #line + 1
            if bytes_written > max_bytes then
                current_too_big = true
                abort_current()
            elseif out_file then
                if pending_newline then out_file:write("\n") end
                out_file:write(line)
                pending_newline = not soft_break
            end
        end
    end

    -- 6) chunk-to-line buffer
    local leftover_text = ""
    while true do
        local chunk = stream_iter()
        if not chunk then
            if leftover_text ~= "" then process_line(leftover_text) end
            break
        end
        local text = leftover_text .. chunk
        local pos = 1
        while true do
            local s, e = text:find("\n", pos)
            if not s then
                leftover_text = text:sub(pos)
                break
            end
            process_line(text:sub(pos, s - 1))
            pos = e + 1
        end
    end

    finalize_attachment()
    return downloaded_count, size_skipped
end

return attachment
