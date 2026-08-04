# LocalShare Roadmap

## Android Clipboard to Temp Chat

Status: implemented.

Behavior:

- Android-only.
- Web-side copy actions are not monitored.
- The settings page has a `监听手机剪贴板` toggle, enabled by default for existing and new installs.
- While LocalShare's backend service is running, useful Android system clipboard text is appended to temporary chat as messages from `手机剪贴板`.
- Clipboard messages are not automatically created as cards.
- No popup is shown for each clipboard event; the home address panel shows a small chat entry with an unread dot.
- Temporary chat can copy, delete, save as card, and clear messages.
- Repeated copy actions of the same text are distinguished with Android clipboard timestamps when available.

Noise controls:

- Ignore very short content.
- Avoid capturing likely passwords or verification codes by default.
- Do not recapture content copied from LocalShare itself.
- When a private WeChat article extraction endpoint is configured at build time, copied WeChat article links are fetched into temporary chat.
- The private endpoint is injected with `--dart-define=WECHAT_ARTICLE_API_BASE_URL=...` via ignored local build config and is not committed.
