# frozen_string_literal: true

FactoryBot.define do
  factory :ticker_dividend_snapshot do
    ticker { 'JNJ' }
    source { DividendSnapshotRefreshService::SOURCE }
    observed_at { Time.current }
    next_ex_date { 14.days.from_now.to_date }
    next_pay_date { 30.days.from_now.to_date }
    dividend_amount { 1.25 }
    annualized_dividend { 5.0 }
    dividend_yield { 0.04 }
    yield_change_30d { 0.005 }
    payout_ratio { 0.55 }
    payout_growth_yoy { 0.08 }
    meta { {} }
  end
end
