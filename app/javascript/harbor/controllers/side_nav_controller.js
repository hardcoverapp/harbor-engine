// Collapses Harbor's side nav to a rail of icons and opens it again. The
// choice lives on <html> (so the stylesheet can act on it before anything is
// drawn; see harbor_nav_state_tag) and in localStorage (so it holds across
// pages and visits).
import { Controller } from "@hotwired/stimulus"

const KEY = "harborNav"

export default class extends Controller {
  static targets = ["toggle"]

  connect() { this.sync() }

  get collapsed() { return document.documentElement.dataset.harborNavState === "collapsed" }

  toggle() {
    const collapse = !this.collapsed
    if (collapse) document.documentElement.dataset.harborNavState = "collapsed"
    else delete document.documentElement.dataset.harborNavState
    try { collapse ? localStorage.setItem(KEY, "collapsed") : localStorage.removeItem(KEY) } catch (e) { /* private mode: lasts for this page */ }
    this.sync()
    // Anything sized to its column can refit.
    window.dispatchEvent(new Event("resize"))
  }

  sync() {
    if (!this.hasToggleTarget) return
    this.toggleTarget.setAttribute("aria-expanded", String(!this.collapsed))
    this.toggleTarget.setAttribute("aria-label", this.collapsed ? "Expand the menu" : "Collapse the menu")
    this.toggleTarget.title = this.collapsed ? "Expand the menu" : "Collapse the menu"
  }
}
