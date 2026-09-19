local json = require('_json')
local util = require('_util')
local G    = require('grosznik')

local method = httpd.method()
local action = util.param('action') or ''

httpd.header('Content-Type', 'application/json; charset=utf-8')

-- POST /api/auth.lua?action=login
if method == 'POST' and action == 'login' then
    local b    = util.body()
    local uname = tostring(b.username or '')
    local pwd   = tostring(b.password or '')
    if uname == '' or pwd == '' then
        return util.err(400, 'Brak nazwy uzytkownika lub hasla')
    end
    local rows = G.query(
        'SELECT id, username, password_hash FROM users WHERE username = ?', uname)
    if #rows == 0 then
        return util.err(401, 'Nieprawidlowe dane logowania')
    end
    local user = rows[1]
    if not G.check_password(pwd, user.password_hash) then
        return util.err(401, 'Nieprawidlowe dane logowania')
    end
    local token = G.jwt_sign(user.id, user.username, 86400) -- 24h
    httpd.set_cookie('grosznik_jwt', token, {
        httpOnly = true,
        path     = '/',
        maxAge   = 86400,
        sameSite = 'Strict'
    })
    util.ok({ok = true, username = user.username, id = user.id})

-- POST /api/auth.lua?action=logout
elseif method == 'POST' and action == 'logout' then
    httpd.set_cookie('grosznik_jwt', '', {
        httpOnly = true, path = '/', maxAge = 0, sameSite = 'Strict'
    })
    util.ok({ok = true})

-- POST /api/auth.lua?action=register  (first-time setup)
elseif method == 'POST' and action == 'register' then
    -- Only allow if no users exist yet
    local count = G.query('SELECT COUNT(*) as n FROM users')
    if count[1] and count[1].n > 0 then
        return util.err(403, 'Rejestracja zamknieta')
    end
    local b     = util.body()
    local uname = tostring(b.username or '')
    local pwd   = tostring(b.password or '')
    local email = tostring(b.email or '')
    if uname == '' or pwd == '' or email == '' then
        return util.err(400, 'Wypelnij wszystkie pola')
    end
    if #pwd < 8 then
        return util.err(400, 'Haslo musi miec minimum 8 znakow')
    end
    local hash = G.hash_password(pwd)
    local res  = G.exec(
        'INSERT INTO users(username, email, password_hash) VALUES(?,?,?)',
        uname, email, hash)
    if not res then
        return util.err(500, 'Blad zapisu')
    end
    local token = G.jwt_sign(res.last_id, uname, 86400)
    httpd.set_cookie('grosznik_jwt', token, {
        httpOnly = true, path = '/', maxAge = 86400, sameSite = 'Strict'
    })
    util.ok({ok = true, id = res.last_id, username = uname})

-- GET /api/auth.lua?action=me
elseif method == 'GET' and action == 'me' then
    local u = util.auth()
    if not u then return util.err(401, 'Nieautoryzowany') end
    local rows = G.query(
        'SELECT id, username, email, telegram_chat_id, default_currency, '..
        'balance_alert_threshold FROM users WHERE id=?', u.id)
    if #rows == 0 then return util.err(404, 'Nie znaleziono') end
    util.ok(rows[1])

-- GET /api/auth.lua?action=setup_status
elseif method == 'GET' and action == 'setup_status' then
    local count = G.query('SELECT COUNT(*) as n FROM users')
    util.ok({needs_setup = (not count[1] or count[1].n == 0)})

-- PUT /api/auth.lua?action=profile
elseif method == 'PUT' and action == 'profile' then
    local u = util.require_auth()
    if not u then return end
    local b = util.body()
    if b.telegram_chat_id then
        G.exec('UPDATE users SET telegram_chat_id=? WHERE id=?',
               tostring(b.telegram_chat_id), u.id)
    end
    if b.balance_alert_threshold then
        G.exec('UPDATE users SET balance_alert_threshold=? WHERE id=?',
               tonumber(b.balance_alert_threshold), u.id)
    end
    if b.default_currency then
        G.exec('UPDATE users SET default_currency=? WHERE id=?',
               tostring(b.default_currency), u.id)
    end
    if b.new_password and b.new_password ~= '' then
        if #tostring(b.new_password) < 8 then
            return util.err(400, 'Haslo musi miec minimum 8 znakow')
        end
        G.exec('UPDATE users SET password_hash=? WHERE id=?',
               G.hash_password(tostring(b.new_password)), u.id)
    end
    util.ok({ok = true})

else
    util.err(405, 'Nieprawidlowa metoda lub akcja')
end
