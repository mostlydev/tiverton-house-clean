# Trading API Admin Interface

A distinctive **Terminal Brutalism** themed admin interface for managing and viewing trading system data.

## Access

**URL:** `http://localhost:4000/admin` (or `http://<server-ip>:4000/admin` when bound to 0.0.0.0)

**Credentials:**
- Username: `admin`
- Password: `trading2026`

**⚠️ IMPORTANT:** Change the default password in `app/controllers/admin/base_controller.rb` before deploying to production. Move credentials to environment variables or Rails encrypted credentials.

## Features

### Dashboard (`/admin`)
System overview with key metrics:
- Total trades, agents, positions, wallets
- Ledger entries, broker fills, outbox events
- Recent trades list

### Core Data Views

#### Trades (`/admin/trades`)
- List all trades with filtering by status and agent
- View individual trade details including:
  - Trade metadata (ticker, side, quantities, prices)
  - Status history
  - Thesis/reasoning
  - Trade events timeline

#### Agents (`/admin/agents`)
- View all trading agents
- Agent detail pages showing:
  - Wallet information
  - Open positions
  - Recent trade history

#### Positions (`/admin/positions`)
- All open positions across agents
- Position details with lot tracking
- Real-time P&L calculations

#### Wallets (`/admin/wallets`)
- Wallet balances for all agents
- Cash, invested amounts, wallet size
- Recent ledger entries

### System Views

#### Outbox Events (`/admin/outbox`)
- Event-sourced outbox pattern monitoring
- Filter by status and event type
- View event payloads and error messages

## Design Philosophy

The admin interface uses a **Terminal Brutalism** aesthetic:
- Dark theme with high contrast
- Monospace headers (Courier New) for a terminal feel
- Bold geometric layouts with sharp edges
- Data-dense tables with excellent typography
- Color coding:
  - Cyan: Primary accents, links, headers
  - Green: Success states, positive P&L
  - Red: Errors, negative P&L
  - Yellow: Warnings, in-progress states
  - Purple: System events

## Technical Details

- **Framework:** Rails 7.2 with Hotwire (Turbo + Stimulus)
- **Authentication:** HTTP Basic Auth
- **Layout:** `app/views/layouts/admin.html.erb`
- **Controllers:** `app/controllers/admin/`
- **Base Controller:** Inherits from `ActionController::Base` (not API mode)
- **CSRF Protection:** Enabled
- **Pagination:** Currently limited to 100-200 records per page (no pagination gem)

## Known Limitations

- **No pagination controls:** Results are limited but not paginated
- **Some system pages incomplete:** Ledger and Broker activity pages may have display issues
- **No search functionality:** Use browser's find-in-page
- **Read-only:** No data modification capabilities (by design)

## Security Notes

1. **Change default credentials immediately**
2. Admin interface bypasses the API-only restriction on ApplicationController
3. When exposing externally, use a reverse proxy to restrict `/admin` access
4. Consider IP whitelisting for admin access
5. HTTPS strongly recommended for production use

## Future Enhancements

- Add kaminari gem for proper pagination
- Search and advanced filtering
- Export functionality (CSV/JSON)
- Real-time updates via Turbo Streams
- Additional system monitoring views
- Role-based access control
