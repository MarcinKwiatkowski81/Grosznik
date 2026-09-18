// grosznik_module.cpp — Lua 5.4 C extension
// Exposes SQLite DB access, JWT HS256, and password hashing to Lua scripts.
//
// Usage in Lua:  local G = require("grosznik")
//
// Build: g++ -shared -fPIC -std=c++17 -O2 -I/usr/include/lua5.4
//          grosznik_module.cpp -o grosznik.so -lsqlite3 -lssl -lcrypto
//
// Env vars:
//   GROSZNIK_DB  – SQLite file path  (default: /data/grosznik.db)
//   JWT_SECRET   – HMAC-SHA256 key   (default: change_me_in_production)

#include <lua5.4/lua.hpp>
#include <sqlite3.h>
#include <openssl/hmac.h>
#include <openssl/sha.h>
#include <openssl/rand.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <sstream>
#include <vector>

// ── Globals ───────────────────────────────────────────────────────────────────
static sqlite3*    gDb{nullptr};
static std::mutex  gDbMu;
static std::string gJwtSecret;

// ── Base64url ─────────────────────────────────────────────────────────────────
static const char kB64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static std::string b64url_enc(const unsigned char* d, size_t n) {
    std::string out; out.reserve((n+2)/3*4);
    for (size_t i = 0; i < n; i += 3) {
        unsigned b = (unsigned)d[i] << 16;
        if (i+1 < n) b |= (unsigned)d[i+1] << 8;
        if (i+2 < n) b |= (unsigned)d[i+2];
        out += kB64[(b>>18)&63]; out += kB64[(b>>12)&63];
        out += (i+1<n) ? kB64[(b>>6)&63]  : '=';
        out += (i+2<n) ? kB64[(b   )&63]  : '=';
    }
    while (!out.empty() && out.back()=='=') out.pop_back();
    return out;
}

static int b64val(char c) {
    if (c>='A'&&c<='Z') return c-'A';
    if (c>='a'&&c<='z') return 26+c-'a';
    if (c>='0'&&c<='9') return 52+c-'0';
    if (c=='-'||c=='+') return 62;
    if (c=='_'||c=='/') return 63;
    return -1;
}

static std::string b64url_dec(const std::string& s) {
    std::string out; int buf=0,bits=0;
    for (char c:s) {
        int v=b64val(c); if(v<0) continue;
        buf=(buf<<6)|v; bits+=6;
        if(bits>=8){bits-=8;out+=(char)((buf>>bits)&0xFF);}
    }
    return out;
}

// ── Hex / SHA256 ─────────────────────────────────────────────────────────────
static std::string to_hex(const unsigned char* d, size_t n) {
    static const char h[]="0123456789abcdef";
    std::string out; out.reserve(n*2);
    for(size_t i=0;i<n;i++){out+=h[d[i]>>4];out+=h[d[i]&0xF];}
    return out;
}

static std::string sha256_hex(const std::string& data) {
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256((const unsigned char*)data.data(), data.size(), digest);
    return to_hex(digest, SHA256_DIGEST_LENGTH);
}

static std::string hmac_sha256_b64(const std::string& key, const std::string& msg) {
    unsigned char digest[EVP_MAX_MD_SIZE]; unsigned int dlen=0;
    HMAC(EVP_sha256(), key.data(), (int)key.size(),
         (const unsigned char*)msg.data(), (int)msg.size(), digest, &dlen);
    return b64url_enc(digest, dlen);
}

// ── JWT HS256 ─────────────────────────────────────────────────────────────────
static std::string jwt_sign_impl(int64_t uid, const std::string& name, int64_t exp_sec) {
    std::string hdr_json = R"({"alg":"HS256","typ":"JWT"})";
    std::string hdr_b64  = b64url_enc((const unsigned char*)hdr_json.data(), hdr_json.size());
    int64_t now = (int64_t)time(nullptr);
    std::ostringstream pay;
    pay << "{\"sub\":" << uid << ",\"name\":\"" << name << "\""
        << ",\"iat\":" << now << ",\"exp\":" << (now+exp_sec) << "}";
    std::string pay_json = pay.str();
    std::string pay_b64  = b64url_enc((const unsigned char*)pay_json.data(), pay_json.size());
    std::string signing  = hdr_b64 + "." + pay_b64;
    return signing + "." + hmac_sha256_b64(gJwtSecret, signing);
}

