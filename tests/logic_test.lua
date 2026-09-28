-- Local logic test for mailpush-android (runs on desktop Lua with stubs)
package.path = "./?.lua;" .. package.path

-- ---- stubs ----
local stubs = {}
local function stub(name, mod) package.loaded[name] = mod end

-- mime.unb64 (real base64 decode)
local b64d = {}
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
for i = 1, #b64chars do b64d[b64chars:sub(i, i)] = i - 1 end
stub("mime", {
    unb64 = function(data)
        data = data:gsub("[^%w%+/=]", "")
        local out, bits, acc = {}, 0, 0
        for c in data:gmatch(".") do
            if c ~= "=" then
                acc = (acc * 64 + b64d[c]) % 4294967296
                bits = bits + 6
                if bits >= 8 then
                    bits = bits - 8
                    out[#out + 1] = string.char(math.floor(acc / 2^bits) % 256)
                    acc = acc % 2^bits -- keep accumulator bounded
                end
            end
        end
        return table.concat(out)
    end,
})

local fs_state = {} -- set of existing paths
local function parent(p) return p:match("^(.*)/[^/]+$") end
local lfs_stub = {
    attributes = function(p, mode)
        if fs_state[p] then return { mode = "file", size = 0 } end
        if fs_state[p .. "/"] or fs_state[p] == "dir" or p == "/" then return { mode = "directory" } end
        return nil
    end,
    mkdir = function(p)
        if fs_state[p] then return nil, "File exists" end
        fs_state[p] = "dir"
        return true
    end,
    dir = function() return function() end end,
}
stub("libs/libkoreader-lfs", lfs_stub)

local logger = {}
for _, lvl in ipairs({ "info", "warn", "err" }) do
    logger[lvl] = function(...) print("[" .. lvl .. "]", ...) end
end
stub("logger", logger)

local real_encoding = dofile("encoding.lua")
local real_filesystem = dofile("filesystem.lua")
local attachment = dofile("attachment.lua")

local function b64enc(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local s = ""
        for j = 3, 0, -1 do
            s = s .. b64chars:sub(math.floor(n / 64^j) % 64 + 1, math.floor(n / 64^j) % 64 + 1)
        end
        out[#out + 1] = s
    end
    local s = table.concat(out)
    local pad = (3 - #data % 3) % 3
    return s:sub(1, #s - pad) .. string.rep("=", pad)
end

local function write_b64(path, data)
    -- encode with the system base64 tool (our pure-Lua encoder is unreliable)
    local src = io.open("/tmp/mp-test/raw.bin", "wb")
    src:write(data)
    src:close()
    os.execute('base64 < /tmp/mp-test/raw.bin | fold -w 76 > "' .. path .. '"')
end

-- ---- build a test email: 2 attachments, one with traversal name ----
os.execute("rm -rf /tmp/mp-test && mkdir -p /tmp/mp-test/dl")
fs_state["/tmp/mp-test/dl"] = "dir"

local book1 = ("BOOKDATA-" .. string.rep("x", 1000) .. "-END"):sub(1, 1020)
local book2 = "PDF%DATA"

write_b64("/tmp/mp-test/a.b64", book1)
write_b64("/tmp/mp-test/b.b64", book2)
local f1 = io.open("/tmp/mp-test/a.b64"):read("*a")
local f2 = io.open("/tmp/mp-test/b.b64"):read("*a")

local msg = table.concat({
    "From: me@example.com",
    "To: you+koreader@example.com",
    "Subject: books",
    'Content-Type: multipart/mixed; boundary="OUTER"',
    "",
    "--OUTER",
    "Content-Type: text/plain",
    "",
    "hello",
    "--OUTER",
    'Content-Type: application/epub+zip; name="book.epub"',
    'Content-Disposition: attachment; filename="../../evil/../../books/My Book.epub"',
    "Content-Transfer-Encoding: base64",
    "",
    f1,
    "--OUTER",
    'Content-Type: application/pdf',
    'Content-Disposition: attachment; filename="doc.pdf"',
    "Content-Transfer-Encoding: base64",
    "",
    f2,
    "--OUTER--",
    "",
}, "\r\n")

-- stream iterator over 8KB chunks
local function make_iter(s)
    local pos = 0
    return function()
        if pos >= #s then return nil end
        local chunk = s:sub(pos + 1, pos + 8192)
        pos = pos + #chunk
        return chunk
    end
end

print("== test 1: normal fetch ==")
local count, skipped = attachment.process_stream(make_iter(msg), "/tmp/mp-test/dl", nil,
    { "epub", "pdf" }, 1024 * 1024)
print("count:", count, "size_skipped:", skipped)
assert(count == 2, "expected 2 downloads, got " .. count)

local fh = io.open("/tmp/mp-test/dl/My Book.epub", "rb")
assert(fh, "My Book.epub missing (traversal name not sanitized?)")
local content = fh:read("*a")
fh:close()
assert(content == book1, "decoded content mismatch: got " .. #content .. " bytes vs " .. #book1)
assert(not lfs_stub.attributes("/tmp/evil") and not lfs_stub.attributes("/tmp/mp-test/evil"), "traversal happened!")
print("PASS: traversal sanitized, content byte-exact")

local fh2 = io.open("/tmp/mp-test/dl/doc.pdf", "rb")
assert(fh2 and fh2:read("*a") == book2, "doc.pdf wrong")
fh2:close()
print("PASS: second attachment ok")

-- ---- test 2: size limit ----
print("== test 2: size limit ==")
os.execute("rm -rf /tmp/mp-test/dl2 && mkdir -p /tmp/mp-test/dl2")
fs_state["/tmp/mp-test/dl2"] = "dir"
local count2, skipped2 = attachment.process_stream(make_iter(msg), "/tmp/mp-test/dl2", nil,
    { "epub", "pdf" }, 100) -- 100 byte cap < 1020 byte book
assert(count2 == 1 and skipped2 == true, "size limit not enforced: " .. tostring(count2) .. "," .. tostring(skipped2))
assert(not lfs_stub.attributes("/tmp/mp-test/dl2/My Book.epub"), "oversize file was kept!")
print("PASS: oversize attachment aborted and discarded")

-- ---- test 3: filename sanitization edge cases ----
print("== test 3: safe_filename ==")
local E = real_encoding.safe_filename
assert(E("../../../etc/passwd") == "passwd", E("../../../etc/passwd"))
assert(E("..\\.hidden.lua.txt") == "hidden.lua.txt")
assert(E("normal_book-1.2.epub") == "normal_book-1.2.epub")
assert(E("") == "attachment")
assert(E("a<b>c:d\"e|f?g*h.epub") == "a_b_c_d_e_f_g_h.epub")
print("PASS: safe_filename")

print("\nALL TESTS PASSED")
