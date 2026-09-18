-- _util.lua: shared utilities for all API endpoints
local json = require('_json')
local G    = require('grosznik')
local M    = {}

-- Set JSON content-type header
local function json_ct()
    httpd.header('Content-Type', 'application/json; charset=utf-8')
end

-- Send JSON 200
function M.ok(data)
    json_ct()
    httpd.write(json.encode(data))
end

-- Send JSON error
function M.err(code, msg)
    httpd.status(code)
    json_ct()
    httpd.write(json.encode({error = msg}))
end

-- Parse JSON request body
function M.body()
    local raw = httpd.body()
    if not raw or raw == '' then return {} end
    return json.decode(raw) or {}
end

-- Verify JWT from httpOnly cookie → returns {id, username} or nil
function M.auth()
    local tok = httpd.get_cookie('grosznik_jwt')
    if not tok or tok == '' then return nil end
    return G.jwt_verify(tok)
end

-- Require auth — send 401 and return nil on failure
function M.require_auth()
    local u = M.auth()
    if not u then M.err(401, 'Nieautoryzowany'); return nil end
    return u
end

-- Query string parameter
function M.param(name)
    local q = httpd.query() or ''
    for pair in (q .. '&'):gmatch('([^&]+)&') do
        local k, v = pair:match('^([^=]+)=(.*)$')
        if k == name then
            -- URL decode: replace + with space, then %XX
            v = v:gsub('+', ' '):gsub('%%(%x%x)', function(h)
                return string.char(tonumber(h,16))
            end)
            return v
        end
    end
    return nil
end

-- GET numeric id from query string
function M.id()
    return tonumber(M.param('id'))
end

return M
