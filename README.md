# Local Web Buttons Bridge for MiladTradeManager

This repo now includes a local web bridge so you can select a stack (symbol) in the website, click action buttons, and trigger the equivalent EA actions in **MiladTradeManager.mq5**.

## What was added

- `web/index.html`: local UI with stack tabs and action buttons matching the EA panel.
- `local_bridge_server.py`: lightweight Python server that:
  - serves the web UI,
  - accepts commands from the UI,
  - exposes a queue endpoint that the EA polls.
- `MiladTradeManager.mq5`: optional polling bridge for external commands.

## Command mapping

| Stack | Website command | EA action |
|---|---|---|
| `XAUUSD`, `XAGUSD`, `US30`, `US500`, `USTEC`, `NAS100` | `buy` | AUTO BUY |
| `XAUUSD`, `XAGUSD`, `US30`, `US500`, `USTEC`, `NAS100` | `sell` / `sale` | AUTO SELL / SALE |
| `XAUUSD`, `XAGUSD`, `US30`, `US500`, `USTEC`, `NAS100` | `rescue` | RESCUE $10 |
| `XAUUSD`, `XAGUSD`, `US30`, `US500`, `USTEC`, `NAS100` | `close50` | CLOSE 50% |
| `XAUUSD`, `XAGUSD`, `US30`, `US500`, `USTEC`, `NAS100` | `close30` | CLOSE 30% |
| `XAUUSD`, `XAGUSD`, `US30`, `US500`, `USTEC`, `NAS100` | `get100` | GET $100 |

## Run locally

1. Start the local server:

```bash
python3 local_bridge_server.py
```

2. Open the page:

- http://127.0.0.1:8000/
- Select a stack tab first, then click action buttons.

3. In MetaTrader 5, for `MiladTradeManager` inputs, set:

- `EnableLocalWebBridge = true`
- `LocalBridgeUrl = http://127.0.0.1:8000/api/command/next`
- `BridgePollSeconds = 1`

4. In MT5 settings, allow WebRequest URL:

- `http://127.0.0.1:8000`

Without this whitelist step, WebRequest will fail.

## Notes

- This is designed for localhost usage only.
- Commands are queued in-memory by the Python process.
- Restarting the Python server clears any pending queued commands.
- Each queued command now includes both `command` and `stack` so the EA knows which symbol to trade/manage.
