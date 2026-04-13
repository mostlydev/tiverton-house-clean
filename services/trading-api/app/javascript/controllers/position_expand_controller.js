import { Controller } from "@hotwired/stimulus"

// Position expand controller - accordion behavior for position thesis cards
export default class extends Controller {
  static targets = ["row", "details"]

  connect() {
    this.filterChangedHandler = this.handleFilterChange.bind(this)
    window.addEventListener("agent-filter:changed", this.filterChangedHandler)
  }

  disconnect() {
    window.removeEventListener("agent-filter:changed", this.filterChangedHandler)
  }

  toggle(event) {
    const row = event.currentTarget
    if (row.style.display === "none") return

    const index = row.dataset.index

    // Find the details row
    const details = this.detailsTargets.find(d => d.dataset.index === index)
    if (!details) return

    const isOpening = details.style.display === "none"

    // Close all other detail rows (accordion behavior)
    this.detailsTargets.forEach(d => {
      d.style.display = "none"
    })

    // If we were opening this one, show it
    if (isOpening) {
      details.style.display = "table-row"
    }
  }

  handleFilterChange() {
    this.detailsTargets.forEach(details => {
      const row = this.rowTargets.find(r => r.dataset.index === details.dataset.index)
      if (!row || row.style.display === "none") {
        details.style.display = "none"
      }
    })
  }
}
