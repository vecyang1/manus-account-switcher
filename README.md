# Manus Account Switcher

CLI tool to manage multiple [Manus AI](https://manus.im) desktop accounts on macOS. Switch between accounts without logging out, check live credit balances, and auto-checkin daily.

<img width="628" height="517" alt="iTerm2 2026-04-02 18 25 37" src="https://github.com/user-attachments/assets/87b91996-0e4e-423b-b1b2-27b328db7bcb" />

<img width="1280" height="840" alt="WeChat 2026-04-02 18 32 11" src="https://github.com/user-attachments/assets/de1bb2b0-12c3-4414-bdb7-3cc64993b8d6" />


<img width="603" height="766" alt="image" src="https://github.com/user-attachments/assets/58a1d194-90fa-49e5-949b-016cf505bb3e" />


## How it works

Manus Desktop is an Electron app. Each "profile" gets its own isolated `--user-data-dir`, meaning separate login sessions, cookies, and settings — like running two different browsers. Your original account is never touched.

## Features

- **Multi-profile management** — add/remove/switch accounts freely
- **Live credit balance** — via reverse-engineered Manus gRPC-JSON API (`GetAvailableCredits`)
- **Account info** — plan type, subscription status, renewal date, token expiry
- **Credentials in macOS Keychain** — passwords never stored in plaintext
- **Daily auto-checkin** — cron job pings all accounts after daily credit refresh
- **Side-by-side mode** — run multiple accounts simultaneously
- **"My Computer" deviceId sync** — shared device identity across profiles

## Install

```bash
# Clone
git clone https://github.com/vecyang1/manus-account-switcher.git
cd manus-account-switcher

# Add alias to your shell
echo 'alias manus="\"'$(pwd)'/manus-switch.sh\""' >> ~/.zshrc
echo 'alias mn="manus"' >> ~/.zshrc
source ~/.zshrc
```

## Usage

```bash
mn                  # Interactive menu
mn list             # List all profiles with live credits
mn credits          # Quick credit check (one line per account)
mn info 1           # Detailed account info
mn cred 1           # Show stored credentials

mn 2                # Open profile #2 in new window (keeps current)
mn s1               # Switch: close all, open profile #1

mn add "email@example.com" "password" "name" "description"
mn rm <name>        # Unregister (keeps data)
mn purge <name>     # Remove everything

mn checkin          # Ping all accounts (triggers activity)
mn cron             # Setup daily auto-checkin at 13:12
mn watch            # Auto-refresh credit display every 30s
mn watch 10         # Every 10s
```

## Manus API (reverse-engineered)

Credits and account info are fetched via Manus's internal gRPC-JSON API:

```bash
# Get credit balance
curl -s -X POST "https://api.manus.im/user.v1.UserService/GetAvailableCredits" \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" -d '{}'

# Get account info (plan, subscription, renewal)
curl -s -X POST "https://api.manus.im/user.v1.UserService/UserInfo" \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" -d '{}'
```

JWT tokens are stored in `~/Library/Application Support/Manus/localStorage.json`.

## Requirements

- macOS (uses `open -n -a`, `security` keychain, `osascript`)
- Manus Desktop (Electron-based)
- Python 3.8+

## License

MIT
