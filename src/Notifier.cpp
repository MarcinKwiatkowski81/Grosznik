#include "Notifier.h"
#include <sqlite3.h>
#include <ctime>
#include <sstream>
#include <iomanip>
#include <vector>
#include <string>
#include <thread>
#include <chrono>

namespace grosznik {

struct Db {
    sqlite3* h = nullptr;
    explicit Db(const std::string& p) {
        sqlite3_open(p.c_str(), &h);
        if (h) {
            sqlite3_exec(h, "PRAGMA journal_mode=WAL;", nullptr, nullptr, nullptr);
            sqlite3_exec(h, "PRAGMA foreign_keys=ON;",  nullptr, nullptr, nullptr);
        }
    }
    ~Db() { if (h) sqlite3_close(h); }

    using Row = std::vector<std::string>;

    std::vector<Row> query(const char* sql, const std::vector<std::string>& p = {}) {
        std::vector<Row> res;
        if (!h) return res;
        sqlite3_stmt* st;
        if (sqlite3_prepare_v2(h, sql, -1, &st, nullptr) != SQLITE_OK) return res;
        for (int i = 0; i < (int)p.size(); ++i)
            sqlite3_bind_text(st, i+1, p[i].c_str(), -1, SQLITE_TRANSIENT);
        int nc = sqlite3_column_count(st);
        while (sqlite3_step(st) == SQLITE_ROW) {
            Row r;
            for (int c = 0; c < nc; ++c) {
                auto* t = (const char*)sqlite3_column_text(st, c);
                r.push_back(t ? t : "");
            }
            res.push_back(r);
        }
        sqlite3_finalize(st);
        return res;
    }

