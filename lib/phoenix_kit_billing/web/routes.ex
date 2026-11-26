defmodule PhoenixKitBilling.Web.Routes do
  @moduledoc """
  Route definitions for Billing module.

  List page routes are auto-generated from live_view: fields in admin_tabs/0.
  Detail/form routes are defined here in admin_routes/0 and admin_locale_routes/0.
  """

  alias PhoenixKitBilling.Web

  def generate(url_prefix) do
    webhook_controller = Web.WebhookController
    extra_on_mount = Application.get_env(:phoenix_kit, :extra_live_session_on_mount, [])
    public_session = public_session_opts(extra_on_mount)

    quote do
      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_api])
        post("/webhooks/billing/stripe", unquote(webhook_controller), :stripe)
        post("/webhooks/billing/paypal", unquote(webhook_controller), :paypal)
        post("/webhooks/billing/razorpay", unquote(webhook_controller), :razorpay)
        post("/webhooks/billing/everypay", unquote(webhook_controller), :everypay)
      end

      # The public payment page of an invoice (`InvoiceLinks`): no login, the
      # signed token is the credential. Both URL shapes, in one live_session,
      # because `Paths.invoice_pay/1` goes through `Routes.path/1`, which adds a
      # locale segment once Languages is on (the same reason as bookings' public
      # pages). The path is specific, never a catch-all, so it cannot shadow
      # `/admin/*` as a locale.
      live_session :phoenix_kit_billing_public, unquote(public_session) do
        scope unquote(localized_scope(url_prefix)) do
          pipe_through([:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation])
          unquote(public_live_routes("_locale"))
        end

        scope unquote(url_prefix) do
          pipe_through([:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation])
          unquote(public_live_routes(""))
        end
      end
    end
  end

  # The page renders core's app layout, whose inline <style>/<script> tags carry
  # the host's CSP nonce. The first render gets it from the request; core's
  # `PhoenixKitWeb.CSP` carries it into the connected LiveView (session + on_mount),
  # so tags patched in after connect keep it. A core without that module (the
  # published floor) gets the live_session as before.
  @core_csp PhoenixKitWeb.CSP

  @doc false
  def public_session_opts(extra_on_mount) do
    on_mount = extra_on_mount ++ [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}]

    if core_csp?() do
      [session: {@core_csp, :live_session, []}, on_mount: [@core_csp | on_mount]]
    else
      [on_mount: on_mount]
    end
  end

  defp core_csp? do
    Code.ensure_loaded?(@core_csp) and function_exported?(@core_csp, :live_session, 1) and
      function_exported?(@core_csp, :on_mount, 4)
  end

  defp localized_scope(prefix) when prefix in ["/", ""], do: "/:locale"
  defp localized_scope(prefix), do: "#{prefix}/:locale"

  defp public_live_routes(suffix) do
    guest_invoice = Web.GuestInvoice

    quote do
      live("/billing/pay/:token", unquote(guest_invoice), :show,
        as: :"billing_invoice_pay#{unquote(suffix)}"
      )
    end
  end

  def admin_routes do
    build_admin_routes("")
  end

  def admin_locale_routes do
    build_admin_routes("_locale")
  end

  defp build_admin_routes(suffix) do
    order_form = Web.OrderForm
    order_detail = Web.OrderDetail
    invoice_detail = Web.InvoiceDetail
    invoice_print = Web.InvoicePrint
    receipt_print = Web.ReceiptPrint
    credit_note_print = Web.CreditNotePrint
    payment_confirmation_print = Web.PaymentConfirmationPrint
    subscription_form = Web.SubscriptionForm
    subscription_detail = Web.SubscriptionDetail
    subscription_type_form = Web.SubscriptionTypeForm
    billing_profile_form = Web.BillingProfileForm

    quote do
      # Orders
      live("/admin/billing/orders/new", unquote(order_form), :new,
        as: :"billing_order_new#{unquote(suffix)}"
      )

      live("/admin/billing/orders/:id", unquote(order_detail), :show,
        as: :"billing_order_detail#{unquote(suffix)}"
      )

      live("/admin/billing/orders/:id/edit", unquote(order_form), :edit,
        as: :"billing_order_edit#{unquote(suffix)}"
      )

      # Invoices
      live("/admin/billing/invoices/:id", unquote(invoice_detail), :show,
        as: :"billing_invoice_detail#{unquote(suffix)}"
      )

      live("/admin/billing/invoices/:id/print", unquote(invoice_print), :print,
        as: :"billing_invoice_print#{unquote(suffix)}"
      )

      live("/admin/billing/invoices/:id/receipt", unquote(receipt_print), :print,
        as: :"billing_receipt_print#{unquote(suffix)}"
      )

      live(
        "/admin/billing/invoices/:invoice_uuid/credit-note/:transaction_uuid",
        unquote(credit_note_print),
        :print,
        as: :"billing_credit_note_print#{unquote(suffix)}"
      )

      live(
        "/admin/billing/invoices/:invoice_uuid/payment-confirmation/:transaction_uuid",
        unquote(payment_confirmation_print),
        :print,
        as: :"billing_payment_confirmation_print#{unquote(suffix)}"
      )

      # Subscriptions
      live("/admin/billing/subscriptions/new", unquote(subscription_form), :new,
        as: :"billing_subscription_new#{unquote(suffix)}"
      )

      live("/admin/billing/subscriptions/:id", unquote(subscription_detail), :show,
        as: :"billing_subscription_detail#{unquote(suffix)}"
      )

      live("/admin/billing/subscriptions/:id/edit", unquote(subscription_form), :edit,
        as: :"billing_subscription_edit#{unquote(suffix)}"
      )

      # Subscription Types
      live("/admin/billing/subscription-types/new", unquote(subscription_type_form), :new,
        as: :"billing_subscription_type_new#{unquote(suffix)}"
      )

      live("/admin/billing/subscription-types/:id/edit", unquote(subscription_type_form), :edit,
        as: :"billing_subscription_type_edit#{unquote(suffix)}"
      )

      # Billing Profiles
      live("/admin/billing/profiles/new", unquote(billing_profile_form), :new,
        as: :"billing_profile_new#{unquote(suffix)}"
      )

      live("/admin/billing/profiles/:id/edit", unquote(billing_profile_form), :edit,
        as: :"billing_profile_edit#{unquote(suffix)}"
      )
    end
  end
end
