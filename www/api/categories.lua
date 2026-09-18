local util = require('_util')
local G    = require('grosznik')

local u = util.require_auth(); if not u then return end
local method = httpd.method()
local id     = util.id()

httpd.header('Content-Type', 'application/json; charset=utf-8')

if method == 'GET' then
    local typ = util.param('type')
    local sql = 'SELECT c.*, p.name as parent_name '..
                'FROM categories c LEFT JOIN categories p ON p.id=c.parent_id '..
                'WHERE (c.user_id IS NULL OR c.user_id=?)'
    local args = {u.id}
    if typ then sql = sql..' AND c.type=?'; args[#args+1] = typ end
    sql = sql..' ORDER BY c.type, COALESCE(c.parent_id, c.id), c.id'
    util.ok(G.query(sql, table.unpack(args)))

elseif method == 'POST' then
    local b = util.body()
    if not b.name or not b.type then
        return util.err(400, 'Brak wymaganych pol: name, type')
    end
    local res = G.exec(
        'INSERT INTO categories(user_id,parent_id,name,type,icon,color) VALUES(?,?,?,?,?,?)',
        u.id, tonumber(b.parent_id), b.name, b.type,
        b.icon or '', b.color or '#888888')
    if not res then return util.err(500, 'Blad zapisu') end
    util.ok({ok = true, id = res.last_id})

elseif method == 'PUT' then
    if not id then return util.err(400, 'Brak id') end
    local b = util.body()
    local sets, vals = {}, {}
    local function add(col, val)
        if val ~= nil then sets[#sets+1] = col..'=?'; vals[#vals+1] = val end
    end
    add('name',  b.name)
    add('icon',  b.icon)
    add('color', b.color)
    if #sets == 0 then return util.err(400, 'Brak pol do aktualizacji') end
    vals[#vals+1] = id; vals[#vals+1] = u.id
    G.exec('UPDATE categories SET '..table.concat(sets,',')..' WHERE id=? AND user_id=?',
           table.unpack(vals))
    util.ok({ok = true})

elseif method == 'DELETE' then
    if not id then return util.err(400, 'Brak id') end
    G.exec('DELETE FROM categories WHERE id=? AND user_id=?', id, u.id)
    util.ok({ok = true})

else
    util.err(405, 'Metoda niedozwolona')
end
