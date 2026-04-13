Rails.application.routes.draw do
  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Dashboard (root)
  root "dashboard#index"

  # Dashboard Turbo Frame endpoints
  get "dashboard/portfolio_bar"
  get "dashboard/positions"
  get "dashboard/trading_floor"
  get "dashboard/news_ticker"

  # Secondary pages
  get "trader/:name", to: "traders#show", as: :trader
  get "trader/:name/ledger", to: "traders#ledger", as: :trader_ledger
  get "research/:ticker", to: "research#show", as: :research
  get "notes/:agent/:ticker", to: "notes#show", as: :notes
  get "docs/risk-management", to: "docs#risk_management"

  # Admin
  namespace :admin do
    root to: "dashboard#index"
    resources :trades, only: [:index, :show]
    resources :agents, only: [:index, :show]
    resources :positions, only: [:index, :show]
    resources :wallets, only: [:index, :show]

    get "ledger", to: "ledger#index"
    get "ledger/transactions", to: "ledger#transactions"
    get "ledger/adjustments", to: "ledger#adjustments"

    get "broker/fills", to: "broker#fills"
    get "broker/orders", to: "broker#orders"
    get "broker/events", to: "broker#events"
    get "broker/activity", to: "broker#activity"
    resources :outbox, only: [:index, :show]
  end

  # API v1
  namespace :api do
    namespace :v1 do
      local_only = lambda do |request|
        ip = request.remote_ip.to_s
        request.local? ||
          ip == "127.0.0.1" ||
          ip == "::1" ||
          ip.start_with?("10.") ||
          ip.start_with?("192.168.") ||
          ip.match?(/\A172\.(1[6-9]|2[0-9]|3[0-1])\./)
      end

      # System
      get 'health', to: 'system#health'
      get 'status', to: 'system#status'

      # Agents
      resources :agents, only: [:index, :show] do
        member do
          get :realized_pnl
        end
      end

      # Wallets
      resources :wallets, only: [:index, :show]

      # Positions
      resources :positions, only: [:index, :show]

      # Market context
      get 'market_context/:agent_id', to: 'market_context#show'
      get 'momentum_context/:agent_id', to: 'momentum_context#show'
      get 'value_context/:agent_id', to: 'value_context#show'
      get 'desk_risk_context/:agent_id', to: 'desk_risk_context#show'
      get 'desk_performance_context/:agent_id', to: 'desk_performance_context#show'

      # Quotes (live price lookup for any ticker)
      get 'quotes/:ticker', to: 'quotes#show'

      # Trades
      resources :trades, only: [:index, :show] do
        collection do
          get :pending
          get :approved
          get :stale_proposals
          get :stale_approved
        end
      end

      # Trade Events
      get 'trade_events', to: 'trade_events#all'
      resources :trade_events, only: [:index], path: 'trades/:trade_id/events'

      # News
      resources :news, only: [:index, :show] do
        collection do
          get :latest
          get :ticker
        end
      end

      # Ticker metrics
      resources :ticker_metrics, only: [:index]
      resources :ticker_discoverability, only: [:index]

      # Watchlists (read)
      resources :watchlists, only: [:index]

      # Assets (tradeable symbols from Alpaca)
      resources :assets, only: [:index]

      # Broker account snapshot
      get 'broker_account_snapshot', to: 'broker_account_snapshots#show'

      # Research knowledge graph (read-only)
      resources :research_entities, only: [:index, :show] do
        member do
          get :graph
        end
      end
      resources :investigations, only: [:index, :show] do
        member do
          get :entities
        end
      end
      resources :research_notes, only: [:index]
      resources :research_relationships, only: [:index]

      # Ledger (event-sourced accounting)
      scope :ledger do
        get 'positions', to: 'ledger#positions'
        get 'positions/:ticker', to: 'ledger#position'
        get 'wallets', to: 'ledger#wallets'
        get 'wallets/:agent_id', to: 'ledger#wallets'
        get 'portfolio/:agent_id', to: 'ledger#portfolio'
        get 'explain/:ticker', to: 'ledger#explain'
        get 'cash_history/:agent_id', to: 'ledger#cash_history'
        get 'audit/trade/:trade_id', to: 'ledger#audit_trade'
        get 'stats', to: 'ledger#stats'
      end

      # Mutating endpoints are localhost-only by default.
      constraints local_only do
        resources :wallets, only: [:update]

        resources :positions, only: [:update]

        resources :positions, only: [] do
          collection do
            patch :revalue
            post :cleanup_dust
          end
        end

        resources :trades, only: [:create] do
          member do
            post :approve
            post :deny
            post :pass
            post :cancel
            post :confirm
            post :execute
            post :fill
            post :fail
          end
        end

        resources :ticker_metrics, only: [] do
          collection do
            post :bulk
          end
        end

        resources :watchlists, only: [:create] do
          collection do
            delete :destroy, action: :destroy
          end
        end

        # Research knowledge graph (mutations)
        resources :research_entities, only: [:create, :update]
        resources :research_relationships, only: [:create, :destroy]
        resources :investigations, only: [:create, :update]
        resources :research_notes, only: [:create]
        resources :investigation_entities, only: [:create, :destroy]

        post 'broker_account_snapshot/refresh', to: 'broker_account_snapshots#refresh'
        post 'operations/news_poll', to: 'operations#news_poll'
        post 'operations/alpaca_consistency', to: 'operations#alpaca_consistency'
        post 'operations/alpaca_align', to: 'operations#alpaca_align'
        post 'operations/wallet_funding_sync', to: 'operations#wallet_funding_sync'
        post 'operations/market_data_backfill', to: 'operations#market_data_backfill'
        post 'operations/dividend_snapshot_refresh', to: 'operations#dividend_snapshot_refresh'
        post 'operations/trader_context_prime', to: 'operations#trader_context_prime'
      end
    end
  end
end
