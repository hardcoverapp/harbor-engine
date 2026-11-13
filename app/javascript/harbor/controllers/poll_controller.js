// Refreshes the page every `interval` seconds so live numbers stay current,
// but never while someone is typing: it skips a turn when a text field has
// focus or holds unsaved text. Stops when the element leaves the page.
import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { interval: { type: Number, default: 15 } }

  connect() {
    this.url = window.location.href
    this.timer = setInterval(() => this.tick(), this.intervalValue * 1000)
  }

  disconnect() {
    clearInterval(this.timer)
    this.timer = null
  }

  tick() {
    if (!this.timer || !this.element.isConnected || window.location.href !== this.url) return this.disconnect()
    const active = document.activeElement
    if (active && active.matches("textarea, input[type=text], input[type=number], input:not([type])")) return
    const dirty = [...document.querySelectorAll("textarea")].some((t) => t.value !== t.defaultValue)
    if (dirty) return
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
