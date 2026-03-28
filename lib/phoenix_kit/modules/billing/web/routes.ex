defmodule PhoenixKit.Modules.Billing.Web.Routes do
  @moduledoc """
  Public route definitions for Billing module.
  Admin LiveView routes are auto-generated from live_view: fields in admin_tabs/0.
  """

  def generate(url_prefix) do
    webhook_controller = PhoenixKit.Modules.Billing.Web.WebhookController

    quote do
      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_api])
        post("/webhooks/billing/stripe", unquote(webhook_controller), :stripe)
        post("/webhooks/billing/paypal", unquote(webhook_controller), :paypal)
        post("/webhooks/billing/razorpay", unquote(webhook_controller), :razorpay)
      end
    end
  end
end
