-- settings.lua — application-level settings (Telegram bot token, etc.)
-- Only authenticated users can read/write.
-- The bot token is stored in app_settings, read at runtime by Notifier.
-- GET  /api/settings.lua               → {telegram_bot_token_set: bool}
-- GET  /api/settings.lua?key=foo       → {key, value} (sensitive keys redacted)
-- PUT  /api/settings.lua               → body: {telegram_bot_token?, ...}
-- POST /api/settings.lua?action=test_telegram → send test message to user's Chat ID

local json = require('_json')
local util = require('_util')
local G    = require('grosznik')

local method = httpd.method()
local action = util.param('action') or ''

-- All endpoints require auth
local u = util.require_auth()
if not u then return end

-- ── GET — return safe summary of settings ─────────────────────────────────────
if method == 'GET' and action == '' then
    local bot_row = G.query("SELECT value FROM app_settings WHERE key='telegram_bot_token'")
    local bot_val = (bot_row[1] and bot_row[1].value) or ''
    -- Never expose the actual token — only whether it is set and its prefix (for verification)
    local bot_set = (bot_val ~= '')
    local bot_hint = ''
    if bot_set and #bot_val > 10 then
        -- Show first 8 chars so user can verify which bot is configured
        bot_hint = bot_val:sub(1, 8) .. '...'
    end
    return util.ok({
        telegram_bot_token_set  = bot_set,
        telegram_bot_token_hint = bot_hint,
    })

-- ── PUT — save settings ────────────────────────────────────────────────────────
elseif method == 'PUT' then
    local b = util.body()
    local changed = {}

    -- telegram_bot_token: store or clear
    if b.telegram_bot_token ~= nil then
        local tok = tostring(b.telegram_bot_token)
        -- Basic format check: Telegram tokens look like "123456789:ABC..."
        -- Allow empty string to clear the token.
        if tok ~= '' and not tok:match('^%d+:') then
            return util.err(400, 'Nieprawidlowy format tokenu Telegram (oczekiwano: 123456789:ABC...)')
        end
        G.exec(
            "INSERT INTO app_settings(key, value, updated_at) VALUES('telegram_bot_token',?,strftime('%s','now'))"
            .." ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
            tok)
        changed[#changed+1] = 'telegram_bot_token'
    end

    -- notify_on_low_balance (global default, per-user overridden in users table)
    if b.notify_on_low_balance ~= nil then
        local v = b.notify_on_low_balance and '1' or '0'
        G.exec(
            "INSERT INTO app_settings(key,value,updated_at) VALUES('notify_on_low_balance',?,strftime('%s','now'))"
            .." ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
            v)
        changed[#changed+1] = 'notify_on_low_balance'
    end

    return util.ok({ok = true, changed = changed})

-- ── POST?action=test_telegram — wysyła testową wiadomość przez bota ───────────
elseif method == 'POST' and action == 'test_telegram' then
    -- Read user's Chat ID
    local user_rows = G.query('SELECT telegram_chat_id FROM users WHERE id=?', u.id)
    local chat_id = (user_rows[1] and user_rows[1].telegram_chat_id) or ''
    if chat_id == '' then
        return util.err(400, 'Brak Telegram Chat ID w profilu. Zapisz Chat ID w Ustawieniach przed testem.')
    end

    -- Read bot token from app_settings
    local bot_row = G.query("SELECT value FROM app_settings WHERE key='telegram_bot_token'")
    local bot_token = (bot_row[1] and bot_row[1].value) or ''
    if bot_token == '' then
        return util.err(400, 'Token bota nie jest skonfigurowany.')
    end

    -- Call Telegram API via os.execute + curl (no Lua HTTP client available)
    -- We write the payload to a temp file to avoid shell quoting issues.
    local msg = 'Test Grosznik: bot dziala poprawnie! Chat ID: ' .. chat_id
    local url = 'https://api.telegram.org/bot' .. bot_token .. '/sendMessage'

    -- Build curl command — use -s (silent) -o /dev/null to discard output,
    -- -w "%{http_code}" to capture the HTTP status code.
    local tmp = '/tmp/grosznik_tg_test_' .. tostring(G.now()) .. '.json'
    local payload = json.encode({chat_id = tonumber(chat_id) or chat_id, text = msg})

    -- Write payload to temp file (avoids quoting nightmares)
    local f = io.open(tmp, 'w')
    if not f then
        return util.err(500, 'Nie można zapisać pliku tymczasowego')
    end
    f:write(payload)
    f:close()

    local cmd = string.format(
        'curl -s -o /tmp/grosznik_tg_resp.json -w "%%{http_code}" '
        ..'-X POST -H "Content-Type: application/json" --data @%s %s 2>/dev/null',
        tmp, url)

    local handle = io.popen(cmd)
    local result = handle and handle:read('*a') or ''
    if handle then handle:close() end
    os.remove(tmp)

    local http_code = tonumber(result) or 0
    if http_code == 200 then
        return util.ok({ok = true, message = 'Wiadomość testowa wysłana na Chat ID ' .. chat_id})
    else
        -- Read error from response
        local resp_f = io.open('/tmp/grosznik_tg_resp.json', 'r')
        local resp_body = resp_f and resp_f:read('*a') or ''
        if resp_f then resp_f:close() end
        local tg_err = ''
        -- Extract "description" field from Telegram error JSON
        tg_err = resp_body:match('"description":"([^"]+)"') or ('HTTP ' .. http_code)
        return util.err(500, 'Błąd Telegram API: ' .. tg_err)
    end

else
    return util.err(405, 'Metoda lub akcja nieobsługiwana')
end
