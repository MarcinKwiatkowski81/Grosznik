local util = require('_util')
local G    = require('grosznik')

local u = util.require_auth(); if not u then return end
local method = httpd.method()
local id     = util.id()

httpd.header('Content-Type', 'application/json; charset=utf-8')

if method == 'GET' then
    if id then
        local rows = G.query(
            'SELECT t.*, c.name as cat_name, c.icon as cat_icon, '..
            '  a.name as account_name '..
            'FROM transactions t '..
            'LEFT JOIN categories c ON c.id=t.category_id '..
            'LEFT JOIN accounts a ON a.id=t.account_id '..
            'WHERE t.id=? AND t.user_id=?', id, u.id)
        if #rows == 0 then return util.err(404, 'Nie znaleziono') end
        util.ok(rows[1])
    else
        -- Filters: account_id, type, category_id, date_from, date_to, limit, offset
        local acct = tonumber(util.param('account_id'))
        local typ  = util.param('type')
        local cat  = tonumber(util.param('category_id'))
        local dfrom= tonumber(util.param('date_from')) or 0
        local dto  = tonumber(util.param('date_to'))   or 9999999999
        local lim  = tonumber(util.param('limit'))     or 50
        local off  = tonumber(util.param('offset'))    or 0
        local sql  = 'SELECT t.*, c.name as cat_name, c.icon as cat_icon, '..
                     '  a.name as account_name '..
                     'FROM transactions t '..
                     'LEFT JOIN categories c ON c.id=t.category_id '..
                     'LEFT JOIN accounts a ON a.id=t.account_id '..
                     'WHERE t.user_id=?'
        local args = {u.id}
        if acct then sql=sql..' AND t.account_id=?'; args[#args+1]=acct end
        if typ  then sql=sql..' AND t.type=?';       args[#args+1]=typ  end
        if cat  then sql=sql..' AND t.category_id=?';args[#args+1]=cat  end
        sql = sql .. ' AND t.date>=? AND t.date<=?'
        args[#args+1]=dfrom; args[#args+1]=dto
        sql = sql .. ' ORDER BY t.date DESC LIMIT ? OFFSET ?'
        args[#args+1]=lim; args[#args+1]=off
        util.ok(G.query(sql, table.unpack(args)))
    end

elseif method == 'POST' then
    local b = util.body()
    if not b.account_id or not b.type or not b.amount or not b.date then
        return util.err(400, 'Brak wymaganych pol')
    end
    local amount = math.abs(tonumber(b.amount) or 0)
    if amount == 0 then return util.err(400, 'Kwota nie moze byc 0') end

    -- Insert transaction
    local res = G.exec(
        'INSERT INTO transactions(user_id,account_id,to_account_id,category_id,'..
        'type,amount,currency,date,description,tags,is_pending) '..
        'VALUES(?,?,?,?,?,?,?,?,?,?,?)',
        u.id, tonumber(b.account_id), tonumber(b.to_account_id),
        tonumber(b.category_id),
        b.type, amount, b.currency or 'PLN',
        tonumber(b.date) or G.now(),
        b.description or '', b.tags or '',
        b.is_pending and 1 or 0)
    if not res then return util.err(500, 'Blad zapisu') end

    -- Update account balance(s)
    if not b.is_pending then
        if b.type == 'income' then
            G.exec('UPDATE accounts SET balance=balance+? WHERE id=? AND user_id=?',
                   amount, tonumber(b.account_id), u.id)
        elseif b.type == 'expense' or b.type == 'atm' then
            G.exec('UPDATE accounts SET balance=balance-? WHERE id=? AND user_id=?',
                   amount, tonumber(b.account_id), u.id)
            if b.type == 'atm' and b.to_account_id then
                -- ATM: decrease bank, increase cash wallet
                G.exec('UPDATE accounts SET balance=balance+? WHERE id=? AND user_id=?',
                       amount, tonumber(b.to_account_id), u.id)
            end
        elseif b.type == 'transfer' or b.type == 'card_payment' then
            G.exec('UPDATE accounts SET balance=balance-? WHERE id=? AND user_id=?',
                   amount, tonumber(b.account_id), u.id)
            if b.to_account_id then
                G.exec('UPDATE accounts SET balance=balance+? WHERE id=? AND user_id=?',
                       amount, tonumber(b.to_account_id), u.id)
            end
        end
    end
    util.ok({ok = true, id = res.last_id})

elseif method == 'DELETE' then
    if not id then return util.err(400, 'Brak id') end
    -- Reverse balance effect before deleting
    local rows = G.query('SELECT * FROM transactions WHERE id=? AND user_id=?', id, u.id)
    if #rows == 0 then return util.err(404, 'Nie znaleziono') end
    local t = rows[1]
    if t.is_pending == 0 then
        local am = tonumber(t.amount) or 0
        if t.type == 'income' then
            G.exec('UPDATE accounts SET balance=balance-? WHERE id=?', am, t.account_id)
        elseif t.type == 'expense' or t.type == 'atm' then
            G.exec('UPDATE accounts SET balance=balance+? WHERE id=?', am, t.account_id)
            if t.type == 'atm' and t.to_account_id then
                G.exec('UPDATE accounts SET balance=balance-? WHERE id=?', am, t.to_account_id)
            end
        elseif t.type == 'transfer' or t.type == 'card_payment' then
            G.exec('UPDATE accounts SET balance=balance+? WHERE id=?', am, t.account_id)
            if t.to_account_id then
                G.exec('UPDATE accounts SET balance=balance-? WHERE id=?', am, t.to_account_id)
            end
        end
    end
    G.exec('DELETE FROM transactions WHERE id=? AND user_id=?', id, u.id)
    util.ok({ok = true})

else
    util.err(405, 'Metoda niedozwolona')
end
