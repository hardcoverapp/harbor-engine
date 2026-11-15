// Submits the form around it as soon as a control changes: a filter or a
// period picker that needs no button.
//
//   <form data-controller="harbor--autosubmit">
//     <select data-action="change->harbor--autosubmit#submit">
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
