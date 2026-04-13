# Discord Integration Setup

The Rails API supports two methods for Discord notifications.

**Bot Name:** Messages will appear from "Leviathan" (webhook) or the bot's registered name (bot token method).

## Method 1: Discord Bot (Recommended)

**Pros:**
- More reliable
- Better rate limiting
- Can target specific channels
- Full Discord API access

**Setup:**

1. **Create Bot Application** (if not already done):
   - Go to https://discord.com/developers/applications
   - Create new application or select existing "tiverton" bot
   - Go to "Bot" section
   - Copy the bot token

2. **Get Channel IDs**:
   - Enable Developer Mode in Discord (User Settings → Advanced → Developer Mode)
   - Right-click on #trading-floor channel → Copy ID
   - Right-click on #infra channel → Copy ID

3. **Update .env file**:
   ```bash
   DISCORD_BOT_TOKEN=your_bot_token_here
   DISCORD_TRADING_FLOOR_CHANNEL_ID=1464509330731696213
   DISCORD_INFRA_CHANNEL_ID=1464796137893662843
   ```

4. **Restart Rails API**:
   ```bash
   cd ~/trading-api
   rails server  # or restart Docker container
   ```

## Method 2: Webhooks (Simpler)

**Pros:**
- No bot application needed
- Simpler setup

**Cons:**
- Less reliable
- Stricter rate limits
- Less flexible

**Setup:**

1. **Create Webhooks**:
   - Go to #trading-floor channel settings → Integrations → Webhooks
   - Create webhook (name it "Trading Floor Bot")
   - Copy webhook URL
   - Repeat for #infra channel

2. **Update .env file**:
   ```bash
   DISCORD_TRADING_FLOOR_WEBHOOK=https://discord.com/api/webhooks/...
   DISCORD_INFRA_WEBHOOK=https://discord.com/api/webhooks/...
   ```

3. **Restart Rails API**

## Testing

Test Discord delivery from Rails console:

```ruby
# Test trading floor channel
DiscordService.post_to_trading_floor(
  content: "[TEST] Discord integration working!"
)

# Test infra channel
DiscordService.post_to_infra(
  content: "[TEST] Infrastructure notifications enabled"
)

# Test via job (async)
trade = Trade.last
DiscordNotificationJob.perform_now(trade.id, :filled)
```

## Usage in Code

```ruby
# Synchronous (blocks until delivery)
DiscordService.post_to_trading_floor(
  content: "[FILLED] Trade completed",
  embed: { title: "Details", description: "..." }  # optional
)

# Async (via Sidekiq job - recommended)
DiscordNotificationJob.perform_later(trade.id, :filled)
DiscordNotificationJob.perform_later(trade.id, :approved, channel: :infra)
```

## Submission Remediation Alerts (Duplicate/Exception Guard)

When duplicate submission guards or execution-submission exceptions are triggered, Rails can notify:
- A designated OpenClaw agent (for remediation workflow)
- A configurable Discord channel (for visibility/triage)

Optional `.env` settings:

```bash
# Enable/disable routing (default: true)
SUBMISSION_REMEDIATION_ENABLED=true

# OpenClaw agent to receive remediation messages (default: tiverton)
SUBMISSION_REMEDIATION_AGENT=tiverton

# Discord channel ID for remediation alerts (default: DISCORD_INFRA_CHANNEL_ID, then infra fallback)
SUBMISSION_REMEDIATION_DISCORD_CHANNEL_ID=1464796137893662843

# Duplicate detection window in seconds for identical submissions (default: 300)
TRADE_DUPLICATE_WINDOW_SECONDS=300

# Alert dedupe window (default: 120)
SUBMISSION_REMEDIATION_THROTTLE_SECONDS=120
```

## Notification Events

The job supports these event types:
- `:filled` - Trade fully executed
- `:partial` - Partial fill
- `:failed` - Execution failed
- `:approved` - Trade approved by Tiverton
- `:denied` - Trade denied
- `:cancelled` - Trade cancelled

## Current Configuration

Check logs on startup:
```
[DISCORD] Bot configured: trading_floor=1464509330731696213, infra=1464796137893662843
```

Or:
```
[DISCORD] Webhook configured for trading_floor
```

If neither:
```
[DISCORD] No Discord configuration found. Set DISCORD_BOT_TOKEN + channel IDs OR webhook URLs in .env
```
