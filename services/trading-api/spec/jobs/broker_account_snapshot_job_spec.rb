# frozen_string_literal: true

require "rails_helper"

RSpec.describe BrokerAccountSnapshotJob, type: :job do
  it "syncs funded trader wallets after a successful broker snapshot" do
    snapshot = double("BrokerAccountSnapshot", fetched_at: Time.current)
    snapshot_service = instance_double(
      BrokerAccountSnapshotService,
      call: { success: true, snapshot: snapshot }
    )
    sync_service = instance_double(
      Wallets::BrokerFundingSyncService,
      call: { success: true, applied: true, skipped: false, funded_trader_ids: %w[weston logan] }
    )

    allow(BrokerAccountSnapshotService).to receive(:new).and_return(snapshot_service)
    expect(Wallets::BrokerFundingSyncService).to receive(:new).with(snapshot: snapshot).and_return(sync_service)

    described_class.perform_now
  end
end
