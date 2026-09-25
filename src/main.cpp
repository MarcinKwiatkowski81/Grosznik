#include "Schema.h"
#include "BotHandler.h"
#include "Notifier.h"

#include <telebot/Bot.h>
#include <telebot/Config.h>

#include <EventLoop.h>
#include <sqlite3.h>

#include <cstdlib>
#include <cstdio>
#include <csignal>
#include <atomic>
#include <thread>
#include <string>
#include <pthread.h>

static std::atomic<bool> gRunning{true};

static std::string env(const char* name, const char* def = "") {
    const char* v = getenv(name);
    return v ? v : def;
}
static int envi(const char* name, int def = 0) {
    const char* v = getenv(name);
    return v ? std::stoi(v) : def;
}

// Read a single value from app_settings table.
// Returns empty string if not found or on error.
static std::string readAppSetting(const std::string& dbPath, const char* key) {
    sqlite3* db = nullptr;
    if (sqlite3_open_v2(dbPath.c_str(), &db,
                        SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return "";
    }
    sqlite3_stmt* st = nullptr;
    std::string result;
    if (sqlite3_prepare_v2(db,
            "SELECT value FROM app_settings WHERE key=?",
            -1, &st, nullptr) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(st) == SQLITE_ROW) {
            const char* v = (const char*)sqlite3_column_text(st, 0);
            if (v) result = v;
        }
        sqlite3_finalize(st);
    }
    sqlite3_close(db);
    return result;
}

int main() {
    // All config comes from env vars — set by build_and_run.sh from config.json
    std::string dbPath      = env("GROSZNIK_DB",          "./data/grosznik.db");
    std::string wwwRoot     = env("GROSZNIK_WWW",         "./www");
    std::string luaModule   = env("GROSZNIK_LUA_MODULE",  "./build/modules/lua_module.so");
    std::string gModule     = env("GROSZNIK_MODULE",      "./build/modules/grosznik.so");
    std::string tgOffset    = env("GROSZNIK_TG_OFFSET",   "./data/tg_offset");
    std::string tgUsers     = env("TELEGRAM_ALLOWED_USERS","");
    int port                = envi("GROSZNIK_PORT",         8080);
    int workers             = envi("GROSZNIK_WORKERS",         1);
    int threads             = envi("GROSZNIK_THREADS",         4);

    // Initialise SQLite schema (creates app_settings table too)
    if (!grosznik::initSchema(dbPath)) {
        fprintf(stderr, "FATAL: Cannot initialise database at %s\n", dbPath.c_str());
        return 1;
    }

    // Telegram token: DB takes priority over env var.
    // This lets the user configure the bot from the web UI without a restart.
    std::string tgToken = readAppSetting(dbPath, "telegram_bot_token");
    if (tgToken.empty()) {
        tgToken = env("TELEGRAM_BOT_TOKEN", "");
        if (!tgToken.empty())
            fprintf(stderr, "[GROSZNIK] Telegram token from env var (no DB setting)\n");
    } else {
        fprintf(stderr, "[GROSZNIK] Telegram token from app_settings (DB)\n");
    }

    signal(SIGPIPE, SIG_IGN);

    // Telegram bot + notifier threads
    std::thread botThread, notifierThread;

    if (!tgToken.empty()) {
        telebot::Config tgCfg;
        tgCfg.token             = tgToken;
        tgCfg.dropPendingOnStart= true;
        tgCfg.offsetFile        = tgOffset;

        if (!tgUsers.empty()) {
            size_t pos = 0;
            while (pos < tgUsers.size()) {
                size_t comma = tgUsers.find(',', pos);
                if (comma == std::string::npos) comma = tgUsers.size();
                try { tgCfg.allowedUsers.push_back(std::stoll(tgUsers.substr(pos, comma-pos))); }
                catch (...) {}
                pos = comma + 1;
            }
        }

        static telebot::Bot* gBot = nullptr;
        static telebot::Config gCfg = tgCfg;
        gBot = new telebot::Bot(gCfg);

        grosznik::registerBotCommands(*gBot, dbPath);

        botThread = std::thread([&]() {
            try { gBot->run(); }
            catch (const std::exception& e) { fprintf(stderr, "[BOT] %s\n", e.what()); }
        });

        notifierThread = std::thread([&]() {
            grosznik::notifierThread(*gBot, dbPath, gRunning);
        });

        std::thread([&]() {
            sigset_t s; sigemptyset(&s);
            sigaddset(&s, SIGINT); sigaddset(&s, SIGTERM);
            pthread_sigmask(SIG_BLOCK, &s, nullptr);
            int sig; sigwait(&s, &sig);
            fprintf(stderr, "[MAIN] Signal %d — stopping\n", sig);
            gRunning.store(false);
            gBot->stop();
        }).detach();
    } else {
        fprintf(stderr, "[GROSZNIK] Telegram bot disabled — configure token in Settings or TELEGRAM_BOT_TOKEN env var\n");
    }

    // HTTPD server
    httpd::ServerConfig cfg;
    cfg.httpPort         = (uint16_t)port;
    cfg.docRoot          = wwwRoot;
    cfg.indexFiles       = "index.lhtml";
    cfg.workers          = workers;
    cfg.threadsPerWorker = threads;
    cfg.modules.push_back({luaModule, ""});
    cfg.modules.push_back({gModule,   ""});

    fprintf(stderr, "[GROSZNIK] port=%d  www=%s  db=%s\n",
            port, wwwRoot.c_str(), dbPath.c_str());
    fprintf(stderr, "[GROSZNIK] lua_module=%s\n", luaModule.c_str());
    fprintf(stderr, "[GROSZNIK] grosznik_module=%s\n", gModule.c_str());

    httpd::Server server;
    server.init(cfg);
    server.run();

    gRunning.store(false);
    if (botThread.joinable())      botThread.join();
    if (notifierThread.joinable()) notifierThread.join();

    return 0;
}
