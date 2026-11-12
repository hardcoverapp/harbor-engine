class PagesController < ApplicationController
  include Harbor::PageGate
  harbor_page :automations, only: :placeholder
  harbor_page :reports, only: :reports

  def home = render(html: "Home", layout: true)
  # Pages of Harbor's section that live in the host ask for the side nav too.
  def reports = render(inline: '<%= render "harbor/shared/section_nav" %><h1>Reports</h1>', layout: true)
  def placeholder = render(inline: '<%= render "harbor/shared/section_nav" %><h1>A page still in the host</h1>', layout: true)
end
