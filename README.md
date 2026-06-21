# Codex Model Switcher

A small macOS menu bar app for managing Codex model provider configurations.

The app helps you add, edit, and switch between Codex providers such as OpenAI, OpenRouter, DeepSeek, or other OpenAI-compatible services. It writes the selected model and provider settings to `~/.codex/config.toml`, stores app data in `~/.codex/model-switcher.json`, and can manage provider API keys and saved OpenAI account credentials.

## Features

- Add, edit, and delete custom model providers.
- Manage multiple models per provider.
- Switch the active Codex model from the menu bar.
- Manage multiple OpenAI accounts.
- Write Codex config updates automatically.
- Keep the app menu-bar only, without a Dock icon.

## Notes

Codex may need to be restarted after changing provider, model, or OpenAI account settings.

API keys and OpenAI credentials are sensitive. Treat files under `~/.codex/` like secrets.

## License

MIT License.
