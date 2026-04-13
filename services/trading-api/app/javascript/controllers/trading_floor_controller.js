import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.scrollToBottom()
    this.pulseLatest()
  }

  scrollToBottom() {
    const el = this.element
    if (!el) return
    requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight
    })
  }

  pulseLatest() {
    const latest = this.element.querySelector(".feed-row.latest")
    if (!latest) return
    latest.classList.remove("pulse")
    // Restart animation on reconnect
    requestAnimationFrame(() => latest.classList.add("pulse"))
  }
}
