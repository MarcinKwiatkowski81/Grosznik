# 💰 Grosznik

Osobisty menedżer finansów z interfejsem webowym i opcjonalnym botem Telegram. Działa jako pojedynczy samowystarczalny proces — baza danych to plik SQLite, serwer HTTP jest wbudowany.

---

## Spis treści

- [Funkcje](#funkcje)
- [Architektura](#architektura)
- [Wymagania](#wymagania)
- [Szybki start](#szybki-start)
- [Konfiguracja](#konfiguracja)
- [Docker](#docker)
- [Pierwsze uruchomienie](#pierwsze-uruchomienie)
- [Bot Telegram](#bot-telegram)
- [Struktura projektu](#struktura-projektu)
- [REST API](#rest-api)
- [Schemat bazy danych](#schemat-bazy-danych)
- [Budowanie ręczne](#budowanie-ręczne)

---

## Funkcje

### Zarządzanie finansami
- **Konta** — bieżące (ROR), oszczędnościowe, lokaty, karty kredytowe, gotówka, inwestycje; śledzenie salda, limitów kredytowych i celów oszczędnościowych
- **Transakcje** — przychody, wydatki, przelewy, wypłaty ATM, spłaty kart; automatyczna aktualizacja sald
- **Zobowiązania stałe** — cykliczne płatności (czynsz, subskrypcje, raty); generowanie instancji miesięcznych, oznaczanie jako opłacone z opcją tworzenia transakcji
- **Kategorie** — hierarchiczne (kategoria → podkategoria), zestaw domyślnych kategorii systemowych, możliwość tworzenia własnych
- **Raporty** — cashflow (przychody vs. wydatki za N miesięcy), struktura wydatków wg kategorii, prognoza salda do końca miesiąca z dziennym wykresem

### Bot Telegram (opcjonalny)
- `/stan` — salda wszystkich kont
- `/ile <kategoria>` — wydatki w kategorii w bieżącym miesiącu
- `/wyprawa <kwota> [opis]` — szybkie dodanie wydatku przez Telegram
- `/pomoc` — lista komend
- Automatyczne powiadomienia: termin płatności za 3 dni, termin dzisiaj, alert niskiego salda, tygodniowy raport (poniedziałek 8:00)
- **Token bota konfigurowalny z poziomu aplikacji** — zakładka Ustawienia, bez edycji plików ani restartu serwera do konfiguracji

### Bezpieczeństwo
- JWT w httpOnly cookie (niedostępne z JavaScript)
- Hasła jako HMAC-SHA256 z solą
- Jeden użytkownik-właściciel (rejestracja tylko przy pustej bazie)
- `PRAGMA journal_mode=WAL` + `PRAGMA foreign_keys=ON`

---

## Architektura

```
┌─────────────────────────────────────────────────────┐
│                    grosznik (binarny)                │
│                                                      │
│  main.cpp ──► HTTPD (wbudowany serwer HTTP)          │
│               ├── lua_module.so   (wykonywanie .lua) │
│               └── grosznik.so    (C API dla Lua)     │
│                     ├── G.query()  → SQLite          │
│                     ├── G.exec()   → SQLite          │
│                     ├── G.jwt_sign/verify()          │
│                     └── G.hash/check_password()      │
│                                                      │
│  BotHandler.cpp + Notifier.cpp ──► Telebot           │
│  Schema.cpp ──► SQLite (inicjalizacja schematu)      │
└─────────────────────────────────────────────────────┘

Żądanie HTTP /api/accounts.lua:
  HTTPD → lua_module → accounts.lua
            ├── require('_util')     ← auth, helpers
            ├── require('_json')     ← enkoder/dekoder JSON
            └── require('grosznik') ← G.query/exec
```

**Jak działa `index.lhtml`:**

`GET /` → HTTPD → `lua_module` wykonuje `index.lhtml` → Lua pyta SQLite
o stan bazy i token bota → wstrzykuje `window.__GROSZNIK__ = {...}` do HTML
→ `app.js` czyta te dane synchronicznie zamiast robić dodatkowy `fetch()`.

**Zależności siostrzane** (repozytoria w tym samym katalogu nadrzędnym):
- `../HTTPD` — serwer HTTP z modułami dynamicznymi (zawiera `lua_module`)
- `../Telebot` — biblioteka klienta Telegram Bot API

Wszystkie API endpointy to pliki `.lua` w `www/api/`. Każdy plik obsługuje routing GET/POST/PUT/DELETE samodzielnie, bez frameworka.

---

## Wymagania

### Buildtime

| Pakiet | Debian/Ubuntu |
|---|---|
| Kompilator C++17 | `build-essential` |
| CMake ≥ 3.16 | `cmake` |
| OpenSSL | `libssl-dev` |
| SQLite 3 | `libsqlite3-dev` |
| Lua 5.4 | `liblua5.4-dev` |
| libcurl | `libcurl4-openssl-dev` |

```bash
sudo apt install build-essential cmake libssl-dev libsqlite3-dev \
                 liblua5.4-dev libcurl4-openssl-dev
```

### Runtime

```bash
sudo apt install libssl3 libsqlite3-0 liblua5.4-0 libcurl4
```

### Narzędzia pomocnicze
- Python 3 — parsowanie `config.json` przez `build_and_run.sh`

---

## Szybki start

Repozytoria muszą leżeć obok siebie:

```
~/Projects/
├── HTTPD/
├── Telebot/
└── Grosznik/
```

```bash
# 1. Wygeneruj klucz JWT
openssl rand -hex 32

# 2. Wpisz go do config.json jako "jwt_secret"
nano config.json

# 3. Zbuduj i uruchom
bash build_and_run.sh
# → http://localhost:8080
```

Token bota Telegram konfiguruje się po zalogowaniu w **Ustawienia → Bot Telegram**.
Nie trzeba edytować plików — token jest zapisany w bazie i wczytywany przy starcie.

---

## Konfiguracja

`build_and_run.sh` parsuje `config.json` i eksportuje zmienne środowiskowe przed uruchomieniem.

```jsonc
{
  "db_path":    "./data/grosznik.db", // plik SQLite (tworzony automatycznie)
  "www_root":   "./www",
  "port":       8080,
  "jwt_secret": "change_me",          // ZMIEŃ: openssl rand -hex 32

  "httpd": {
    "workers": 1,
    "threads_per_worker": 4
  },

  "modules": {
    "lua":      "./build/modules/lua_module.so",
    "grosznik": "./build/modules/grosznik.so"
  },

  "telegram": {
    "bot_token":     "",   // puste = bot wyłączony
    "allowed_users": [],  // Chat ID z dostępem; [] = wszyscy
    "offset_file":   "./data/tg_offset"
  },

  "build": {
    "httpd_dir":   "../HTTPD",
    "telebot_dir": "../Telebot",
    "jobs": 0   // 0 = auto-detect
  }
}
```

### Zmienne środowiskowe

| Zmienna | Domyślna | Opis |
|---|---|---|
| `GROSZNIK_DB` | `./data/grosznik.db` | Ścieżka do bazy SQLite |
| `GROSZNIK_WWW` | `./www` | Katalog dokumentów HTTP |
| `GROSZNIK_PORT` | `8080` | Port nasłuchu |
| `JWT_SECRET` | `change_me` | Sekret JWT — **zmień na produkcji!** |
| `GROSZNIK_WORKERS` | `1` | Liczba workerów HTTPD |
| `GROSZNIK_THREADS` | `4` | Wątki I/O na worker |
| `GROSZNIK_LUA_MODULE` | *(auto)* | Ścieżka do `lua_module.so` |
| `GROSZNIK_MODULE` | *(auto)* | Ścieżka do `grosznik.so` |
| `TELEGRAM_BOT_TOKEN` | *(puste)* | Token bota Telegram |
| `TELEGRAM_ALLOWED_USERS` | *(puste)* | Dozwolone Chat ID (CSV) |
| `LUA_PATH` | *(auto)* | Ścieżki modułów Lua |
| `LUA_CPATH` | *(auto)* | Ścieżki modułów C dla Lua |

---

## Docker

Kontekst budowania to katalog **nadrzędny** (zawiera wszystkie trzy repozytoria):

```bash
cd ~/Projects

# docker compose (zalecane)
JWT_SECRET=$(openssl rand -hex 32) \
TELEGRAM_BOT_TOKEN="twój_token" \
docker compose -f Grosznik/docker-compose.yml up -d

# lub ręcznie
docker build -f Grosznik/Dockerfile -t grosznik .
docker run -d --name grosznik -p 8080:8080 \
  -v grosznik_data:/data \
  -e JWT_SECRET="$(openssl rand -hex 32)" \
  grosznik
```

Dane (SQLite) są w volume `grosznik_data` → `/data` wewnątrz kontenera.

> **Uwaga:** `docker-compose.yml` używa `context: ..` — Dockerfile potrzebuje dostępu do `HTTPD/`, `Telebot/` i `Grosznik/` jednocześnie podczas budowania.

---

## Pierwsze uruchomienie

1. Otwórz `http://localhost:8080`
2. Pojawia się formularz **„Pierwsze uruchomienie"** — podaj login, e-mail i hasło (min. 8 znaków)
3. Kliknij **„Utwórz konto"** — zostajesz zalogowany
4. Dodaj konto bankowe: **Konta → + Dodaj konto**

> Rejestracja działa tylko przy pustej bazie. Grosznik jest przeznaczony dla jednej osoby / gospodarstwa domowego.

### Reset (zapomniane hasło)

```bash
rm data/grosznik.db
bash build_and_run.sh --run-only
```

### Opcje `build_and_run.sh`

```bash
bash build_and_run.sh              # buduj + uruchom
bash build_and_run.sh prod.json    # własny plik konfiguracji
bash build_and_run.sh --build-only # tylko kompilacja
bash build_and_run.sh --run-only   # tylko uruchomienie
bash build_and_run.sh --help
```

---

## Bot Telegram

### Konfiguracja

**Sposób zalecany — przez interfejs aplikacji (bez edycji plików):**

1. [@BotFather](https://t.me/BotFather) → utwórz bota → skopiuj token
2. Zaloguj się do Grosznika, przejdź do **Ustawienia → Bot Telegram**
3. Wklej token, kliknij **Zapisz token** → token trafia do `app_settings` w bazie
4. Zrestartuj serwer: `bash build_and_run.sh --run-only`
5. Swoje Chat ID znajdź u [@userinfobot](https://t.me/userinfobot)
6. Wpisz Chat ID w **Ustawienia → Twoje konto Telegram**, kliknij **Zapisz Chat ID**
7. Kliknij **Wyślij wiadomość testową** — weryfikuje działanie bota

**Sposób alternatywny — przez zmienną środowiskową (jak poprzednio):**

Ustaw `TELEGRAM_BOT_TOKEN` w `config.json` lub środowisku. Token z bazy ma **wyższy priorytet** — jeśli jest w `app_settings`, env var jest ignorowana.

Opcjonalnie: ogranicz dostęp do komend bota przez `telegram.allowed_users` w `config.json`.

### Komendy

| Komenda | Opis |
|---|---|
| `/start` | Powitanie |
| `/pomoc` | Lista komend |
| `/stan` | Salda wszystkich aktywnych kont |
| `/ile <kategoria>` | Wydatki w kategorii w bieżącym miesiącu, np. `/ile paliwo` |
| `/wyprawa <kwota> [opis]` | Dodaj wydatek na konto bieżące, np. `/wyprawa 45.50 Biedronka` |
| `/ping` | Test połączenia |

### Automatyczne powiadomienia

Wątek `Notifier` sprawdza co 15 minut:

| Zdarzenie | Kiedy |
|---|---|
| Przypomnienie o płatności | 3 dni przed terminem |
| Powiadomienie o terminie | W dniu płatności |
| Alert niskiego salda | Saldo konta bieżącego < próg (domyślnie 500 PLN) |
| Raport tygodniowy | Poniedziałek 8:00 — przychody / wydatki / bilans za 7 dni |

---

## Struktura projektu

```
Grosznik/
├── src/
│   ├── main.cpp          # Entry point: HTTPD + Telebot
│   ├── Schema.cpp        # Schemat SQLite + domyślne kategorie
│   ├── BotHandler.cpp    # Komendy bota (/stan, /ile, /wyprawa ...)
│   └── Notifier.cpp      # Wątek powiadomień
│
├── modules/grosznik/
│   └── grosznik_module.cpp  # Moduł HTTPD z Lua C API:
│                            #   G.query(), G.exec(), G.now()
│                            #   G.jwt_sign(), G.jwt_verify()
│                            #   G.hash_password(), G.check_password()
│
├── include/              # Nagłówki Schema.h, BotHandler.h, Notifier.h
│
├── www/
│   ├── index.lhtml          # SPA shell (Lua: wstrzykuje boot data przy renderze)
│   ├── assets/
│   │   ├── app.css          # Ciemny motyw (CSS custom properties)
│   │   └── app.js           # Frontend (vanilla JS, bez frameworka)
│   └── api/
│       ├── _json.lua        # Enkoder/dekoder JSON (pure Lua)
│       ├── _util.lua        # Helpers: auth(), body(), param(), ok(), err()
│       ├── auth.lua         # Logowanie, rejestracja, profil, JWT
│       ├── accounts.lua     # CRUD kont
│       ├── categories.lua   # CRUD kategorii
│       ├── transactions.lua # CRUD transakcji + aktualizacja sald
│       ├── obligations.lua  # CRUD zobowiązań + instancje miesięczne
│       ├── reports.lua      # Cashflow, kategorie, prognoza
│       └── settings.lua     # Ustawienia aplikacji (token bota Telegram)
│
├── CMakeLists.txt
├── build_and_run.sh
├── config.json
├── Dockerfile
└── docker-compose.yml
```

---

## REST API

Wszystkie endpointy wymagają cookie `grosznik_jwt` (httpOnly JWT), poza `setup_status`, `login` i `register`.

Odpowiedzi: zawsze `application/json`. Błędy: `{"error": "opis"}` + kod 4xx/5xx.

### `/api/auth.lua`

| Metoda | `?action=` | Opis |
|---|---|---|
| `GET` | `setup_status` | `{"needs_setup": bool}` |
| `POST` | `login` | `{username, password}` → cookie JWT 24h |
| `POST` | `register` | `{username, email, password}` → tylko przy pustej bazie |
| `POST` | `logout` | Kasuje cookie |
| `GET` | `me` | Profil zalogowanego użytkownika |
| `PUT` | `profile` | `{telegram_chat_id?, default_currency?, balance_alert_threshold?, new_password?}` |

### `/api/accounts.lua`

| Metoda | Parametry | Opis |
|---|---|---|
| `GET` | — | Lista kont z `available_credit`, `goal_pct` |
| `GET` | `?id=N` | Konto + 20 ostatnich transakcji |
| `POST` | body | Utwórz. Wymagane: `name`, `type`, `currency` |
| `PUT` | `?id=N` | Aktualizuj dowolne pola |
| `DELETE` | `?id=N` | Dezaktywuj (`is_active=0`) |

Typy: `checking` · `savings` · `deposit` · `credit_card` · `cash` · `investment`

### `/api/transactions.lua`

| Metoda | Parametry | Opis |
|---|---|---|
| `GET` | filtry | Lista. Filtry: `account_id`, `type`, `category_id`, `date_from`, `date_to`, `limit` (def. 50), `offset` |
| `GET` | `?id=N` | Jedna transakcja |
| `POST` | body | Utwórz. Wymagane: `account_id`, `type`, `amount`, `date` (Unix timestamp) |
| `DELETE` | `?id=N` | Usuń + odwróć zmianę salda |

Typy: `income` · `expense` · `transfer` · `card_payment` · `atm`

### `/api/categories.lua`

| Metoda | Opis |
|---|---|
| `GET` | Systemowe + własne. Filtr: `?type=income\|expense\|transfer` |
| `POST` | `{name, type, parent_id?, icon?, color?}` |
| `PUT ?id=N` | `{name?, icon?, color?}` |
| `DELETE ?id=N` | Usuń własną |

### `/api/obligations.lua`

**Szablony:**

| Metoda | Opis |
|---|---|
| `GET` | Aktywne szablony |
| `POST` | `{name, amount, account_id, payment_day, currency?, frequency?, category_id?}` |
| `PUT ?id=N` | Dowolne pola |
| `DELETE ?id=N` | Dezaktywuj |

**Instancje** (`?sub=instances`):

| Metoda | Parametry | Opis |
|---|---|---|
| `GET` | `?sub=instances&year=Y&month=M` | Instancje na miesiąc |
| `POST` | `?sub=instances&id=N&action=pay` | Opłać. Body: `{create_transaction?, account_id?}` |

### `/api/reports.lua`

| `?report=` | Parametry | Opis |
|---|---|---|
| `cashflow` | `?months=N` (def. 6) | `[{year, month, label, income, expense}]` |
| `categories` | `?year=Y&month=M` | `[{name, color, icon, total}]` |
| `forecast` | — | `{current_balance, pending_costs, expected_income, projected_eom, forecast_points[]}` |

### `/api/settings.lua` — ustawienia aplikacji

| Metoda | Parametry | Opis |
|---|---|---|
| `GET` | — | `{telegram_bot_token_set, telegram_bot_token_hint}` — nigdy nie zwraca pełnego tokenu |
| `PUT` | body | `{telegram_bot_token?, notify_on_low_balance?}` — zapisuje w tabeli `app_settings` |
| `POST` | `?action=test_telegram` | Wysyła testową wiadomość na Chat ID użytkownika przez skonfigurowanego bota |

Token bota jest przechowywany w `app_settings` i odczytywany przy starcie serwera
(priorytet nad zmienną `TELEGRAM_BOT_TOKEN`). Zmiana wymaga restartu serwera.

---

## Schemat bazy danych

```
users
  id, username UNIQUE, email UNIQUE, password_hash
  telegram_chat_id, default_currency, timezone
  balance_alert_threshold REAL, notify_telegram INTEGER, created_at INTEGER

accounts
  id, user_id → users CASCADE
  name, type CHECK(...), currency, balance REAL
  interest_rate, savings_goal, savings_goal_name   -- savings/deposit
  credit_limit, billing_day, payment_due_days      -- credit_card
  is_active INTEGER, created_at INTEGER

categories
  id, user_id → users (NULL = systemowa), parent_id → categories
  name, type CHECK(...), icon, color

transactions
  id, user_id → users CASCADE
  account_id → accounts, to_account_id → accounts  -- transfer/atm
  category_id → categories
  type CHECK(...), amount REAL, currency
  date INTEGER (Unix ts), description, tags, is_pending INTEGER

obligations
  id, user_id → users CASCADE, account_id → accounts
  name, amount REAL, currency, frequency CHECK(...), payment_day
  category_id → categories, is_active INTEGER

obligation_instances
  id, obligation_id → obligations CASCADE, user_id → users CASCADE
  period_year, period_month, due_date INTEGER, amount REAL
  status CHECK('pending'|'paid'|'overdue')
  paid_at, transaction_id → transactions
  notified_3days, notified_due INTEGER
  UNIQUE(obligation_id, period_year, period_month)

notification_log
  id, user_id, type, channel, message, sent_at INTEGER, status

app_settings
  key TEXT PRIMARY KEY, value TEXT, updated_at INTEGER
  -- Przechowuje: telegram_bot_token, notify_on_low_balance, ...
```

`PRAGMA journal_mode=WAL` — bezpieczna współbieżność przy wielu wątkach I/O.
`PRAGMA foreign_keys=ON` — integralność referencyjna egzekwowana przez SQLite.

---

## Budowanie ręczne

```bash
# 1. HTTPD
cd ../HTTPD
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(nproc)

# 2. Telebot
cd ../Telebot
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(nproc)

# 3. Grosznik
cd ../Grosznik
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DHTTPD_DIR=../HTTPD -DTELEBOT_DIR=../Telebot
cmake --build build -j$(nproc)

# 4. Uruchom
export GROSZNIK_DB=./data/grosznik.db
export GROSZNIK_WWW=./www
export JWT_SECRET=$(openssl rand -hex 32)
export LUA_PATH="./www/api/?.lua;./www/api/?/init.lua;./?.lua"
export LUA_CPATH="./build/modules/?.so"
export GROSZNIK_LUA_MODULE=../HTTPD/build/modules/lua_module.so
export GROSZNIK_MODULE=./build/modules/grosznik.so
mkdir -p data && ./build/grosznik
```

### Produkty kompilacji

| Plik | Opis |
|---|---|
| `build/grosznik` | Główna binarka (HTTP + Telebot) |
| `build/modules/grosznik.so` | Moduł HTTPD z Lua C API |
| `../HTTPD/build/modules/lua_module.so` | Interpreter Lua dla HTTPD |

---

## Licencja

Projekt prywatny. Wszelkie prawa zastrzeżone.
