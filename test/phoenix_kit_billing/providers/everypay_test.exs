defmodule PhoenixKitBilling.Providers.EveryPayTest do
  # DataCase (not plain ExUnit.Case, was: async: true), because
  # `handle_webhook_event/1` now resolves its currency's `decimal_places`
  # (§7/Э5) via `PhoenixKitBilling.Providers.MinorUnits`, which reads
  # `phoenix_kit_currencies`.
  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.PaymentOption
  alias PhoenixKitBilling.Providers
  alias PhoenixKitBilling.Providers.EveryPay
  alias PhoenixKitBilling.Providers.Types.WebhookEventData

  setup do
    Repo.delete_all(Currency)

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        is_default: true,
        exchange_rate: "1.0"
      })

    :ok
  end

  describe "provider identity" do
    test "provider_name/0 is :everypay" do
      assert EveryPay.provider_name() == :everypay
    end

    test "is registered in the provider registry" do
      assert Providers.get_provider(:everypay) == EveryPay
      assert Providers.get_provider("everypay") == EveryPay
      assert Providers.provider_exists?(:everypay)
      assert :everypay in Providers.all_providers()
    end

    test "provider_info/1 returns EveryPay metadata" do
      assert %{name: "EveryPay"} = Providers.provider_info(:everypay)
    end
  end

  describe "unsupported callbacks" do
    test "create_setup_session/2 is not supported" do
      assert EveryPay.create_setup_session(%{}, []) == {:error, :not_supported}
    end

    test "get_payment_method_details/1 is not supported" do
      assert EveryPay.get_payment_method_details("tok_123") == {:error, :not_supported}
    end

    test "verify_webhook_signature/3 always passes (callbacks are unsigned)" do
      assert EveryPay.verify_webhook_signature("body", "sig", "secret") == :ok
    end
  end

  describe "handle_webhook_event/1" do
    test "settled payment normalizes to checkout.completed" do
      payment = %{
        "payment_reference" => "ref-1",
        "payment_state" => "settled",
        "order_reference" => "invoice-uuid",
        "amount" => 10.0,
        "currency" => "EUR"
      }

      assert {:ok,
              %WebhookEventData{
                type: "checkout.completed",
                provider: :everypay,
                event_id: "ref-1:settled",
                data: %{mode: "payment", invoice_uuid: "invoice-uuid", amount: 1000}
              }} = EveryPay.handle_webhook_event(payment)
    end

    test "failed payment normalizes to payment.failed" do
      payment = %{
        "payment_reference" => "ref-2",
        "payment_state" => "failed",
        "order_reference" => "invoice-uuid"
      }

      assert {:ok, %WebhookEventData{type: "payment.failed", data: %{error_code: "failed"}}} =
               EveryPay.handle_webhook_event(payment)
    end

    test "refunded payment normalizes to refund.created" do
      payment = %{
        "payment_reference" => "ref-3",
        "payment_state" => "refunded",
        "order_reference" => "invoice-uuid",
        "currency" => "EUR",
        "refunds" => [%{"amount" => 10.0}]
      }

      assert {:ok,
              %WebhookEventData{type: "refund.created", data: %{charge_id: "ref-3", amount: 1000}}} =
               EveryPay.handle_webhook_event(payment)
    end

    test "a currency this shop's table has never heard of does not guess an amount" do
      payment = %{
        "payment_reference" => "ref-5",
        "payment_state" => "settled",
        "order_reference" => "invoice-uuid",
        "amount" => 10.0,
        "currency" => "XXX"
      }

      assert {:ok, %WebhookEventData{data: %{amount: nil, currency: "XXX"}}} =
               EveryPay.handle_webhook_event(payment)
    end

    test "non-final state is ignored as unknown event" do
      payment = %{"payment_reference" => "ref-4", "payment_state" => "initial"}
      assert EveryPay.handle_webhook_event(payment) == {:error, :unknown_event}
    end

    test "malformed payload is rejected" do
      assert EveryPay.handle_webhook_event(%{"foo" => "bar"}) == {:error, :invalid_payload}
    end
  end

  describe "PaymentOption integration" do
    test "everypay is an accepted payment option code" do
      assert "everypay" in PaymentOption.codes()
    end

    test "an online everypay payment option is valid" do
      changeset =
        PaymentOption.changeset(%PaymentOption{}, %{
          name: "EveryPay",
          code: "everypay",
          type: "online",
          provider: "everypay"
        })

      assert changeset.valid?
    end
  end
end
