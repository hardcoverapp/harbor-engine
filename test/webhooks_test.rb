require "test_helper"

class HarborWebhooksTest < ActionDispatch::IntegrationTest
  include HarborTestConfig

  setup do
    Harbor::WebhookEvent.delete_all
    Harbor::Run.delete_all
    post "/login", params: { name: "Sam Settings" }
  end

  def delivery(**attrs)
    Harbor::WebhookEvent.create!({ provider: "github", event: "pull_request", action: "opened", received_at: Time.current,
                                   payload: { "pull_request" => { "number" => 12, "title" => "Fix the cover", "html_url" => "https://example.com/pr/12" } } }.merge(attrs))
  end

  test "the page lists deliveries newest first, with what each was about and its status" do
    old = delivery(received_at: 2.hours.ago, action: "closed", status: "ignored", note: "not ours")
    new = delivery(delivery_id: "d-2", status: "dispatched", matched_handler: "review")
    get harbor.webhooks_path
    assert_response :success
    assert_equal [ new.id, old.id ], css_select("[data-webhook-event]").map { |li| li["data-webhook-event"].to_i }
    assert_select "[data-webhook-event='#{new.id}']", text: /pull_request\.opened/
    assert_select "[data-webhook-event='#{new.id}'] [data-status=dispatched]", text: "dispatched"
    assert_select "[data-webhook-event='#{new.id}'] a[href='https://example.com/pr/12']", text: "PR #12 · Fix the cover"
    assert_select "[data-webhook-event='#{new.id}']", text: /review/
    assert_select "[data-webhook-event='#{old.id}']", text: /not ours/
    assert_select "[data-harbor-nav] a[aria-current=page]", text: "Webhooks"
  end

  test "a delivery that started a run names it; with no run page anywhere it is plain text" do
    run = Harbor::Run.create!(skill: "review")
    event = delivery(run: run)
    get harbor.webhooks_path
    assert_select "[data-webhook-event='#{event.id}'] span", text: "Run ##{run.id}"
    assert_select "[data-webhook-event='#{event.id}'] a", text: "Run ##{run.id}", count: 0
  end

  test "a row keeps the status beside the name and lets the rest wrap, so nothing overlaps on a phone" do
    event = delivery(delivery_id: "d-long", event: "pull_request_review_comment", action: "created", status: "dispatched",
                     matched_handler: "Reviews::LongHandlerName", note: "a note long enough to need a second line on a narrow screen")
    get harbor.webhooks_path
    assert_select "[data-webhook-event='#{event.id}']" do
      assert_select "[data-status=dispatched]", count: 1
      assert_select "[data-webhook-subject].line-clamp-2", text: /a note long enough/
      assert_select "[data-webhook-meta].flex-wrap", text: /Reviews::LongHandlerName.*ago/m
      assert_select "[data-webhook-meta] .whitespace-nowrap", text: /ago/
    end
  end

  test "an empty page says so" do
    get harbor.webhooks_path
    assert_select "p", text: /No webhook deliveries yet/
  end

  test "the page can be switched off, and needs a login" do
    Harbor::Setting.set!(:page_webhooks, "false")
    get harbor.webhooks_path
    assert_response :not_found
    Harbor::Setting.reset!(:page_webhooks)
    delete "/logout"
    get harbor.webhooks_path
    assert_redirected_to "/login"
  end

  test "what a delivery was about, by event shape" do
    cases = {
      [ "pull_request_review", { "pull_request" => { "number" => 3, "html_url" => "u" }, "review" => { "state" => "changes_requested", "user" => { "login" => "ada" } } } ] =>
        [ "PR #3 · changes requested by ada", "u" ],
      [ "check_suite", { "check_suite" => { "conclusion" => "failure", "head_branch" => "main", "html_url" => "s", "pull_requests" => [] } } ] =>
        [ "CI failure on main", "s" ],
      [ "check_suite", { "check_suite" => { "conclusion" => "success", "pull_requests" => [ { "number" => 9, "html_url" => "p" } ] } } ] =>
        [ "PR #9 · CI success", "p" ],
      [ "issues", { "issue" => { "number" => 5, "title" => "Broken", "html_url" => "i" } } ] => [ "Issue #5 · Broken", "i" ],
      [ "push", { "ref" => "refs/heads/main", "after" => "abcdef1234", "compare" => "c", "head_commit" => { "message" => "Ship it\n\nbody" } } ] =>
        [ "main @ abcdef1 · Ship it", "c" ],
      [ "ping", {} ] => [ nil, nil ]
    }
    cases.each do |(event, payload), (subject, url)|
      delivery = Harbor::WebhookEvent.new(event: event, payload: payload)
      assert_equal [ subject, url ], [ delivery.subject, delivery.external_url ], event
    end
    assert_equal "ping", Harbor::WebhookEvent.new(event: "ping").label
  end

  test "an unknown status is refused, and a delivery id is taken once" do
    assert_not Harbor::WebhookEvent.new(provider: "github", event: "ping", status: "lost", received_at: Time.current).valid?
    delivery(delivery_id: "same")
    assert_raises(ActiveRecord::RecordNotUnique) { delivery(delivery_id: "same") }
  end

  test "Harbor finds deliveries through the class the host names" do
    assert_equal Harbor::WebhookEvent, Harbor.webhook_event_class
  end

  test "the status pill reads the same for runs, deliveries and workflow runs" do
    html = ApplicationController.helpers.harbor_status_pill("waiting_for_model")
    assert_match "waiting for model", html
    assert_match "bg-pale-yellow", html
    assert_match "bg-pale-green", ApplicationController.helpers.harbor_status_pill("ok")
    assert_match "bg-bone", ApplicationController.helpers.harbor_status_pill("something-new")
  end
end
