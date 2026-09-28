-- encoding helpers (from emailtokoreader streaming fork, MIT; hardened)

local mime = require("mime")

local encoding = {}

function encoding.url_decode(str)
    str = str:gsub("+", " ")
    return (str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

function encoding.decode_rfc2047(str)
    return (str:gsub("=%?([^%?]+)%?([bBqQ])%?([^%?]+)%?=", function(_, enc, data)
        if enc:lower() == "q" then
            data = data:gsub("_", " ")
            data = data:gsub("=(%x%x)", function(h)
                return string.char(tonumber(h, 16))
            end)
            return data
        end
        local ok, decoded = pcall(mime.unb64, data)
        if ok and decoded then return decoded end
        return data
    end))
end

-- Sanitize an attachment filename:
--  * strip directory components (path traversal: "../", absolute paths, "\\")
--  * replace filesystem-hostile characters
--  * drop control chars / leading dots (hidden files, "..lua" tricks)
--  * cap length
function encoding.safe_filename(name)
    if not name then return "attachment" end
    name = name:gsub("\\", "/")
    name = name:gsub(".*/", "")            -- keep basename only
    name = name:gsub("[%c%z]", "")          -- control chars
    name = name:gsub('[<>:"|?*]', "_")     -- Windows-hostile too
    name = name:gsub("^%.*", "")            -- leading dots
    name = name:gsub("%s+$", "")
    if name == "" then name = "attachment" end
    if #name > 180 then
        local base, ext = name:match("^(.+)%.([^%.]+)$")
        if base and ext and #ext <= 10 then
            name = base:sub(1, 180 - #ext - 1) .. "." .. ext
        else
            name = name:sub(1, 180)
        end
    end
    return name
end

return encoding
