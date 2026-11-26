defmodule PhoenixKitBilling.VoidCheckoutTest do
  @moduledoc """
  Voiding an invoice with an open hosted checkout session closes that session at
  the provider first (`Providers.expire_checkout_session/2`), over a stubbed
  Stripe. Without it the customer could still pay a void invoice through the
  link they held; the payment then only reached the void trail, to be refunded.
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Providers, WebhookProcessor}
  alias PhoenixKitBilling.Providers.Types.CheckoutSession

  setup do
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_123")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    :ok
  end

  # `answer` gets (method, path) and returns {status, json}.
  defp stub(answer) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:stripe, conn.method, conn.request_path})
      {status, body} = answer.(conn.method, conn.request_path)
      conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
    end)
  end

  defp sent_invoice do
    {:ok, invoice} =
      Billing.create_invoice(fixture_user(), %{total: Decimal.new("20.00"), currency: "EUR"})

    {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)
    invoice
  end

  defp with_session(invoice, id, expires_at \\ DateTime.add(DateTime.utc_now(), 3600)) do
    session = %CheckoutSession{
      id: id,
      url: "https://checkout.stripe.test/#{id}",
      provider: :stripe,
      expires_at: expires_at
    }

    :ok = Billing.record_checkout_session(invoice, :stripe, session)
    Repo.get!(Invoice, invoice.uuid)
  end

  test "an open session is expired at Stripe, then the invoice is voided" do
    invoice = sent_invoice() |> with_session("cs_open")
    stub(fn "POST", _ -> {200, %{"id" => "cs_open", "status" => "expired"}} end)

    assert {:ok, voided} = Billing.void_invoice(invoice, "booking cancelled")

    assert_received {:stripe, "POST", "/v1/checkout/sessions/cs_open/expire"}
    assert voided.status == "void"
    assert voided.metadata["checkout"]["closed_reason"] == "voided"
    assert is_binary(voided.metadata["checkout"]["closed_at"])
    assert Billing.open_checkout(voided.metadata) == nil
  end

  test "a session the customer already paid through refuses the void" do
    invoice = sent_invoice() |> with_session("cs_paid")

    stub(fn
      "POST", _ -> {400, %{"error" => %{"message" => "not in an expirable state"}}}
      "GET", _ -> {200, %{"id" => "cs_paid", "status" => "complete"}}
    end)

    assert {:error, :checkout_completed} = Billing.void_invoice(invoice)
    assert Repo.get!(Invoice, invoice.uuid).status == "sent"
  end

  test "a session that expired on its own at Stripe lets the void through" do
    invoice = sent_invoice() |> with_session("cs_gone")

    stub(fn
      "POST", _ -> {400, %{"error" => %{"message" => "not in an expirable state"}}}
      "GET", _ -> {200, %{"id" => "cs_gone", "status" => "expired"}}
    end)

    assert {:ok, %Invoice{status: "void"}} = Billing.void_invoice(invoice)
  end

  test "when Stripe cannot be reached the invoice stays open, unless told otherwise" do
    invoice = sent_invoice() |> with_session("cs_down")
    stub(fn _, _ -> {500, %{"error" => %{"message" => "boom", "type" => "api_error"}}} end)

    capture_log(fn ->
      assert {:error, {:checkout_not_closed, _}} = Billing.void_invoice(invoice)
    end)

    assert Repo.get!(Invoice, invoice.uuid).status == "sent"

    assert {:ok, voided} = Billing.void_invoice(invoice, nil, close_checkout: false)
    assert voided.status == "void"
    refute voided.metadata["checkout"]["closed_at"]
  end

  test "no session, an expired one or a closed one: no provider call" do
    stub(fn _, _ -> flunk("Stripe must not be called") end)

    assert {:ok, _} = Billing.void_invoice(sent_invoice())

    past = DateTime.add(DateTime.utc_now(), -60)
    assert {:ok, _} = sent_invoice() |> with_session("cs_past", past) |> Billing.void_invoice()

    refute_received {:stripe, _, _}
  end

  test "a session opened while the first was being closed is closed as well" do
    invoice = sent_invoice() |> with_session("cs_first")
    parent = self()

    stub(fn "POST", path ->
      # While the first session is being expired, someone opens another.
      if path =~ "cs_first" and Process.get(:reopened) != true do
        Process.put(:reopened, true)
        with_session(invoice, "cs_second")
        send(parent, :reopened)
      end

      {200, %{"status" => "expired"}}
    end)

    assert {:ok, voided} = Billing.void_invoice(invoice)

    assert_received {:stripe, "POST", "/v1/checkout/sessions/cs_first/expire"}
    assert_received {:stripe, "POST", "/v1/checkout/sessions/cs_second/expire"}
    assert voided.metadata["checkout"]["provider_session_id"] == "cs_second"
    assert voided.metadata["checkout"]["closed_reason"] == "voided"
  end

  test "a session opened for an invoice voided meanwhile is closed, not handed out" do
    invoice = sent_invoice()

    stub(fn
      "POST", "/v1/checkout/sessions" ->
        # The void lands while Stripe is creating the session.
        {:ok, _} = Billing.void_invoice(invoice, nil, close_checkout: false)

        {200,
         %{
           "id" => "cs_late",
           "url" => "https://checkout.stripe.test/late",
           "expires_at" => System.os_time(:second) + 3600
         }}

      "POST", _expire ->
        {200, %{"status" => "expired"}}
    end)

    assert {:error, :invoice_not_payable} =
             Billing.create_checkout_session(invoice, :stripe, success_url: "https://x.test/ok")

    assert_received {:stripe, "POST", "/v1/checkout/sessions/cs_late/expire"}
  end

  test "a second session recorded on the invoice closes the first, which a void could not find" do
    invoice = sent_invoice() |> with_session("cs_tab1")
    stub(fn "POST", _ -> {200, %{"status" => "expired"}} end)

    invoice = with_session(invoice, "cs_tab2")

    assert_received {:stripe, "POST", "/v1/checkout/sessions/cs_tab1/expire"}
    assert invoice.metadata["checkout"]["provider_session_id"] == "cs_tab2"

    # Recording the same session again closes nothing.
    with_session(invoice, "cs_tab2")
    refute_received {:stripe, "POST", "/v1/checkout/sessions/cs_tab2/expire"}
  end

  test "checkout.session.expired marks the recorded session closed" do
    invoice = sent_invoice() |> with_session("cs_hook")

    payload = %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "checkout.session.expired",
      "data" => %{
        "object" => %{"id" => "cs_hook", "metadata" => %{"invoice_uuid" => invoice.uuid}}
      }
    }

    {:ok, event} = Providers.handle_webhook_event(:stripe, payload)
    assert {:ok, :expired} = WebhookProcessor.process(event)

    stored = Repo.get!(Invoice, invoice.uuid)
    assert stored.metadata["checkout"]["closed_reason"] == "expired"
    assert Billing.open_checkout(stored.metadata) == nil
  end

  test "the provider expiry is recorded with the session" do
    expires_at = DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)
    invoice = sent_invoice() |> with_session("cs_exp", expires_at)

    assert {:ok, stored_at, _} = DateTime.from_iso8601(invoice.metadata["checkout"]["expires_at"])
    assert DateTime.compare(stored_at, expires_at) == :eq
  end

  test "a provider that is not configured any more does not block the void" do
    invoice = sent_invoice() |> with_session("cs_unconfigured")
    Settings.update_setting("billing_stripe_enabled", "false")

    log =
      capture_log(fn ->
        assert {:ok, %Invoice{status: "void"} = voided} = Billing.void_invoice(invoice)
        refute voided.metadata["checkout"]["closed_at"]
      end)

    assert log =~ "left open"
  end

  test "a provider without expire_checkout_session/1 answers :not_supported" do
    Settings.update_setting("billing_everypay_enabled", "true")
    on_exit(fn -> Settings.update_setting("billing_everypay_enabled", "false") end)

    assert {:error, reason} = Providers.expire_checkout_session(:everypay, "x")
    assert reason in [:not_supported, :provider_not_available]
  end
end