static bool jwt_verify_impl(const std::string& token, int64_t& out_id, std::string& out_name) {
    size_t d1 = token.find('.');
    if (d1==std::string::npos) return false;
    size_t d2 = token.find('.', d1+1);
    if (d2==std::string::npos) return false;
    std::string hdr_b64 = token.substr(0, d1);
    std::string pay_b64 = token.substr(d1+1, d2-d1-1);
    std::string sig     = token.substr(d2+1);
    if (sig != hmac_sha256_b64(gJwtSecret, hdr_b64+"."+pay_b64)) return false;
    std::string pay = b64url_dec(pay_b64);
    auto getField = [&](const char* key) -> std::string {
        std::string k = std::string("\"") + key + "\":";
        size_t p = pay.find(k); if(p==std::string::npos) return "";
        p += k.size();
        if (pay[p]=='"') { size_t q=pay.find('"',p+1); return q==std::string::npos?"":pay.substr(p+1,q-p-1); }
        size_t q=p; while(q<pay.size()&&(isdigit(pay[q])||pay[q]=='-'))q++;
        return pay.substr(p,q-p);
    };
    std::string exp_s = getField("exp");
    if (exp_s.empty()) return false;
    if (std::stoll(exp_s) < (int64_t)time(nullptr)) return false;
    std::string sub = getField("sub");
    if (sub.empty()) return false;
    out_id   = std::stoll(sub);
    out_name = getField("name");
    return true;
}

// ── SQLite param binding ──────────────────────────────────────────────────────
static void bind_params(sqlite3_stmt* st, lua_State* L, int from, int argc) {
    for (int i=from; i<=argc; i++) {
        int col = i-from+1, t = lua_type(L,i);
        if (t==LUA_TNIL||t==LUA_TNONE) sqlite3_bind_null(st,col);
        else if (t==LUA_TNUMBER) {
            if (lua_isinteger(L,i)) sqlite3_bind_int64(st,col,lua_tointeger(L,i));
            else sqlite3_bind_double(st,col,lua_tonumber(L,i));
        } else {
            size_t len; const char* s=lua_tolstring(L,i,&len);
            sqlite3_bind_text(st,col,s,(int)len,SQLITE_TRANSIENT);
        }
    }
}

// ── Lua: grosznik.query(sql, ...) → array of row-tables ──────────────────────
static int l_query(lua_State* L) {
    const char* sql = luaL_checkstring(L,1);
    int argc = lua_gettop(L);
    std::lock_guard<std::mutex> lk(gDbMu);
    sqlite3_stmt* st=nullptr;
    if (sqlite3_prepare_v2(gDb,sql,-1,&st,nullptr)!=SQLITE_OK) {
        lua_pushnil(L); lua_pushstring(L,sqlite3_errmsg(gDb)); return 2;
    }
    bind_params(st,L,2,argc);
    lua_newtable(L); int row=1, nc=sqlite3_column_count(st);
    while (sqlite3_step(st)==SQLITE_ROW) {
        lua_newtable(L);
        for (int c=0;c<nc;c++) {
            lua_pushstring(L,sqlite3_column_name(st,c));
            switch(sqlite3_column_type(st,c)) {
                case SQLITE_INTEGER: lua_pushinteger(L,sqlite3_column_int64(st,c)); break;
                case SQLITE_FLOAT:   lua_pushnumber(L,sqlite3_column_double(st,c)); break;
                case SQLITE_NULL:    lua_pushnil(L); break;
                default: { const char* t=(const char*)sqlite3_column_text(st,c);
                           lua_pushstring(L,t?t:""); } break;
            }
            lua_settable(L,-3);
        }
        lua_rawseti(L,-2,row++);
    }
    sqlite3_finalize(st);
    return 1;
}

