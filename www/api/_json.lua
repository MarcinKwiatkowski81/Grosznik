-- _json.lua: minimal JSON encoder/decoder
local M = {}

local function esc(s)
    return s:gsub('\\', '\\\\'):gsub('"', '\\"')
            :gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')
end

function M.encode(v)
    local t = type(v)
    if v == nil         then return 'null'
    elseif t == 'boolean' then return v and 'true' or 'false'
    elseif t == 'number'  then
        if v ~= v then return 'null' end  -- NaN
        if math.type and math.type(v) == 'integer' then return tostring(v) end
        return string.format('%.10g', v)
    elseif t == 'string'  then return '"' .. esc(v) .. '"'
    elseif t == 'table'   then
        -- array check: all keys are consecutive integers starting at 1
        local n = #v
        local isArray = (n > 0)
        if isArray then
            for k in pairs(v) do
                if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then
                    isArray = false; break
                end
            end
        end
        if isArray then
            local parts = {}
            for i = 1, n do parts[i] = M.encode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        else
            local parts = {}
            for k, val in pairs(v) do
                if type(k) == 'string' or type(k) == 'number' then
                    parts[#parts+1] = '"' .. esc(tostring(k)) .. '":' .. M.encode(val)
                end
            end
            return '{' .. table.concat(parts, ',') .. '}'
        end
    end
    return 'null'
end

-- Decoder
local function skip(s, i)
    while i <= #s and s:sub(i,i):match('%s') do i = i+1 end
    return i
end

local decode_value  -- forward declare

local function decode_string(s, i)
    i = i + 1  -- skip opening "
    local out = {}
    while i <= #s do
        local c = s:sub(i,i)
        if c == '"' then return table.concat(out), i+1 end
        if c == '\\' then
            i = i+1; c = s:sub(i,i)
            local esc_map = {['"']='"',['\\']='\\',['/']='\/',
                             ['n']='\n',['r']='\r',['t']='\t',['b']='\b',['f']='\f'}
            out[#out+1] = esc_map[c] or c
        else
            out[#out+1] = c
        end
        i = i+1
    end
    error('unterminated string')
end

local function decode_number(s, i)
    local j = i
    if s:sub(j,j) == '-' then j=j+1 end
    while j <= #s and s:sub(j,j):match('[0-9%.eE%+%-]') do j=j+1 end
    return tonumber(s:sub(i,j-1)), j
end

local function decode_array(s, i)
    i = i+1  -- skip [
    local arr = {}
    i = skip(s,i)
    if s:sub(i,i) == ']' then return arr, i+1 end
    while true do
        local v; v, i = decode_value(s, i)
        arr[#arr+1] = v
        i = skip(s,i)
        local c = s:sub(i,i)
        if c == ']' then return arr, i+1 end
        if c ~= ',' then error('expected , or ]') end
        i = skip(s, i+1)
    end
end

local function decode_object(s, i)
    i = i+1  -- skip {
    local obj = {}
    i = skip(s,i)
    if s:sub(i,i) == '}' then return obj, i+1 end
    while true do
        local k; k, i = decode_string(s, skip(s,i))
        i = skip(s,i)
        if s:sub(i,i) ~= ':' then error('expected :') end
        i = skip(s, i+1)
        local v; v, i = decode_value(s, i)
        obj[k] = v
        i = skip(s,i)
        local c = s:sub(i,i)
        if c == '}' then return obj, i+1 end
        if c ~= ',' then error('expected , or }') end
        i = skip(s, i+1)
    end
end

decode_value = function(s, i)
    i = skip(s,i)
    local c = s:sub(i,i)
    if c == '"' then return decode_string(s,i)
    elseif c == '[' then return decode_array(s,i)
    elseif c == '{' then return decode_object(s,i)
    elseif c == 't' then return true,  i+4
    elseif c == 'f' then return false, i+5
    elseif c == 'n' then return nil,   i+4
    else                 return decode_number(s,i)
    end
end

function M.decode(s)
    if not s or s == '' then return nil end
    local ok, result = pcall(function()
        local v, _ = decode_value(s, 1)
        return v
    end)
    if ok then return result end
    return nil
end

return M
