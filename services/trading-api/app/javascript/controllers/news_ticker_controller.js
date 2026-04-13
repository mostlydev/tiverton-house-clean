import { Controller } from "@hotwired/stimulus"

// Split-flap news ticker controller
export default class extends Controller {
  static values = {
    items: Array
  }

  pages = []
  index = 0
  intervalId = null
  flipMs = 80
  holdBackMs = 100
  staggerMs = 15
  holdMs = 8000

  connect() {
    if (this.itemsValue.length === 0) return

    const dims = this.tickerDims()
    this.pages = this.buildTickerPages(this.itemsValue, dims.cols, dims.rows)

    if (this.pages.length === 0) return

    this.buildTickerCells(dims.cols * dims.rows)
    this.startTickerCycle()

    // Handle resize
    this.resizeHandler = this.handleResize.bind(this)
    window.addEventListener("resize", this.resizeHandler)
  }

  disconnect() {
    if (this.intervalId) {
      clearInterval(this.intervalId)
    }
    if (this.resizeHandler) {
      window.removeEventListener("resize", this.resizeHandler)
    }
  }

  handleResize() {
    clearTimeout(this.resizeTimer)
    this.resizeTimer = setTimeout(() => {
      const dims = this.tickerDims()
      this.pages = this.buildTickerPages(this.itemsValue, dims.cols, dims.rows)
      this.buildTickerCells(dims.cols * dims.rows)
      if (this.pages.length > 0) {
        this.renderTickerPage(this.pages[this.index % this.pages.length])
      }
    }, 200)
  }

  tickerDims() {
    const cellWidth = window.innerWidth <= 768 ? 10 : 12
    // Use document.body.clientWidth to exclude scrollbar, add small buffer
    const availableWidth = document.body.clientWidth - 4
    const cols = Math.floor(availableWidth / cellWidth)
    return { cols: cols, rows: 2 }
  }

  buildTickerCells(count) {
    this.element.innerHTML = ""
    for (let i = 0; i < count; i++) {
      const cell = document.createElement("div")
      cell.className = "flip-cell"

      const card = document.createElement("div")
      card.className = "flip-card"

      const front = document.createElement("div")
      front.className = "flip-face flip-front"
      front.textContent = " "

      const back = document.createElement("div")
      back.className = "flip-face flip-back"
      back.textContent = " "

      card.appendChild(front)
      card.appendChild(back)
      cell.appendChild(card)
      this.element.appendChild(cell)
    }
  }

  formatTickerText(item) {
    const symbols = (item.symbols && item.symbols.length > 0) ? item.symbols.slice(0, 3).join(", ") : "Market"
    const source = item.source || "Unknown"
    const headline = item.headline || "No headline"
    const published = item.published_at ? new Date(item.published_at) : null
    const dateStr = published
      ? `${published.getMonth() + 1}/${published.getDate()} ${published.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }).toLowerCase()}`
      : ""
    return `${dateStr} ${symbols} — ${headline} (${source})`.toUpperCase()
  }

  layoutTextToGrid(text, cols, rows) {
    const words = text.split(/\s+/).filter(Boolean)
    const ellipsis = "..."
    const lines = []
    let currentLine = ""
    let wordIndex = 0

    // Build lines
    while (wordIndex < words.length && lines.length < rows) {
      const word = words[wordIndex]
      const testLine = currentLine ? currentLine + " " + word : word

      if (testLine.length <= cols) {
        currentLine = testLine
        wordIndex++
      } else if (currentLine === "") {
        // Word is longer than line
        if (lines.length === rows - 1) {
          currentLine = word.slice(0, cols - ellipsis.length) + ellipsis
        } else {
          currentLine = word.slice(0, cols)
        }
        wordIndex++
        lines.push(currentLine)
        currentLine = ""
      } else {
        lines.push(currentLine)
        currentLine = ""
      }
    }

    // Handle remaining text
    if (currentLine && lines.length < rows) {
      if (wordIndex < words.length) {
        if (currentLine.length + ellipsis.length + 1 <= cols) {
          currentLine = currentLine + " " + ellipsis
        } else {
          const lineWords = currentLine.split(" ")
          if (lineWords.length > 1) {
            lineWords.pop()
            currentLine = lineWords.join(" ") + " " + ellipsis
          } else {
            currentLine = currentLine.slice(0, cols - ellipsis.length) + ellipsis
          }
        }
      }
      lines.push(currentLine)
    }

    // Fill remaining rows with empty lines
    while (lines.length < rows) {
      lines.push("")
    }

    // Center each line and join
    return lines.map(line => {
      const leftPad = Math.floor((cols - line.length) / 2)
      return line.padStart(leftPad + line.length).padEnd(cols)
    }).join("")
  }

  buildTickerPages(items, cols, rows) {
    const pages = items.map(item => this.formatTickerText(item))
    if (pages.length === 0) return []
    return pages.map(text => this.layoutTextToGrid(text, cols, rows))
  }

  renderTickerPage(text) {
    const cells = this.element.querySelectorAll(".flip-cell")
    const chars = text.split("")
    const dims = this.tickerDims()

    cells.forEach((cell, i) => {
      const front = cell.querySelector(".flip-front")
      const back = cell.querySelector(".flip-back")
      const currentChar = front.textContent || " "
      const nextChar = chars[i] || " "

      if (currentChar === nextChar) return

      const col = i % dims.cols
      const row = Math.floor(i / dims.cols)

      const baseDelay = col * this.staggerMs
      const rowOffset = row * (this.staggerMs * 3)
      const delay = baseDelay + rowOffset

      cell.classList.remove("flip")
      back.textContent = nextChar

      setTimeout(() => {
        cell.offsetHeight // Force reflow
        cell.classList.add("flip")

        setTimeout(() => {
          front.textContent = " "
        }, Math.floor(this.flipMs / 2))

        setTimeout(() => {
          front.textContent = nextChar
        }, this.flipMs)

        setTimeout(() => {
          cell.classList.remove("flip")
        }, this.flipMs + this.holdBackMs)
      }, delay)
    })
  }

  startTickerCycle() {
    if (this.intervalId) {
      clearInterval(this.intervalId)
    }

    this.index = 0
    this.renderTickerPage(this.pages[this.index])

    this.intervalId = setInterval(() => {
      this.index = (this.index + 1) % this.pages.length
      this.renderTickerPage(this.pages[this.index])
    }, this.holdMs)
  }
}