// ── Lua: grosznik.exec(sql, ...) → {changes=N, last_id=N} ────────────────────
static int l_exec(lua_State* L) {
    const char* sql = luaL_checkstring(L,1);
    int argc = lua_gettop(L);
    std::lock_guard<std::mutex> lk(gDbMu);
    sqlite3_stmt* st=nullptr;
    if (sqlite3_prepare_v2(gDb,sql,-1,&st,nullptr)!=SQLITE_OK) {
        lua_pushnil(L); lua_pushstring(L,sqlite3_errmsg(gDb)); return 2;
    }
    bind_params(st,L,2,argc);
    int rc=sqlite3_step(st); sqlite3_finalize(st);
    if (rc!=SQLITE_DONE&&rc!=SQLITE_ROW) {
        lua_pushnil(L); lua_pushstring(L,sqlite3_errmsg(gDb)); return 2;
    }
    lua_newtable(L);
    lua_pushinteger(L,sqlite3_changes(gDb));          lua_setfield(L,-2,"changes");
    lua_pushinteger(L,sqlite3_last_insert_rowid(gDb)); lua_setfield(L,-2,"last_id");
    return 1;
}

// ── Lua: grosznik.jwt_sign(uid, username [, exp_sec]) → token ────────────────
static int l_jwt_sign(lua_State* L) {
    int64_t uid  = (int64_t)luaL_checkinteger(L,1);
    const char* name = luaL_checkstring(L,2);
    int64_t exp  = (int64_t)luaL_optinteger(L,3,86400);
    lua_pushstring(L, jwt_sign_impl(uid, name, exp).c_str());
    return 1;
}

// ── Lua: grosznik.jwt_verify(token) → {id, username} | nil ──────────────────
static int l_jwt_verify(lua_State* L) {
    const char* tok = luaL_checkstring(L,1);
    int64_t id=0; std::string name;
    if (!jwt_verify_impl(tok,id,name)) { lua_pushnil(L); return 1; }
    lua_newtable(L);
    lua_pushinteger(L,id);          lua_setfield(L,-2,"id");
    lua_pushstring(L,name.c_str()); lua_setfield(L,-2,"username");
    return 1;
}

// ── Lua: grosznik.hash_password(pwd) → "SALT$HASH" ──────────────────────────
static int l_hash_password(lua_State* L) {
    const char* pwd = luaL_checkstring(L,1);
    unsigned char salt[16]; RAND_bytes(salt,16);
    std::string s = to_hex(salt,16) + "$" + sha256_hex(to_hex(salt,16) + pwd);
    lua_pushstring(L,s.c_str()); return 1;
}

// ── Lua: grosznik.check_password(pwd, stored) → bool ────────────────────────
static int l_check_password(lua_State* L) {
    const char* pwd = luaL_checkstring(L,1);
    std::string stored = luaL_checkstring(L,2);
    size_t sep = stored.find('$');
    if (sep==std::string::npos) { lua_pushboolean(L,0); return 1; }
    std::string salt = stored.substr(0,sep), expected = stored.substr(sep+1);
    lua_pushboolean(L, sha256_hex(salt+pwd)==expected ? 1 : 0);
    return 1;
}

// ── Lua: grosznik.now() → unix timestamp ─────────────────────────────────────
static int l_now(lua_State* L) {
    lua_pushinteger(L,(lua_Integer)time(nullptr)); return 1;
}

// ── Module registration ───────────────────────────────────────────────────────
static const luaL_Reg kLib[] = {
    {"query",          l_query},
    {"exec",           l_exec},
    {"jwt_sign",       l_jwt_sign},
    {"jwt_verify",     l_jwt_verify},
    {"hash_password",  l_hash_password},
    {"check_password", l_check_password},
    {"now",            l_now},
    {nullptr, nullptr}
};

extern "C" int luaopen_grosznik(lua_State* L) {
    if (!gDb) {
        const char* p = getenv("GROSZNIK_DB");
        if (!p) p = "/data/grosznik.db";
        if (sqlite3_open(p,&gDb)!=SQLITE_OK) {
            lua_pushstring(L,sqlite3_errmsg(gDb)); return lua_error(L);
        }
        sqlite3_exec(gDb,"PRAGMA journal_mode=WAL;",nullptr,nullptr,nullptr);
        sqlite3_exec(gDb,"PRAGMA foreign_keys=ON;", nullptr,nullptr,nullptr);
        fprintf(stderr,"[GROSZNIK] SQLite: %s\n",p);
    }
    if (gJwtSecret.empty()) {
        const char* s = getenv("JWT_SECRET");
        gJwtSecret = s ? s : "change_me_in_production";
    }
    luaL_newlib(L, kLib);
    return 1;
}
