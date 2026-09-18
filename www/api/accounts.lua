local util = require('_util')
local G    = require('grosznik')

local u = util.require_auth(); if not u then return end
local method = httpd.method()
local id     = util.id()

httpd.header('Content-Type', 'application/json; charset=utf-8')

if method == 'GET' then
    if id then
        -- GET single account + recent transactions
        local rows = G.query(
            'SELECT * FROM accounts WHERE id=? AND user_id=?', id, u.id)
        if #rows == 0 then return util.err(404, 'Nie znaleziono') end
        local acc = rows[1]
        local txns = G.query(
            'SELECT t.*, c.name as cat_name, c.icon as cat_icon '..
            'FROM transactions t LEFT JOIN categories c ON c.id=t.category_id '..
            'WHERE t.account_id=? ORDER BY t.date DESC LIMIT 20', id)
        acc.recent_transactions = txns
        util.ok(acc)
    else
        -- GET all accounts with computed fields
        local rows = G.query(
            'SELECT a.*, '..
            '(CASE WHEN a.type="credit_card" AND a.credit_limit IS NOT NULL '..
            '  THEN a.credit_limit - a.balance ELSE NULL END) as available_credit, '..
            '(CASE WHEN a.savings_goal IS NOT NULL AND a.savings_goal > 0 '..
            '  THEN ROUND(a.balance * 100.0 / a.savings_goal, 1) ELSE NULL END) as goal_pct '..
            'FROM accounts a WHERE a.user_id=? AND a.is_active=1 '..
            'ORDER BY a.type, a.name', u.id)
        util.ok(rows)
    end

elseif method == 'POST' then
    local b = util.body()
    if not b.name or not b.type or not b.currency then
        return util.err(400, 'Brak wymaganych pol: name, type, currency')
    end
    local res = G.exec(
        'INSERT INTO accounts(user_id,name,type,currency,balance,'..
        'interest_rate,savings_goal,savings_goal_name,'..
        'credit_limit,billing_day,payment_due_days) '..
        'VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        u.id, b.name, b.type, b.currency,
        tonumber(b.balance) or 0,
        tonumber(b.interest_rate),
        tonumber(b.savings_goal),
        b.savings_goal_name,
        tonumber(b.credit_limit),
        tonumber(b.billing_day),
        tonumber(b.payment_due_days))
    if not res then return util.err(500, 'Blad zapisu') end
    util.ok({ok = true, id = res.last_id})

elseif method == 'PUT' then
    if not id then return util.err(400, 'Brak id') end
    local b = util.body()
    -- Build dynamic SET clause
    local sets, vals = {}, {}
    local function add(col, val)
        if val ~= nil then sets[#sets+1] = col..'=?'; vals[#vals+1] = val end
    end
    add('name',              b.name)
    add('currency',          b.currency)
    add('balance',           tonumber(b.balance))
    add('interest_rate',     tonumber(b.interest_rate))
    add('savings_goal',      tonumber(b.savings_goal))
    add('savings_goal_name', b.savings_goal_name)
    add('credit_limit',      tonumber(b.credit_limit))
    add('billing_day',       tonumber(b.billing_day))
    add('payment_due_days',  tonumber(b.payment_due_days))
    if #sets == 0 then return util.err(400, 'Brak pol do aktualizacji') end
    vals[#vals+1] = id; vals[#vals+1] = u.id
    G.exec('UPDATE accounts SET '..table.concat(sets,',')..' WHERE id=? AND user_id=?',
           table.unpack(vals))
    util.ok({ok = true})

elseif method == 'DELETE' then
    if not id then return util.err(400, 'Brak id') end
    G.exec('UPDATE accounts SET is_active=0 WHERE id=? AND user_id=?', id, u.id)
    util.ok({ok = true})

else
    util.err(405, 'Metoda niedozwolona')
end
