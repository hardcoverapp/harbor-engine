// Keeps a <details> the way the reader left it while the page morph-refreshes
// around it: a refresh would otherwise close one they had opened.
//
//   <details data-controller="harbor--details"
//            data-action="turbo:before-morph-attribute->harbor--details#preserveOpen">
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  preserveOpen(event) {
    if (event.target === this.element && event.detail.attributeName === "open") {
      event.preventDefault()
    }
  }
}
