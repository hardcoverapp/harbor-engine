// A form where one choice decides which fields follow: each panel belongs to
// one value of the choice, and only the chosen value's panel is shown. The
// fields of a hidden panel are switched off, so they are neither required
// nor sent.
//
//   <form data-controller="harbor--choice">
//     <input type="radio" value="a" data-harbor--choice-target="option" data-action="harbor--choice#show">
//     <div data-harbor--choice-target="panel" data-choice="a">…</div>
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["option", "panel"]

  connect() { this.show() }

  show() {
    const chosen = this.optionTargets.find(option => option.checked)?.value
    this.panelTargets.forEach(panel => {
      const on = panel.dataset.choice === chosen
      panel.hidden = !on
      panel.querySelectorAll("input, select, textarea").forEach(field => { field.disabled = !on })
    })
  }
}
