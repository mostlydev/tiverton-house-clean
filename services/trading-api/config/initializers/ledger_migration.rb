# frozen_string_literal: true

# Ledger Migration Feature Flags
#
# These flags control the behavior of reconciliation and accounting services
# during the transaction ledger migration (v5).
#
# Phase 0.1: LEDGER_MIGRATION_WRITE_GUARD=true
#   - OrderReconciliationService: poll-only mode (no fill/position/wallet mutations)
#   - Direct position/wallet mutators: blocked
#
# Set LEDGER_MIGRATION_WRITE_GUARD=true to enable migration mode.
# Set LEDGER_MIGRATION_WRITE_GUARD=false or unset to restore normal operation.

module LedgerMigration
  # Valid read sources
  READ_SOURCES = %w[legacy ledger].freeze

  # Valid write modes
  WRITE_MODES = %w[legacy ledger dual].freeze

  class << self
    # Main guard - blocks all accounting mutations when true (Phase 0-2)
    def write_guard_enabled?
      ActiveModel::Type::Boolean.new.cast(ENV.fetch('LEDGER_MIGRATION_WRITE_GUARD', 'false'))
    end

    # Read source for positions/wallets - 'legacy' or 'ledger'
    # Phase 4: Switch to 'ledger' after shadow mode validation
    def read_source
      source = ENV.fetch('LEDGER_READ_SOURCE', 'legacy').downcase
      READ_SOURCES.include?(source) ? source : 'legacy'
    end

    # Write mode for fills/positions/wallets
    # - 'legacy': Write to legacy tables only (pre-migration)
    # - 'dual': Write to both legacy and ledger (shadow mode)
    # - 'ledger': Write to ledger only, legacy is read-only (Phase 5)
    def write_mode
      mode = ENV.fetch('LEDGER_WRITE_MODE', 'legacy').downcase
      WRITE_MODES.include?(mode) ? mode : 'legacy'
    end

    def read_from_ledger?
      read_source == 'ledger'
    end

    def read_from_legacy?
      read_source == 'legacy'
    end

    def write_to_ledger?
      %w[dual ledger].include?(write_mode)
    end

    def write_to_legacy?
      %w[dual legacy].include?(write_mode)
    end

    def ledger_only_writes?
      write_mode == 'ledger'
    end

    # Convenience method for logging blocked mutations
    def log_blocked_mutation(context, details = {})
      return unless write_guard_enabled? || ledger_only_writes?

      Rails.logger.warn(
        "[LEDGER_MIGRATION] Blocked mutation in #{context}: #{details.to_json}"
      )
    end

    # Check if legacy writes should be blocked
    def block_legacy_write?(context)
      if write_guard_enabled?
        log_blocked_mutation(context, reason: 'write_guard_enabled')
        return true
      end

      if ledger_only_writes?
        log_blocked_mutation(context, reason: 'ledger_only_mode')
        return true
      end

      false
    end

    # Summary for status endpoint
    def status
      {
        write_guard_enabled: write_guard_enabled?,
        read_source: read_source,
        write_mode: write_mode,
        mode: determine_mode
      }
    end

    private

    def determine_mode
      return 'frozen' if write_guard_enabled?

      case write_mode
      when 'ledger'
        'ledger_only'
      when 'dual'
        read_from_ledger? ? 'dual_ledger_read' : 'dual_legacy_read'
      else
        'legacy'
      end
    end
  end
end
