#pragma once
#include <telebot/Bot.h>
#include <string>
namespace grosznik {
    void registerBotCommands(telebot::Bot& bot, const std::string& dbPath);
}
