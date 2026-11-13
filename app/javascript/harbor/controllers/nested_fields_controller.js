// Rows of a nested form: add one from a template, and move rows up and down,
// renumbering their position fields. Used by the workspace form.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["list", "template"]

  add() {
    const id = `${Date.now()}${Math.floor(Math.random() * 1000000).toString().padStart(6, "0")}`
    this.listTarget.insertAdjacentHTML("beforeend", this.templateTarget.innerHTML.replaceAll("NEW_RECORD", id))
    const row = this.listTarget.lastElementChild
    const priority = row.querySelector('input[name$="[position]"]')
    if (priority) {
      const priorities = Array.from(this.listTarget.querySelectorAll('input[name$="[position]"]')).filter(input => input !== priority).map(input => Number(input.value))
      priority.value = Math.max(-1, ...priorities) + 1
    }
    row.querySelector('input:not([type="hidden"]), select')?.focus()
  }

  // Arrow ordering: move a row up or down, then renumber the priority
  // fields in their new order.
  moveUp(event) { this.move(event, -1) }
  moveDown(event) { this.move(event, 1) }

  move(event, direction) {
    const row = event.target.closest("[data-harbor-nested-row]")
    if (!row) return
    const sibling = direction < 0 ? row.previousElementSibling : row.nextElementSibling
    if (!sibling) return
    if (direction < 0) sibling.before(row)
    else sibling.after(row)
    Array.from(this.listTarget.querySelectorAll('input[name$="[position]"]')).forEach((input, index) => { input.value = index })
    event.target.focus()
  }
}
