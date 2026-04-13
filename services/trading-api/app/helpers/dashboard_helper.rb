# frozen_string_literal: true

module DashboardHelper
  def dashboard_trade_qty(trade)
    qty = trade[:qty_filled].presence || trade[:qty_requested].presence
    return "—" if qty.blank?

    number_with_precision(qty, precision: 4, strip_insignificant_zeros: true)
  end

  def dashboard_trade_value(trade)
    value = trade[:filled_value].presence || trade[:amount_requested].presence
    return "—" if value.blank?

    number_to_currency(value)
  end
end
