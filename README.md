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

To access from your phone on the same Wi‑Fi, bind to all interfaces:

```bash
BRIDGE_HOST=0.0.0.0 python3 local_bridge_server.py
```

Then open `http://<your-pc-lan-ip>:8000/` on the phone.

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

## Troubleshooting queued commands that never execute

If the website says commands are queued but no action happens in MT5:

1. Confirm EA input `EnableLocalWebBridge` is `true`.
2. Confirm `LocalBridgeUrl` is exactly `http://127.0.0.1:8000/api/command/next`.
3. In **MT5 → Tools → Options → Expert Advisors**, add `http://127.0.0.1:8000` to allowed WebRequest URLs.
4. Keep the EA attached and AutoTrading enabled.

The web status panel now warns when EA polling is not detected recently, which usually means one of the settings above is missing.

## Notes

- This is designed for localhost usage only.
- If you bind with `BRIDGE_HOST=0.0.0.0`, your LAN can reach the UI/API on port `8000`; use only on trusted networks.
- Commands are queued in-memory by the Python process.
- Restarting the Python server clears any pending queued commands.
- Each queued command now includes both `command` and `stack` so the EA knows which symbol to trade/manage.
