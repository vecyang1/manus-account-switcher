# Manus Account Switcher

CLI tool to manage multiple [Manus AI](https://manus.im) desktop accounts on macOS. Switch between accounts without logging out, check live credit balances, and auto-checkin daily.


<img width="621" height="513" alt="image" src="https://github.com/user-attachments/assets/28e71217-5d8f-4ecd-aa0d-21eb07621afc" />


<img width="1280" height="840" alt="WeChat 2026-04-02 18 32 11" src="https://github.com/user-attachments/assets/de1bb2b0-12c3-4414-bdb7-3cc64993b8d6" />




## How it works

Manus Desktop is an Electron app. Each "profile" gets its own isolated `--user-data-dir`, meaning separate login sessions, cookies, and settings — like running two different browsers. Your original account is never touched.

## Features

- **Multi-profile management** — add/remove/switch accounts freely
- **Live credit balance** — via reverse-engineered Manus gRPC-JSON API (`GetAvailableCredits`)
- **Account info** — plan type, subscription status, renewal date, token expiry
- **Credentials in macOS Keychain** — passwords never stored in plaintext
- **Knowledge sync** — export/import/sync learned preferences across accounts
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

mn kn               # Show knowledge entries for all accounts
mn kn 1             # Show knowledge for profile #1
mn kexport 1        # Export knowledge to JSON file
mn kimport 2 file   # Import knowledge from JSON into profile #2
mn ksync 1          # Sync knowledge from #1 → all other profiles
mn kdedup           # Remove duplicate knowledge entries (all profiles)
mn kdedup 1         # Remove duplicates for profile #1 only
mn krm 1 "name"     # Delete a specific knowledge entry by name
```

> **Auto-sync**: When you switch profiles with `mn s<N>`, knowledge is automatically synced from the profile with the most entries. New accounts inherit your learned context without any manual steps.

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

### Knowledge API (reverse-engineered)

```bash
# List all knowledge entries
curl -s -X POST "https://api.manus.im/knowledge.v1.KnowledgeService/ListKnowledge" \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" -d '{"limit": 100}'

# Create a knowledge entry
curl -s -X POST "https://api.manus.im/knowledge.v1.KnowledgeService/CreateKnowledge" \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"...", "content":"...", "trigger":"..."}'

# Delete a knowledge entry
curl -s -X POST "https://api.manus.im/knowledge.v1.KnowledgeService/DeleteKnowledge" \
  -H "Authorization: Bearer <jwt_token>" \
  -H "Content-Type: application/json" -d '{"uid":"..."}'
```

## Requirements

- macOS (uses `open -n -a`, `security` keychain, `osascript`)
- Manus Desktop (Electron-based)
- Python 3.8+

## License

MIT
