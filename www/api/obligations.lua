local util = require('_util')
local G    = require('grosznik')

local u = util.require_auth(); if not u then return end
local method = httpd.method()
local id     = util.id()
local sub    = util.param('sub')    -- 'instances'
local action = util.param('action') -- 'pay'

httpd.header('Content-Type', 'application/json; charset=utf-8')

-- /api/obligations.lua?sub=instances
if sub == 'instances' then
    if method == 'GET' then
        local year  = tonumber(util.param('year'))  or tonumber(os.date('%Y'))
        local month = tonumber(util.param('month')) or tonumber(os.date('%m'))
        local oid   = tonumber(util.param('obligation_id'))
        local sql   = 'SELECT oi.*, o.name, o.currency, o.frequency '..
                      'FROM obligation_instances oi '..
                      'JOIN obligations o ON o.id=oi.obligation_id '..
                      'WHERE oi.user_id=? AND oi.period_year=? AND oi.period_month=?'
        local args  = {u.id, year, month}
        if oid then sql = sql..' AND oi.obligation_id=?'; args[#args+1] = oid end
        sql = sql..' ORDER BY oi.due_date'
        util.ok(G.query(sql, table.unpack(args)))

    elseif method == 'POST' and action == 'pay' then
        if not id then return util.err(400, 'Brak id instancji') end
        local b = util.body()
        G.exec('UPDATE obligation_instances SET status="paid", paid_at=? WHERE id=? AND user_id=?',
               G.now(), id, u.id)
        if b.create_transaction and b.account_id then
            local inst = G.query(
                'SELECT oi.*, o.name, o.currency, o.category_id '..
                'FROM obligation_instances oi '..
                'JOIN obligations o ON o.id=oi.obligation_id WHERE oi.id=?', id)
            if #inst > 0 then
                local i = inst[1]
                local res = G.exec(
                    'INSERT INTO transactions(user_id,account_id,category_id,'..
                    'type,amount,currency,date,description) VALUES(?,?,?,?,?,?,?,?)',
                    u.id, tonumber(b.account_id), i.category_id or 21,
                    'expense', i.amount, i.currency, G.now(),
                    'Zobowiazanie: '..(i.name or ''))
                if res then
                    G.exec('UPDATE obligation_instances SET transaction_id=? WHERE id=?',
                           res.last_id, id)
                    G.exec('UPDATE accounts SET balance=balance-? WHERE id=? AND user_id=?',
                           i.amount, tonumber(b.account_id), u.id)
                end
            end
        end
        util.ok({ok = true})
    else
        util.err(405, 'Metoda niedozwolona')
    end
    return
end

-- Obligation templates CRUD
if method == 'GET' then
    if id then
        local rows = G.query(
            'SELECT o.*, a.name as account_name, c.name as cat_name '..
            'FROM obligations o '..
            'LEFT JOIN accounts a ON a.id=o.account_id '..
            'LEFT JOIN categories c ON c.id=o.category_id '..
            'WHERE o.id=? AND o.user_id=?', id, u.id)
        if #rows == 0 then return util.err(404, 'Nie znaleziono') end
        util.ok(rows[1])
    else
        util.ok(G.query(
            'SELECT o.*, a.name as account_name, c.name as cat_name '..
            'FROM obligations o '..
            'LEFT JOIN accounts a ON a.id=o.account_id '..
            'LEFT JOIN categories c ON c.id=o.category_id '..
            'WHERE o.user_id=? AND o.is_active=1 ORDER BY o.payment_day', u.id))
    end

elseif method == 'POST' then
    local b = util.body()
    if not b.name or not b.amount or not b.account_id or not b.payment_day then
        return util.err(400, 'Brak wymaganych pol: name, amount, account_id, payment_day')
    end
    local res = G.exec(
        'INSERT INTO obligations(user_id,account_id,name,amount,currency,'..
        'frequency,payment_day,category_id) VALUES(?,?,?,?,?,?,?,?)',
        u.id, tonumber(b.account_id), b.name, tonumber(b.amount),
        b.currency or 'PLN', b.frequency or 'monthly',
        tonumber(b.payment_day), tonumber(b.category_id))
    if not res then return util.err(500, 'Blad zapisu') end
    util.ok({ok = true, id = res.last_id})

elseif method == 'PUT' then
    if not id then return util.err(400, 'Brak id') end
    local b = util.body()
    local sets, vals = {}, {}
    local function add(col, val)
        if val ~= nil then sets[#sets+1] = col..'=?'; vals[#vals+1] = val end
    end
    add('name',        b.name)
    add('amount',      tonumber(b.amount))
    add('currency',    b.currency)
    add('frequency',   b.frequency)
    add('payment_day', tonumber(b.payment_day))
    add('account_id',  tonumber(b.account_id))
    add('category_id', tonumber(b.category_id))
    add('is_active',   b.is_active ~= nil and (b.is_active and 1 or 0) or nil)
    if #sets == 0 then return util.err(400, 'Brak pol do aktualizacji') end
    vals[#vals+1] = id; vals[#vals+1] = u.id
    G.exec('UPDATE obligations SET '..table.concat(sets,',')..' WHERE id=? AND user_id=?',
           table.unpack(vals))
    util.ok({ok = true})

elseif method == 'DELETE' then
    if not id then return util.err(400, 'Brak id') end
    G.exec('UPDATE obligations SET is_active=0 WHERE id=? AND user_id=?', id, u.id)
    util.ok({ok = true})

else
    util.err(405, 'Metoda niedozwolona')
end
