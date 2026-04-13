import { Controller } from "@hotwired/stimulus"

// Agent filter controller - filters positions and trades by agent
export default class extends Controller {
  static targets = ["card"]

  connect() {
    this.activeAgent = null
  }

  toggle(event) {
    const card = event.currentTarget
    const agentName = this.normalize(card.dataset.agent)

    if (this.activeAgent === agentName) {
      // Clear filter
      this.activeAgent = null
    } else {
      // Set filter
      this.activeAgent = agentName
    }

    this.applyFilter()
  }

  applyFilter() {
    // Update card states
    this.cardTargets.forEach(card => {
      const agent = this.normalize(card.dataset.agent)
      const isActive = this.activeAgent === agent
      const hasFilter = Boolean(this.activeAgent)

      card.classList.toggle("active", isActive)
      card.classList.toggle("dimmed", hasFilter && !isActive)
    })

    // Filter positions table
    document.querySelectorAll(".position-row").forEach(row => {
      const agentName = this.rowAgentName(row)
      const isMatch = this.matchesActiveAgent(agentName)

      if (isMatch) {
        row.style.display = ""
        row.classList.remove("dimmed")
      } else {
        row.style.display = "none"
        row.classList.add("dimmed")
      }
    })

    // Hide detail rows for filtered positions
    document.querySelectorAll(".position-details").forEach(row => {
      const isMatch = this.matchesActiveAgent(this.rowAgentName(row))
      if (!isMatch) {
        row.style.display = "none"
      }
    })

    // Filter trades table
    document.querySelectorAll("#recent-trades-table tbody tr").forEach(row => {
      const cellCount = row.querySelectorAll("td").length
      if (cellCount <= 1) return

      const isMatch = this.matchesActiveAgent(this.rowAgentName(row))
      row.style.display = isMatch ? "" : "none"
    })

    this.dispatch("changed", { detail: { agent: this.activeAgent } })
  }

  rowAgentName(row) {
    const explicit = this.normalize(row.dataset.agentName)
    if (explicit) return explicit

    const agentCell = row.querySelector("td")
    return this.normalize(agentCell ? agentCell.textContent : "")
  }

  matchesActiveAgent(agentName) {
    if (!this.activeAgent) return true
    return agentName === this.activeAgent
  }

  normalize(value) {
    return (value || "").toString().trim().toLowerCase()
  }
}
