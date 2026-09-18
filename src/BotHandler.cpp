#include "BotHandler.h"
#include <sqlite3.h>
#include <ctime>
#include <sstream>
#include <iomanip>
#include <vector>
#include <string>

namespace grosznik {

// ── Minimal SQLite helper ─────────────────────────────────────────────────────
struct Db {
    sqlite3* h = nullptr;
    explicit Db(const std::string& path) {
        sqlite3_open(path.c_str(), &h);
        if (h) {
            sqlite3_exec(h, "PRAGMA journal_mode=WAL;", 0,0,0);
            sqlite3_exec(h, "PRAGMA foreign_keys=ON;",  0,0,0);
        }
    }
    ~Db() { if (h) sqlite3_close(h); }

    using Row = std::vector<std::string>;

    std::vector<Row> query(const char* sql,
                           const std::vector<std::string>& p = {}) {
        std::vector<Row> result;
        if (!h) return result;
        sqlite3_stmt* st;
        if (sqlite3_prepare_v2(h, sql, -1, &st, nullptr) != SQLITE_OK) return result;
        for (int i = 0; i < (int)p.size(); ++i)
            sqlite3_bind_text(st, i+1, p[i].c_str(), -1, SQLITE_TRANSIENT);
        int ncols = sqlite3_column_count(st);
        while (sqlite3_step(st) == SQLITE_ROW) {
            Row row;
            for (int c = 0; c < ncols; ++c) {
                auto* t = (const char*)sqlite3_column_text(st, c);
                row.push_back(t ? t : "");
            }
            result.push_back(row);
        }
        sqlite3_finalize(st);
        return result;
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
    std::ostringstream ss; ss << std::fixed << std::setprecision(2) << v; return ss.str();
}

void registerBotCommands(telebot::Bot& bot, const std::string& dbPath) {

    bot.commands().on("start", "Powitanie i lista komend",
        [&bot](const telebot::CommandContext& c) {
            return "Czesc " + c.message.from.displayName() +
                   "! Jestem Grosznikiem.\n\n" + bot.commands().helpText();
        });

    bot.commands().on("pomoc", "Lista komend",
        [&bot](const telebot::CommandContext&) {
            return bot.commands().helpText();
        });

    // /stan — salda wszystkich kont
    bot.commands().on("stan", "Stan wszystkich kont",
        [dbPath](const telebot::CommandContext& c) -> std::string {
            Db db(dbPath);
            auto rows = db.query(
                "SELECT a.name, a.type, a.balance, a.currency, a.credit_limit "
                "FROM accounts a JOIN users u ON u.id = a.user_id "
                "WHERE u.telegram_chat_id=? AND a.is_active=1 "
                "ORDER BY a.type, a.name",
                {std::to_string(c.message.chat.id)});
            if (rows.empty())
                return "Brak kont. Zaloguj sie do aplikacji i dodaj konta.";
            std::ostringstream out;
            out << "Stan kont:\n\n";
            double total = 0;
            for (auto& r : rows) {
                double bal = r[2].empty() ? 0 : std::stod(r[2]);
                std::string icon = r[1]=="cash" ? "Gotowka"
                    : r[1]=="credit_card" ? "Karta kredytowa"
                    : r[1]=="savings"||r[1]=="deposit" ? "Oszczednosci" : "Konto";
                out << icon << " " << r[0] << ": " << fmt2(bal) << " " << r[3] << "\n";
                if (r[1]=="credit_card" && !r[4].empty()) {
                    double lim = std::stod(r[4]);
                    out << "  (dostepne: " << fmt2(lim-bal) << " " << r[3] << ")\n";
                }
                if (r[1] != "credit_card") total += bal;
            }
            out << "\nLaczne aktywa: " << fmt2(total) << " PLN";
            return out.str();
        });

    // /ile <kategoria>
    bot.commands().on("ile", "Wydatki w kategorii w tym miesiacu. /ile paliwo",
        [dbPath](const telebot::CommandContext& c) -> std::string {
            if (c.args.empty()) return "Uzycie: /ile <kategoria>";
            Db db(dbPath);
            std::string uid = [&](){
                auto r = db.query("SELECT id FROM users WHERE telegram_chat_id=?",
                                  {std::to_string(c.message.chat.id)});
                return r.empty() ? "" : r[0][0];
            }();
            if (uid.empty()) return "Nie znaleziono konta powiazanego z tym czatem.";

            time_t now = time(nullptr);
            struct tm ms = *localtime(&now);
            ms.tm_mday=1; ms.tm_hour=0; ms.tm_min=0; ms.tm_sec=0;
            time_t mstart = mktime(&ms);
            struct tm me = ms; me.tm_mon++;
            if (me.tm_mon==12){me.tm_mon=0;me.tm_year++;}
            time_t mend = mktime(&me);

            auto rows = db.query(
                "SELECT COALESCE(SUM(t.amount),0), t.currency "
                "FROM transactions t JOIN categories cat ON cat.id=t.category_id "
                "WHERE t.user_id=? AND t.type='expense' "
                "  AND t.date>=? AND t.date<? AND LOWER(cat.name) LIKE LOWER(?) "
                "GROUP BY t.currency",
                {uid, std::to_string((long long)mstart),
                 std::to_string((long long)mend), "%"+c.args+"%"});

            if (rows.empty()) return "Brak wydatkow na \"" + c.args + "\" w tym miesiacu.";
            std::ostringstream out;
            out << "Wydatki na \"" << c.args << "\" w tym miesiacu:\n";
            for (auto& r : rows) out << "  " << fmt2(std::stod(r[0])) << " " << r[1] << "\n";
            return out.str();
        });

    // /wyprawa <kwota> [opis]
    bot.commands().on("wyprawa", "Dodaj wydatek. /wyprawa 50 Biedronka",
        [dbPath](const telebot::CommandContext& c) -> std::string {
            if (c.args.empty()) return "Uzycie: /wyprawa <kwota> [opis]";
            Db db(dbPath);
            std::string uid = [&](){
                auto r = db.query("SELECT id FROM users WHERE telegram_chat_id=?",
                                  {std::to_string(c.message.chat.id)});
                return r.empty() ? "" : r[0][0];
            }();
            if (uid.empty()) return "Nie znaleziono konta.";

            std::istringstream iss(c.args);
            std::string amt_s, desc;
            iss >> amt_s; std::getline(iss, desc);
            if (!desc.empty() && desc[0]==' ') desc=desc.substr(1);

            double amount = 0;
            try { amount = std::stod(amt_s); } catch (...) {
                return "Nieprawidlowa kwota: " + amt_s;
            }
            if (amount <= 0) return "Kwota musi byc dodatnia.";

            auto acct = db.query(
                "SELECT id, currency FROM accounts "
                "WHERE user_id=? AND type='checking' AND is_active=1 LIMIT 1", {uid});
            if (acct.empty()) return "Brak konta biezacego. Dodaj konto w aplikacji.";
            std::string acct_id = acct[0][0], cur = acct[0][1];

            auto cat = db.query(
                "SELECT id FROM categories WHERE name='Inne wydatki' AND user_id IS NULL");
            std::string cat_id = cat.empty() ? "21" : cat[0][0];

            time_t now = time(nullptr);
            db.exec("INSERT INTO transactions(user_id,account_id,category_id,"
                    "type,amount,currency,date,description) VALUES(?,?,?,'expense',?,?,?,?)",
                    {uid,acct_id,cat_id,fmt2(amount),cur,
                     std::to_string((long long)now),
                     desc.empty()?"Wydatek przez Telegram":desc});
            db.exec("UPDATE accounts SET balance=balance-? WHERE id=?",
                    {fmt2(amount), acct_id});

            auto bal = db.query("SELECT balance,currency FROM accounts WHERE id=?",{acct_id});
            std::ostringstream out;
            out << "Dodano: " << fmt2(amount) << " " << cur;
            if (!desc.empty()) out << " - " << desc;
            if (!bal.empty())
                out << "\nSaldo konta: " << fmt2(std::stod(bal[0][0])) << " " << bal[0][1];
            return out.str();
        });

    bot.commands().on("ping", "Sprawdz czy bot dziala",
        [](const telebot::CommandContext&) -> std::string { return "pong"; });
}

} // namespace grosznik
