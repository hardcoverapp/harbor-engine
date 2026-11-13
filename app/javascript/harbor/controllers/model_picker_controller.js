// One row of the alias form: choosing a provider refills the model list with
// that provider's models.
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["provider", "model"]
  static values = { options: Object }

  changeProvider() {
    const options = this.optionsValue[this.providerTarget.value] || []
    this.modelTarget.replaceChildren(
      new Option("Choose a model", ""),
      ...options.map(([label, id]) => new Option(label, id))
    )
    this.modelTarget.value = ""
  }
}
