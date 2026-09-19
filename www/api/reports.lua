local util = require('_util')
local G    = require('grosznik')

local u = util.require_auth(); if not u then return end
local report = util.param('report') or 'cashflow'
local months = tonumber(util.param('months')) or 6

httpd.header('Content-Type', 'application/json; charset=utf-8')

local now = G.now()
local lt  = os.date('*t', now)

local function month_ts(y, m)
    return os.time({year=y, month=m, day=1, hour=0, min=0, sec=0})
end

-- ── cashflow: monthly income vs expense ──────────────────────────────────────
if report == 'cashflow' then
    local result = {}
    for i = months - 1, 0, -1 do
        local y, m = lt.year, lt.month - i
        while m <= 0 do m = m + 12; y = y - 1 end
        local ts_start = month_ts(y, m)
        local ts_end   = month_ts(y, m == 12 and 1 or m + 1)
        if m == 12 then ts_end = month_ts(y + 1, 1) end
        local inc = G.query(
            'SELECT COALESCE(SUM(amount),0) as s FROM transactions '..
            'WHERE user_id=? AND type="income" AND is_pending=0 AND date>=? AND date<?',
            u.id, ts_start, ts_end)
        local exp = G.query(
            'SELECT COALESCE(SUM(amount),0) as s FROM transactions '..
            'WHERE user_id=? AND type="expense" AND is_pending=0 AND date>=? AND date<?',
            u.id, ts_start, ts_end)
        result[#result+1] = {
            year    = y,
            month   = m,
            label   = string.format('%02d.%04d', m, y),
            income  = inc[1] and tonumber(inc[1].s) or 0,
            expense = exp[1] and tonumber(exp[1].s) or 0,
        }
    end
    util.ok(result)

-- ── categories: expense breakdown for given month ────────────────────────────
elseif report == 'categories' then
    local y = tonumber(util.param('year'))  or lt.year
    local m = tonumber(util.param('month')) or lt.month
    local ts_start = month_ts(y, m)
    local ts_end   = m == 12 and month_ts(y+1, 1) or month_ts(y, m+1)
    local rows = G.query(
        'SELECT c.name, c.color, c.icon, COALESCE(SUM(t.amount),0) as total '..
        'FROM transactions t '..
        'JOIN categories c ON c.id=t.category_id '..
        'WHERE t.user_id=? AND t.type="expense" AND t.is_pending=0 '..
        '  AND t.date>=? AND t.date<? '..
        'GROUP BY c.id ORDER BY total DESC',
        u.id, ts_start, ts_end)
    util.ok(rows)

-- ── forecast: projected balance to end of month ───────────────────────────────
elseif report == 'forecast' then
    local total_bal = G.query(
        'SELECT COALESCE(SUM(balance),0) as s FROM accounts '..
        'WHERE user_id=? AND is_active=1 AND type NOT IN ("credit_card")', u.id)
    local balance = total_bal[1] and tonumber(total_bal[1].s) or 0

    local ts_end = lt.month == 12 and month_ts(lt.year+1, 1) or month_ts(lt.year, lt.month+1)
    local pending_obls = G.query(
        'SELECT COALESCE(SUM(amount),0) as s FROM obligation_instances '..
        'WHERE user_id=? AND status="pending" AND due_date>=? AND due_date<?',
        u.id, now, ts_end)
    local pending_cost = pending_obls[1] and tonumber(pending_obls[1].s) or 0

    local expected_inc = G.query(
        'SELECT COALESCE(SUM(amount),0) as s FROM transactions '..
        'WHERE user_id=? AND type="income" AND is_pending=1 AND date>=? AND date<?',
        u.id, now, ts_end)
    local income_pending = expected_inc[1] and tonumber(expected_inc[1].s) or 0

    -- Forecast points: daily until end of month
    local points = {}
    local days   = math.floor((ts_end - now) / 86400)
    local running = balance
    for d = 0, days do
        local ts = now + d * 86400
        local day_dt = os.date('*t', ts)
                local day_obls = G.query(
            'SELECT COALESCE(SUM(amount),0) as s FROM obligation_instances '
            ..'WHERE user_id=? AND status="pending" AND due_date>=? AND due_date<?',
            u.id, ts, ts + 86400)
        running = running - (day_obls[1] and tonumber(day_obls[1].s) or 0)
        points[#points+1] = {
            date    = string.format('%02d.%02d', day_dt.day, day_dt.month),
            balance = math.floor(running * 100) / 100
        }
    end

    util.ok({
        current_balance  = balance,
        pending_costs    = pending_cost,
        expected_income  = income_pending,
        projected_eom    = balance - pending_cost + income_pending,
        forecast_points  = points
    })

else
    util.err(400, 'Nieznany raport: '..report)
end
