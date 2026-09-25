
#include "Schema.h"
#include <sqlite3.h>
#include <cstdio>

static const char kSchema[] = R"SQL(
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS users (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    username                 TEXT    NOT NULL UNIQUE,
    email                    TEXT    NOT NULL UNIQUE,
    password_hash            TEXT    NOT NULL,
    telegram_chat_id         TEXT    NOT NULL DEFAULT '',
    default_currency         TEXT    NOT NULL DEFAULT 'PLN',
    timezone                 TEXT    NOT NULL DEFAULT 'Europe/Warsaw',
    balance_alert_threshold  REAL    NOT NULL DEFAULT 500.0,
    notify_telegram          INTEGER NOT NULL DEFAULT 1,
    created_at               INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS accounts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id           INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name              TEXT    NOT NULL,
    type              TEXT    NOT NULL CHECK(type IN
                        ('checking','savings','deposit','credit_card','cash','investment')),
    currency          TEXT    NOT NULL DEFAULT 'PLN',
    balance           REAL    NOT NULL DEFAULT 0.0,
    interest_rate     REAL,
    savings_goal      REAL,
    savings_goal_name TEXT,
    credit_limit      REAL,
    billing_day       INTEGER,
    payment_due_days  INTEGER,
    is_active         INTEGER NOT NULL DEFAULT 1,
    created_at        INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS categories (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id   INTEGER REFERENCES users(id) ON DELETE CASCADE,
    parent_id INTEGER REFERENCES categories(id),
    name      TEXT    NOT NULL,
    type      TEXT    NOT NULL CHECK(type IN ('income','expense','transfer')),
    icon      TEXT    NOT NULL DEFAULT '',
    color     TEXT    NOT NULL DEFAULT '#888888'
);

CREATE TABLE IF NOT EXISTS transactions (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id        INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id     INTEGER NOT NULL REFERENCES accounts(id),
    to_account_id  INTEGER REFERENCES accounts(id),
    category_id    INTEGER REFERENCES categories(id),
    type           TEXT    NOT NULL CHECK(type IN
                     ('income','expense','transfer','card_payment','atm')),
    amount         REAL    NOT NULL,
    currency       TEXT    NOT NULL DEFAULT 'PLN',
    date           INTEGER NOT NULL,
    description    TEXT    NOT NULL DEFAULT '',
    tags           TEXT    NOT NULL DEFAULT '',
    is_pending     INTEGER NOT NULL DEFAULT 0,
    created_at     INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS obligations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id  INTEGER NOT NULL REFERENCES accounts(id),
    name        TEXT    NOT NULL,
    amount      REAL    NOT NULL,
    currency    TEXT    NOT NULL DEFAULT 'PLN',
    frequency   TEXT    NOT NULL CHECK(frequency IN ('monthly','yearly','weekly')),
    payment_day INTEGER NOT NULL,
    category_id INTEGER REFERENCES categories(id),
    is_active   INTEGER NOT NULL DEFAULT 1,
    created_at  INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS obligation_instances (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    obligation_id   INTEGER NOT NULL REFERENCES obligations(id) ON DELETE CASCADE,
    user_id         INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    period_year     INTEGER NOT NULL,
    period_month    INTEGER NOT NULL,
    due_date        INTEGER NOT NULL,
    amount          REAL    NOT NULL,
    status          TEXT    NOT NULL DEFAULT 'pending'
                            CHECK(status IN ('pending','paid','overdue')),
    paid_at         INTEGER,
    transaction_id  INTEGER REFERENCES transactions(id),
    notified_3days  INTEGER NOT NULL DEFAULT 0,
    notified_due    INTEGER NOT NULL DEFAULT 0,
    UNIQUE(obligation_id, period_year, period_month)
);

CREATE TABLE IF NOT EXISTS notification_log (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id  INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type     TEXT    NOT NULL,
    channel  TEXT    NOT NULL,
    message  TEXT    NOT NULL,
    sent_at  INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    status   TEXT    NOT NULL DEFAULT 'sent'
);

-- Ustawienia aplikacji (klucz-wartość, niezwiązane z użytkownikiem)
CREATE TABLE IF NOT EXISTS app_settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- Domyślne kategorie (user_id NULL = systemowe, wstawiane tylko raz)
INSERT OR IGNORE INTO categories(id, user_id, parent_id, name, type, icon, color) VALUES
  (1,  NULL, NULL, 'Przychody',          'income',   '💰', '#2ea043'),
  (2,  NULL,    1, 'Wynagrodzenie',      'income',   '💼', '#2ea043'),
  (3,  NULL,    1, 'Najem',              'income',   '🏠', '#2ea043'),
  (4,  NULL,    1, 'Premia',             'income',   '⭐', '#2ea043'),
  (5,  NULL,    1, 'Zwrot podatku',      'income',   '📋', '#2ea043'),
  (6,  NULL,    1, 'Inne przychody',     'income',   '📥', '#2ea043'),
  (7,  NULL, NULL, 'Wydatki',            'expense',  '💸', '#f85149'),
  (8,  NULL,    7, 'Jedzenie',           'expense',  '🍔', '#f85149'),
  (9,  NULL,    8, 'Zakupy spożywcze',   'expense',  '🛒', '#f85149'),
  (10, NULL,    8, 'Restauracje',        'expense',  '🍽️', '#f85149'),
  (11, NULL,    7, 'Transport',          'expense',  '🚗', '#d29922'),
  (12, NULL,   11, 'Paliwo',             'expense',  '⛽', '#d29922'),
  (13, NULL,   11, 'Bilety',             'expense',  '🎫', '#d29922'),
  (14, NULL,    7, 'Mieszkanie',         'expense',  '🏠', '#388bfd'),
  (15, NULL,   14, 'Czynsz',             'expense',  '🔑', '#388bfd'),
  (16, NULL,   14, 'Media',              'expense',  '💡', '#388bfd'),
  (17, NULL,    7, 'Rozrywka',           'expense',  '🎬', '#a371f7'),
  (18, NULL,    7, 'Zdrowie',            'expense',  '🏥', '#ec6547'),
  (19, NULL,    7, 'Edukacja',           'expense',  '📚', '#79c0ff'),
  (20, NULL,    7, 'Ubrania',            'expense',  '👕', '#ffa657'),
  (21, NULL,    7, 'Inne wydatki',       'expense',  '📤', '#8b949e'),
  (22, NULL, NULL, 'Przelewy',           'transfer', '🔄', '#8b949e');
)SQL";

namespace grosznik {

bool initSchema(const std::string& dbPath) {
    sqlite3* db = nullptr;
    if (sqlite3_open(dbPath.c_str(), &db) != SQLITE_OK) {
        fprintf(stderr, "[GROSZNIK] Cannot open DB %s: %s\n",
                dbPath.c_str(), sqlite3_errmsg(db));
        sqlite3_close(db);
        return false;
    }
    char* err = nullptr;
    if (sqlite3_exec(db, kSchema, nullptr, nullptr, &err) != SQLITE_OK) {
        fprintf(stderr, "[GROSZNIK] Schema error: %s\n", err);
        sqlite3_free(err);
        sqlite3_close(db);
        return false;
    }
    sqlite3_close(db);
    fprintf(stderr, "[GROSZNIK] Schema initialized: %s\n", dbPath.c_str());
    return true;
}

} // namespace grosznik
