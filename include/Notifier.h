#pragma once
#include <telebot/Bot.h>
#include <string>
#include <atomic>
namespace grosznik {
    void notifierThread(telebot::Bot& bot,
                        const std::string& dbPath,
                        std::atomic<bool>& running);
}
