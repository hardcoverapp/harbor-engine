class PagesController < ApplicationController
  def home = render(html: "Home", layout: true)
  def reports = render(html: "Reports", layout: true)
  def placeholder = render(html: "A page still in the host", layout: true)
end
