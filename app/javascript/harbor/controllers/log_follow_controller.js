// Keeps a log pinned to its newest line while the page morph-refreshes it,
// the way a terminal does. Scroll up to read and it stays where you put it;
// scroll back to the bottom and it follows again.
//
//   <pre data-controller="harbor--log-follow">…</pre>
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.pinned = true
    this.onScroll = () => { this.pinned = this.atBottom() }
    this.onMorph = () => { if (this.pinned) this.toBottom() }
    this.element.addEventListener("scroll", this.onScroll, { passive: true })
    document.addEventListener("turbo:morph", this.onMorph)
    this.toBottom()
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.onScroll)
    document.removeEventListener("turbo:morph", this.onMorph)
  }

  atBottom() {
    const el = this.element
    return el.scrollHeight - el.scrollTop - el.clientHeight < 24
  }

  toBottom() {
    this.element.scrollTop = this.element.scrollHeight
  }
}