    bool exec(const char* sql, const std::vector<std::string>& p = {}) {
        if (!h) return false;
        sqlite3_stmt* st;
        if (sqlite3_prepare_v2(h, sql, -1, &st, nullptr) != SQLITE_OK) return false;
        for (int i = 0; i < (int)p.size(); ++i)
            sqlite3_bind_text(st, i+1, p[i].c_str(), -1, SQLITE_TRANSIENT);
        bool ok = sqlite3_step(st) == SQLITE_DONE;
        sqlite3_finalize(st);
        return ok;
    }
};

static std::string fmt2(double v) {
    std::ostringstream s;
    s << std::fixed << std::setprecision(2) << v;
    return s.str();
}

static void generateInstances(Db& db) {
    time_t now = time(nullptr);
    struct tm* lt = localtime(&now);
    for (int delta = 0; delta <= 1; delta++) {
        struct tm t = *lt;
        t.tm_mon += delta;
        if (t.tm_mon == 12) { t.tm_mon = 0; t.tm_year++; }
        int y = t.tm_year + 1900, m = t.tm_mon + 1;
        auto obls = db.query(
            "SELECT id, user_id, amount, payment_day FROM obligations "
            "WHERE is_active=1 AND frequency='monthly'");
        for (auto& o : obls) {
            int day = std::stoi(o[3]);
            struct tm due = {};
            due.tm_year = y - 1900; due.tm_mon = m - 1; due.tm_mday = day;
            time_t due_ts = mktime(&due);
            db.exec(
                "INSERT OR IGNORE INTO obligation_instances"
                "(obligation_id,user_id,period_year,period_month,due_date,amount,status)"
                " VALUES(?,?,?,?,?,?,'pending')",
                {o[0], o[1], std::to_string(y), std::to_string(m),
                 std::to_string((long long)due_ts), o[2]});
        }
    }
}

static void checkObligations(Db& db, telebot::Bot& bot) {
    generateInstances(db);
    time_t now = time(nullptr);
    time_t in3 = now + 3 * 24 * 3600;

    // Remind 3 days before
    auto due3 = db.query(
        "SELECT oi.id, u.telegram_chat_id, o.name, oi.amount, oi.due_date, o.currency "
        "FROM obligation_instances oi "
        "JOIN obligations o ON o.id=oi.obligation_id "
        "JOIN users u ON u.id=oi.user_id "
        "WHERE oi.status='pending' AND oi.notified_3days=0 "
        "  AND oi.due_date>? AND oi.due_date<=? "
        "  AND u.notify_telegram=1 AND u.telegram_chat_id!=''",
        {std::to_string((long long)now), std::to_string((long long)in3)});
    for (auto& r : due3) {
        time_t due_ts = (time_t)std::stoll(r[4]);
        char buf[32]; struct tm* dt = localtime(&due_ts);
        strftime(buf, sizeof(buf), "%d.%m.%Y", dt);
        std::string msg = "Przypomnienie: Za 3 dni platnosc za "
            + r[2] + ": " + fmt2(std::stod(r[3])) + " " + r[5]
            + " (termin: " + buf + ")";
        bot.notifyChat(std::stoll(r[1]), msg);
        db.exec("UPDATE obligation_instances SET notified_3days=1 WHERE id=?", {r[0]});
    }

    // Remind on due day
    struct tm today = *localtime(&now);
    today.tm_hour = 0; today.tm_min = 0; today.tm_sec = 0;
    time_t day_start = mktime(&today);
    struct tm tomorrow = today; tomorrow.tm_mday++;
    time_t day_end = mktime(&tomorrow);

    auto due_today = db.query(
        "SELECT oi.id, u.telegram_chat_id, o.name, oi.amount, o.currency "
        "FROM obligation_instances oi "
        "JOIN obligations o ON o.id=oi.obligation_id "
        "JOIN users u ON u.id=oi.user_id "
        "WHERE oi.status='pending' AND oi.notified_due=0 "
        "  AND oi.due_date>=? AND oi.due_date<? "
        "  AND u.notify_telegram=1 AND u.telegram_chat_id!=''",
        {std::to_string((long long)day_start), std::to_string((long long)day_end)});
    for (auto& r : due_today) {
        std::string msg = "Dzis termin platnosci: " + r[2]
            + " — " + fmt2(std::stod(r[3])) + " " + r[4];
        bot.notifyChat(std::stoll(r[1]), msg);
        db.exec("UPDATE obligation_instances SET notified_due=1 WHERE id=?", {r[0]});
    }

    // Mark overdue
    db.exec("UPDATE obligation_instances SET status='overdue' "
            "WHERE status='pending' AND due_date < ?",
            {std::to_string((long long)now - 86400)});
}

static void checkBalanceAlerts(Db& db, telebot::Bot& bot) {
    auto rows = db.query(
        "SELECT a.name, a.balance, a.currency, u.balance_alert_threshold, u.telegram_chat_id "
        "FROM accounts a JOIN users u ON u.id=a.user_id "
        "WHERE a.type='checking' AND a.is_active=1 "
        "  AND u.notify_telegram=1 AND u.telegram_chat_id!='' "
        "  AND a.balance < u.balance_alert_threshold");
    for (auto& r : rows) {
        std::string msg = "Alert: Saldo konta " + r[0]
            + " wynosi " + fmt2(std::stod(r[1])) + " " + r[2]
            + " (ponizej progu " + fmt2(std::stod(r[3])) + " " + r[2] + ")";
        bot.notifyChat(std::stoll(r[4]), msg);
    }
}

static void sendWeeklyReport(Db& db, telebot::Bot& bot) {
    time_t now = time(nullptr);
    time_t week_ago = now - 7 * 24 * 3600;
    auto users = db.query(
        "SELECT id, telegram_chat_id FROM users "
        "WHERE notify_telegram=1 AND telegram_chat_id!=''");
    for (auto& u : users) {
        auto inc = db.query(
            "SELECT COALESCE(SUM(amount),0) FROM transactions "
            "WHERE user_id=? AND type='income' AND date>=? AND date<=?",
            {u[0], std::to_string((long long)week_ago), std::to_string((long long)now)});
        auto exp = db.query(
            "SELECT COALESCE(SUM(amount),0) FROM transactions "
            "WHERE user_id=? AND type='expense' AND date>=? AND date<=?",
            {u[0], std::to_string((long long)week_ago), std::to_string((long long)now)});
        double income  = inc.empty() ? 0 : std::stod(inc[0][0]);
        double expense = exp.empty() ? 0 : std::stod(exp[0][0]);
        std::string msg = "Raport tygodniowy:\n"
            "Przychody: " + fmt2(income)  + " PLN\n"
            "Wydatki:   " + fmt2(expense) + " PLN\n"
            "Bilans:    " + fmt2(income - expense) + " PLN";
        bot.notifyChat(std::stoll(u[1]), msg);
    }
}

void notifierThread(telebot::Bot& bot,
                    const std::string& dbPath,
                    std::atomic<bool>& running) {
    const int INTERVAL_SEC = 15 * 60;
    const int TICK_SEC     = 5;
    int ticks = 0;
    int monday_yday_sent = -1;

    while (running.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::seconds(TICK_SEC));
        ticks += TICK_SEC;
        if (ticks >= INTERVAL_SEC) {
            ticks = 0;
            Db db(dbPath);
            checkObligations(db, bot);
            checkBalanceAlerts(db, bot);
            time_t now = time(nullptr);
            struct tm* lt = localtime(&now);
            if (lt->tm_wday == 1 && lt->tm_hour == 8
                && monday_yday_sent != lt->tm_yday) {
                monday_yday_sent = lt->tm_yday;
                sendWeeklyReport(db, bot);
            }
        }
    }
}

} // namespace grosznik
