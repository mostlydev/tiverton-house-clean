import { Controller } from "@hotwired/stimulus"

// Auto-refresh controller for Turbo Frames
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 30000 }
  }

  connect() {
    this.startRefresh()
  }

  disconnect() {
    this.stopRefresh()
  }

  startRefresh() {
    this.refreshTimer = setInterval(() => {
      this.refresh()
    }, this.intervalValue)
  }

  stopRefresh() {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer)
    }
  }

  refresh() {
    // If this is a turbo-frame, reload it
    if (this.element.tagName === "TURBO-FRAME") {
      this.element.reload()
    } else {
      // Otherwise, look for turbo-frames inside
      this.element.querySelectorAll("turbo-frame[src]").forEach(frame => {
        frame.reload()
      })
    }
  }
}
