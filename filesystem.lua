-- filesystem helpers (from emailtokoreader streaming fork, MIT)

local lfs = require("libs/libkoreader-lfs")

local filesystem = {}

function filesystem.normalize_path(path)
    if not path:match("/$") then path = path .. "/" end
    return path
end

function filesystem.mkdir_p(path)
    local current = ""
    for part in path:gmatch("[^/]+") do
        current = current .. "/" .. part
        if not lfs.attributes(current) then
            local ok, err = lfs.mkdir(current)
            if not ok and err ~= "File exists" then
                return false, err
            end
        end
    end
    return true
end

function filesystem.unique_filepath(path)
    local base, ext = path:match("^(.-)(%.[^%.]+)$")
    if not base then return path end
    local candidate = path
    local counter = 1
    while lfs.attributes(candidate) do
        candidate = string.format("%s (%d)%s", base, counter, ext)
        counter = counter + 1
    end
    return candidate
end

return filesystem
