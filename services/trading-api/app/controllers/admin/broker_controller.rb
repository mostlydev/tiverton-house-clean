module Admin
  class BrokerController < BaseController
    def fills
      @fills = BrokerFill.includes(:broker_order)
                        .order(created_at: :desc)
                        .limit(100)
    end

    def orders
      @orders = BrokerOrder.order(created_at: :desc)
                          .limit(100)
    end

    def events
      @events = BrokerOrderEvent.order(created_at: :desc)
                               .limit(200)
    end

    def activity
      @activities = BrokerAccountActivity.order(created_at: :desc)
                                        .limit(100)
    end
  end
end
