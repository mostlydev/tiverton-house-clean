module AdminHelper
  def status_badge_class(status)
    case status
    when 'FILLED', 'APPROVED'
      'badge-success'
    when 'DENIED', 'FAILED', 'CANCELLED'
      'badge-danger'
    when 'EXECUTING', 'PROPOSED', 'QUEUED'
      'badge-warning'
    else
      'badge-info'
    end
  end

  def outbox_status_class(status)
    case status
    when 'completed'
      'badge-success'
    when 'failed'
      'badge-danger'
    when 'processing'
      'badge-warning'
    else
      'badge-info'
    end
  end

  # Pagination fallback if kaminari is not installed
  def paginate(collection)
    # No-op if kaminari is not available
    nil
  end
end
