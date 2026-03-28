defmodule PhoenixKit.Modules.Billing.Web.Routes do
  @moduledoc """
  Route definitions for Billing module.

  List page routes are auto-generated from live_view: fields in admin_tabs/0.
  Detail/form routes are defined here in admin_routes/0 and admin_locale_routes/0.
  """

  alias PhoenixKit.Modules.Billing.Web

  def generate(url_prefix) do
    webhook_controller = Web.WebhookController

    quote do
      scope unquote(url_prefix) do
        pipe_through([:phoenix_kit_api])
        post("/webhooks/billing/stripe", unquote(webhook_controller), :stripe)
        post("/webhooks/billing/paypal", unquote(webhook_controller), :paypal)
        post("/webhooks/billing/razorpay", unquote(webhook_controller), :razorpay)
      end
    end
  end

  def admin_routes do
    quote do
      # Orders
      live "/admin/billing/orders/new", unquote(Web.OrderForm), :new,
        as: :billing_order_new

      live "/admin/billing/orders/:id", unquote(Web.OrderDetail), :show,
        as: :billing_order_detail

      live "/admin/billing/orders/:id/edit", unquote(Web.OrderForm), :edit,
        as: :billing_order_edit

      # Invoices
      live "/admin/billing/invoices/:id", unquote(Web.InvoiceDetail), :show,
        as: :billing_invoice_detail

      live "/admin/billing/invoices/:id/print", unquote(Web.InvoicePrint), :print,
        as: :billing_invoice_print

      live "/admin/billing/invoices/:id/receipt", unquote(Web.ReceiptPrint), :print,
        as: :billing_receipt_print

      live "/admin/billing/invoices/:invoice_uuid/credit-note/:transaction_uuid",
           unquote(Web.CreditNotePrint),
           :print,
           as: :billing_credit_note_print

      live "/admin/billing/invoices/:invoice_uuid/payment-confirmation/:transaction_uuid",
           unquote(Web.PaymentConfirmationPrint),
           :print,
           as: :billing_payment_confirmation_print

      # Subscriptions
      live "/admin/billing/subscriptions/new", unquote(Web.SubscriptionForm), :new,
        as: :billing_subscription_new

      live "/admin/billing/subscriptions/:id", unquote(Web.SubscriptionDetail), :show,
        as: :billing_subscription_detail

      live "/admin/billing/subscriptions/:id/edit", unquote(Web.SubscriptionForm), :edit,
        as: :billing_subscription_edit

      # Subscription Types
      live "/admin/billing/subscription-types/new", unquote(Web.SubscriptionTypeForm), :new,
        as: :billing_subscription_type_new

      live "/admin/billing/subscription-types/:id/edit", unquote(Web.SubscriptionTypeForm), :edit,
        as: :billing_subscription_type_edit

      # Billing Profiles
      live "/admin/billing/profiles/new", unquote(Web.BillingProfileForm), :new,
        as: :billing_profile_new

      live "/admin/billing/profiles/:id/edit", unquote(Web.BillingProfileForm), :edit,
        as: :billing_profile_edit
    end
  end

  def admin_locale_routes do
    quote do
      # Orders
      live "/admin/billing/orders/new", unquote(Web.OrderForm), :new,
        as: :billing_order_new_locale

      live "/admin/billing/orders/:id", unquote(Web.OrderDetail), :show,
        as: :billing_order_detail_locale

      live "/admin/billing/orders/:id/edit", unquote(Web.OrderForm), :edit,
        as: :billing_order_edit_locale

      # Invoices
      live "/admin/billing/invoices/:id", unquote(Web.InvoiceDetail), :show,
        as: :billing_invoice_detail_locale

      live "/admin/billing/invoices/:id/print", unquote(Web.InvoicePrint), :print,
        as: :billing_invoice_print_locale

      live "/admin/billing/invoices/:id/receipt", unquote(Web.ReceiptPrint), :print,
        as: :billing_receipt_print_locale

      live "/admin/billing/invoices/:invoice_uuid/credit-note/:transaction_uuid",
           unquote(Web.CreditNotePrint),
           :print,
           as: :billing_credit_note_print_locale

      live "/admin/billing/invoices/:invoice_uuid/payment-confirmation/:transaction_uuid",
           unquote(Web.PaymentConfirmationPrint),
           :print,
           as: :billing_payment_confirmation_print_locale

      # Subscriptions
      live "/admin/billing/subscriptions/new", unquote(Web.SubscriptionForm), :new,
        as: :billing_subscription_new_locale

      live "/admin/billing/subscriptions/:id", unquote(Web.SubscriptionDetail), :show,
        as: :billing_subscription_detail_locale

      live "/admin/billing/subscriptions/:id/edit", unquote(Web.SubscriptionForm), :edit,
        as: :billing_subscription_edit_locale

      # Subscription Types
      live "/admin/billing/subscription-types/new", unquote(Web.SubscriptionTypeForm), :new,
        as: :billing_subscription_type_new_locale

      live "/admin/billing/subscription-types/:id/edit", unquote(Web.SubscriptionTypeForm), :edit,
        as: :billing_subscription_type_edit_locale

      # Billing Profiles
      live "/admin/billing/profiles/new", unquote(Web.BillingProfileForm), :new,
        as: :billing_profile_new_locale

      live "/admin/billing/profiles/:id/edit", unquote(Web.BillingProfileForm), :edit,
        as: :billing_profile_edit_locale
    end
  end
end
