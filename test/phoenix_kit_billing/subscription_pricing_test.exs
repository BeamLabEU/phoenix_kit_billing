defmodule PhoenixKitBilling.SubscriptionPricingTest do
  @moduledoc """
  When a subscription pays and what it pays: in advance, the price it stored, with
  the tax inside that price.

  A subscription used to be free until the end of its first period, so a customer
  could use a whole period, cancel and never pay; a trial took a period longer. A
  renewal charged the plan's current price, so editing a plan repriced everyone with
  no notice, and its invoice showed no tax with tax switched on.
  """

  use PhoenixKitBilling.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitBilling.Test.Repo

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  alias PhoenixKitBilling.{
    Events,
    Invoice,
    Order,
    PaymentMethod,
    Subscription,
    SubscriptionType,
    Transaction
  }

  alias PhoenixKitBilling.Workers.{
    SubscriptionCharge,
    SubscriptionDunningWorker,
    SubscriptionRenewalWorker
  }

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual})
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_123")
    Settings.update_setting("billing_tax_enabled", "false")
    Settings.update_setting("billing_default_tax_rate", "0")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
      Settings.update_setting("billing_tax_enabled", "false")
      Settings.update_setting("billing_default_tax_rate", "0")
    end)

    :ok
  end

  defp approve(during \\ fn -> :ok end) do
    stub(fn conn ->
      during.()
      id = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "id" => "pi_#{id}",
        "status" => "succeeded",
        "latest_charge" => "ch_#{id}"
      })
    end)
  end

  defp decline do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_status(402)
      |> Req.Test.json(%{"error" => %{"code" => "card_declined", "message" => "Declined"}})
    end)
  end

  defp stub(answer) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      key = conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first()
      send(test_pid, {:charge, URI.decode_query(body), key})
      answer.(conn)
    end)
  end

  defp flush_charges(acc \\ []) do
    receive do
      {:charge, body, key} -> flush_charges([{body, key} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp plan(attrs \\ %{}) do
    {:ok, type} =
      %{
        name: "Plan",
        slug: "plan-#{System.unique_integer([:positive])}",
        price: Decimal.new("5.00"),
        currency: "EUR"
      }
      |> Map.merge(attrs)
      |> Billing.create_subscription_type()

    type
  end

  defp customer do
    user = fixture_user()

    {:ok, method} =
      %PaymentMethod{}
      |> PaymentMethod.changeset(%{
        provider: "stripe",
        provider_payment_method_id: "pm_#{System.unique_integer([:positive])}",
        provider_customer_id: "cus_1",
        user_uuid: user.uuid,
        status: "active"
      })
      |> Repo.insert()

    {user, method}
  end

  defp signup(user, method, type, attrs \\ %{}) do
    Billing.create_subscription(
      user.uuid,
      Map.merge(%{subscription_type_uuid: type.uuid, payment_method_uuid: method.uuid}, attrs)
    )
  end

  # Paid up, with its period about to end.
  defp running!(user, method, type, attrs \\ %{}) do
    approve()
    {:ok, subscription} = signup(user, method, type, attrs)
    flush_charges()

    subscription
    |> Ecto.Changeset.change(current_period_end: in_seconds(3600))
    |> Repo.update!()
  end

  defp profile!(user, country) do
    {:ok, profile} =
      Billing.create_billing_profile(user, %{
        "type" => "individual",
        "first_name" => "Jane",
        "last_name" => "Roe",
        "country" => country
      })

    profile
  end

  defp in_seconds(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
  end

  defp renew(subscription) do
    SubscriptionRenewalWorker.perform(%Oban.Job{
      args: %{"subscription_uuid" => subscription.uuid}
    })
  end

  defp fan_out, do: SubscriptionRenewalWorker.perform(%Oban.Job{args: %{}})

  defp queued?(subscription) do
    all_enqueued(worker: SubscriptionRenewalWorker)
    |> Enum.any?(&(&1.args["subscription_uuid"] == subscription.uuid))
  end

  defp reload(subscription), do: Repo.get!(Subscription, subscription.uuid)

  defp subscriptions(user) do
    Repo.all(from(s in Subscription, where: s.user_uuid == ^user.uuid))
  end

  defp invoices(user) do
    Repo.all(from(i in Invoice, where: i.user_uuid == ^user.uuid, order_by: [asc: i.uuid]))
  end

  defp latest_invoice(user), do: user |> invoices() |> List.last()

  defp ledger(invoice) do
    Repo.all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
  end

  defp dunning_jobs, do: all_enqueued(worker: SubscriptionDunningWorker)

  describe "a plan without a trial" do
    test "is charged at signup, and its period starts today" do
      {user, method} = customer()
      type = plan()
      approve()

      assert {:ok, %Subscription{status: "active"} = subscription} = signup(user, method, type)

      assert [{charged, _key}] = flush_charges()
      assert charged["amount"] == "500"

      assert [%Invoice{status: "paid"} = invoice] = invoices(user)
      assert invoice.subscription_uuid == subscription.uuid
      assert [%Transaction{}] = ledger(invoice)

      assert DateTime.to_date(subscription.current_period_start) == Date.utc_today()

      assert DateTime.to_date(subscription.current_period_end) ==
               SubscriptionType.next_billing_date(type, Date.utc_today())
    end

    test "does not call the first payment a renewal" do
      {user, method} = customer()
      approve()
      {:ok, _} = signup(user, method, plan())

      refute latest_invoice(user).notes =~ "renewal"
    end

    test "is not charged again by the next daily run" do
      {user, method} = customer()
      approve()
      {:ok, subscription} = signup(user, method, plan())
      flush_charges()

      assert :ok = fan_out()

      refute queued?(subscription)
    end

    test "declined, does not start, owes nothing, and says why" do
      {user, method} = customer()
      decline()

      assert {:error, :card_declined} = signup(user, method, plan())

      assert [%Subscription{status: "cancelled"} = subscription] = subscriptions(user)
      assert [%Invoice{status: "void"}] = invoices(user)
      assert dunning_jobs() == []

      assert :ok = fan_out()
      refute queued?(subscription)
    end

    test "is announced once it is paid, and not when it is declined" do
      Events.subscribe_subscriptions()
      {user, method} = customer()

      decline()
      {:error, _} = signup(user, method, plan())
      refute_received {:subscription_created, _}

      approve()
      {:ok, subscription} = signup(user, method, plan())
      uuid = subscription.uuid
      assert_received {:subscription_created, %Subscription{uuid: ^uuid, status: "active"}}
    end

    test "without a payment method is refused before anything is created" do
      user = fixture_user()

      assert {:error, :no_payment_method} =
               Billing.create_subscription(user.uuid, %{subscription_type_uuid: plan().uuid})

      assert subscriptions(user) == []
      assert invoices(user) == []
    end

    test "inside a transaction is refused: a rollback would lose the record of a charge" do
      {user, method} = customer()
      type = plan()
      approve()

      assert {:ok, {:error, :in_transaction}} =
               Repo.transaction(fn -> signup(user, method, type) end)

      assert flush_charges() == []
      assert subscriptions(user) == []
    end

    test "that the ledger refuses after the charge goes past due, and is not charged again" do
      {user, method} = customer()

      approve(fn ->
        Repo.update_all(from(i in Invoice, where: i.user_uuid == ^user.uuid),
          set: [status: "void"]
        )
      end)

      log =
        capture_log(fn ->
          assert {:error, {:charged_not_recorded, _}} = signup(user, method, plan())
        end)

      assert log =~ "failed to record it"

      assert [%Subscription{status: "past_due"} = subscription] = subscriptions(user)
      assert dunning_jobs() == []

      assert :ok = fan_out()
      refute queued?(subscription)
    end

    test "that the daily run took first charges nothing, and returns what the run left" do
      {user, method} = customer()
      approve()
      {:ok, paid} = signup(user, method, plan())
      flush_charges()

      # What the signup still holds: the period the payment has since moved on from.
      stale = %{paid | current_period_end: paid.current_period_start}

      assert {:ok, %Subscription{status: "active"} = found} =
               SubscriptionCharge.first_charge(stale)

      assert found.current_period_end == paid.current_period_end
      assert flush_charges() == []
    end

    test "after a crash past the charge, the daily run retries on the same invoice and key" do
      {user, method} = customer()
      approve(fn -> raise "the node went down" end)

      assert_raise RuntimeError, fn -> signup(user, method, plan()) end

      assert [%Subscription{status: "active"} = subscription] = subscriptions(user)
      assert [%Invoice{status: "sent", uuid: uuid}] = invoices(user)

      assert :ok = fan_out()
      assert queued?(subscription)

      approve()
      assert {:ok, _} = renew(subscription)

      assert [%Invoice{status: "paid", uuid: ^uuid}] = invoices(user)
      assert [{_first, key}, {_second, key}] = flush_charges()
      assert is_binary(key)
    end
  end

  describe "a trial" do
    test "takes nothing at signup, and its period ends with the trial" do
      {user, method} = customer()
      approve()

      assert {:ok, %Subscription{status: "trialing"} = subscription} =
               signup(user, method, plan(%{trial_days: 14}))

      assert flush_charges() == []
      assert invoices(user) == []

      assert subscription.current_period_end == subscription.trial_end
      assert Date.diff(DateTime.to_date(subscription.trial_end), Date.utc_today()) == 14
    end

    test "starts without a card" do
      user = fixture_user()

      assert {:ok, %Subscription{status: "trialing"}} =
               Billing.create_subscription(user.uuid, %{
                 subscription_type_uuid: plan(%{trial_days: 14}).uuid
               })
    end

    test "is left alone by the daily run until it ends" do
      {user, method} = customer()
      {:ok, subscription} = signup(user, method, plan(%{trial_days: 14}))

      subscription =
        subscription
        |> Ecto.Changeset.change(current_period_end: in_seconds(3600))
        |> Repo.update!()

      assert :ok = fan_out()

      refute queued?(subscription)
    end

    test "is charged once it has ended, and the next period starts there" do
      {user, method} = customer()
      type = plan(%{trial_days: 14})
      {:ok, subscription} = signup(user, method, type)
      ended = in_seconds(-3600)

      subscription =
        subscription
        |> Ecto.Changeset.change(current_period_end: ended, trial_end: ended)
        |> Repo.update!()

      assert :ok = fan_out()
      assert queued?(subscription)

      approve()
      assert {:ok, %Subscription{status: "active"} = renewed} = renew(subscription)

      assert [{_charged, _key}] = flush_charges()
      assert renewed.current_period_start == ended

      assert DateTime.to_date(renewed.current_period_end) ==
               SubscriptionType.next_billing_date(type, DateTime.to_date(ended))
    end

    test "leaves a paying subscription picked up a day ahead, as it always was" do
      {user, method} = customer()
      subscription = running!(user, method, plan())

      assert :ok = fan_out()

      assert queued?(subscription)
    end
  end

  describe "a free plan" do
    test "starts at once, with no card and no charge" do
      user = fixture_user()
      type = plan(%{price: Decimal.new("0")})
      approve()

      assert {:ok, %Subscription{status: "active"} = subscription} =
               Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})

      assert flush_charges() == []
      assert invoices(user) == []

      assert DateTime.to_date(subscription.current_period_end) ==
               SubscriptionType.next_billing_date(type, Date.utc_today())
    end

    test "moves to its next period with no invoice and no provider call" do
      user = fixture_user()
      type = plan(%{price: Decimal.new("0")})

      {:ok, subscription} =
        Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})

      subscription =
        subscription
        |> Ecto.Changeset.change(current_period_end: in_seconds(3600))
        |> Repo.update!()

      approve()
      assert {:ok, %Subscription{status: "active"}} = renew(subscription)

      assert flush_charges() == []
      assert invoices(user) == []
      assert DateTime.compare(reload(subscription).current_period_end, in_seconds(3600)) == :gt
    end
  end

  describe "a renewal after its plan was edited" do
    test "charges the price it stored, in its currency, under its name" do
      {user, method} = customer()
      type = plan()
      subscription = running!(user, method, type)

      {:ok, _} =
        Billing.update_subscription_type(type, %{
          price: Decimal.new("9.00"),
          currency: "USD",
          name: "Renamed"
        })

      approve()
      assert {:ok, _} = renew(subscription)

      assert [{charged, _key}] = flush_charges()
      assert charged["amount"] == "500"
      assert charged["currency"] == "eur"

      invoice = latest_invoice(user)
      assert Decimal.equal?(invoice.total, "5.00")
      assert invoice.currency == "EUR"
      assert [%{"name" => "Plan subscription"}] = invoice.line_items
    end

    test "leaves a new subscriber on the plan's new price" do
      type = plan()
      {:ok, type} = Billing.update_subscription_type(type, %{price: Decimal.new("9.00")})
      {user, method} = customer()
      approve()

      {:ok, subscription} = signup(user, method, type)

      assert Decimal.equal?(subscription.price, "9.00")
      assert [{%{"amount" => "900"}, _key}] = flush_charges()
    end

    test "after a trial charges what the trial stored" do
      {user, method} = customer()
      type = plan(%{trial_days: 14})
      {:ok, subscription} = signup(user, method, type)
      {:ok, _} = Billing.update_subscription_type(type, %{price: Decimal.new("9.00")})

      approve()
      assert {:ok, _} = renew(subscription)

      assert [{%{"amount" => "500"}, _key}] = flush_charges()
    end
  end

  describe "change_subscription_type/3" do
    test "moves the stored price, name and currency, and the next renewal charges them" do
      {user, method} = customer()
      subscription = running!(user, method, plan())
      bigger = plan(%{name: "Bigger", price: Decimal.new("20.00"), currency: "USD"})

      assert {:ok, moved} = Billing.change_subscription_type(subscription, bigger.uuid)

      assert moved.subscription_type_uuid == bigger.uuid
      assert moved.plan_name == "Bigger"
      assert Decimal.equal?(moved.price, "20.00")
      assert moved.currency == "USD"

      approve()
      assert {:ok, _} = renew(moved)

      assert [{%{"amount" => "2000", "currency" => "usd"}, _key}] = flush_charges()
    end

    test "refuses a plan that does not exist, and changes nothing" do
      {user, method} = customer()
      type = plan()
      subscription = running!(user, method, type)

      assert {:error, :subscription_type_not_found} =
               Billing.change_subscription_type(subscription, Ecto.UUID.generate())

      assert reload(subscription).subscription_type_uuid == type.uuid
    end

    test "leaves an invoice made for the period at its amount" do
      {user, method} = customer()
      subscription = running!(user, method, plan())

      decline()
      {:ok, _} = renew(subscription)
      open = latest_invoice(user)

      assert {:ok, _} =
               Billing.change_subscription_type(
                 reload(subscription),
                 plan(%{price: Decimal.new("20.00")}).uuid
               )

      assert Decimal.equal?(Repo.get!(Invoice, open.uuid).total, "5.00")
    end
  end

  describe "apply_plan_price/1" do
    test "moves the running subscriptions of the plan, and says how many" do
      type = plan()
      {user, method} = customer()
      {other_user, other_method} = customer()
      first = running!(user, method, type)
      second = running!(other_user, other_method, type)

      {:ok, type} = Billing.update_subscription_type(type, %{price: Decimal.new("9.00")})

      assert {:ok, 2} = Billing.apply_plan_price(type)

      assert Decimal.equal?(reload(first).price, "9.00")
      assert Decimal.equal?(reload(second).price, "9.00")

      approve()
      assert {:ok, _} = renew(reload(first))
      assert [{%{"amount" => "900"}, _key}] = flush_charges()
    end

    test "moves the currency and the name with the price" do
      type = plan()
      {user, method} = customer()
      subscription = running!(user, method, type)

      {:ok, type} =
        Billing.update_subscription_type(type, %{currency: "USD", name: "Renamed"})

      assert {:ok, 1} = Billing.apply_plan_price(type)

      assert %Subscription{currency: "USD", plan_name: "Renamed"} = reload(subscription)
    end

    test "leaves cancelled subscriptions and other plans alone" do
      type = plan()
      {user, method} = customer()
      {other_user, other_method} = customer()
      cancelled = running!(user, method, type)
      {:ok, _} = Billing.cancel_subscription(cancelled, immediately: true)
      elsewhere = running!(other_user, other_method, plan())

      {:ok, type} = Billing.update_subscription_type(type, %{price: Decimal.new("9.00")})

      assert {:ok, 0} = Billing.apply_plan_price(type)

      assert Decimal.equal?(reload(cancelled).price, "5.00")
      assert Decimal.equal?(reload(elsewhere).price, "5.00")
    end

    test "counts only the subscriptions it changed" do
      type = plan()
      {user, method} = customer()
      running!(user, method, type)

      assert {:ok, 0} = Billing.apply_plan_price(type)
    end

    test "reads the plan again, so a stale struct cannot set an old price" do
      stale = plan()
      {user, method} = customer()
      subscription = running!(user, method, stale)

      {:ok, _} = Billing.update_subscription_type(stale, %{price: Decimal.new("9.00")})

      assert {:ok, 1} = Billing.apply_plan_price(stale)

      assert Decimal.equal?(reload(subscription).price, "9.00")
    end

    test "leaves an invoice made for the period at its amount" do
      type = plan()
      {user, method} = customer()
      subscription = running!(user, method, type)

      decline()
      {:ok, _} = renew(subscription)
      open = latest_invoice(user)

      {:ok, type} = Billing.update_subscription_type(type, %{price: Decimal.new("9.00")})
      assert {:ok, 1} = Billing.apply_plan_price(type)

      assert Decimal.equal?(Repo.get!(Invoice, open.uuid).total, "5.00")
    end
  end

  describe "tax on a subscription's invoice" do
    defp tax_at(percent) do
      Settings.update_setting("billing_tax_enabled", "true")
      Settings.update_setting("billing_default_tax_rate", percent)
    end

    defp invoice_for(price, attrs \\ %{}, setup \\ fn _user -> %{} end) do
      {user, method} = customer()
      approve()

      {:ok, _} =
        signup(user, method, plan(Map.merge(%{price: Decimal.new(price)}, attrs)), setup.(user))

      latest_invoice(user)
    end

    defp in_country(country) do
      fn user -> %{billing_profile_uuid: profile!(user, country).uuid} end
    end

    defp assert_split(invoice, net, tax, rate) do
      assert Decimal.equal?(invoice.subtotal, net)
      assert Decimal.equal?(invoice.tax_amount, tax)
      assert Decimal.equal?(invoice.tax_rate, rate)
    end

    test "is none while tax is off, whatever the customer's country" do
      invoice = invoice_for("12.40", %{}, in_country("EE"))

      assert_split(invoice, "12.40", "0", "0")
      assert Decimal.equal?(invoice.total, "12.40")
    end

    test "is inside the price, at the default rate without a billing profile" do
      tax_at("20")

      invoice = invoice_for("12.00")

      assert_split(invoice, "10.00", "2.00", "0.20")
      assert Decimal.equal?(invoice.total, "12.00")
    end

    test "does not change what the card is charged" do
      tax_at("20")

      invoice_for("12.00")

      assert [{%{"amount" => "1200"}, _key}] = flush_charges()
    end

    test "is at the standard rate of the billing profile's country" do
      tax_at("20")

      assert_split(invoice_for("12.40", %{}, in_country("EE")), "10.00", "2.40", "0.24")
    end

    test "takes a rate with a fraction, like Finland's" do
      tax_at("20")

      assert_split(invoice_for("12.55", %{}, in_country("FI")), "10.00", "2.55", "0.255")
    end

    test "is none in a country without VAT" do
      tax_at("20")

      assert_split(invoice_for("12.00", %{}, in_country("US")), "12.00", "0", "0")
    end

    test "leaves the net on the line, so the lines add up to the subtotal" do
      tax_at("20")

      assert [%{"unit_price" => unit, "total" => total}] = invoice_for("12.00").line_items

      assert Decimal.equal?(Decimal.new(unit), "10.00")
      assert Decimal.equal?(Decimal.new(total), "10.00")
    end

    test "carries the buyer the rate was chosen for" do
      invoice = invoice_for("12.00", %{}, in_country("EE"))

      assert %{"country" => "EE", "first_name" => "Jane"} = invoice.billing_details
    end

    test "is worked out from the price the subscription stored, not the plan's" do
      tax_at("20")
      {user, method} = customer()
      type = plan(%{price: Decimal.new("12.00")})
      subscription = running!(user, method, type)
      {:ok, _} = Billing.update_subscription_type(type, %{price: Decimal.new("24.00")})

      approve()
      {:ok, _} = renew(subscription)

      invoice = latest_invoice(user)
      assert_split(invoice, "10.00", "2.00", "0.20")
      assert Decimal.equal?(invoice.total, "12.00")
    end

    test "is on a renewal's invoice too" do
      tax_at("20")
      {user, method} = customer()
      subscription = running!(user, method, plan(%{price: Decimal.new("12.00")}))

      approve()
      {:ok, _} = renew(subscription)

      assert_split(latest_invoice(user), "10.00", "2.00", "0.20")
    end
  end

  describe "Invoice.split_included_tax/2" do
    test "the net and the tax add up to the amount, however it rounds" do
      cases = [
        {"5.00", "0.24"},
        {"9.99", "0.255"},
        {"0.01", "0.20"},
        {"33.33", "0.07"},
        # Taxing the rounded net would give 0.00, 0.01 and 0.01 here.
        {"0.03", "0.24"},
        {"0.03", "0.20"},
        {"0.02", "0.255"}
      ]

      for {amount, rate} <- cases do
        {net, tax} = Invoice.split_included_tax(Decimal.new(amount), Decimal.new(rate))

        assert Decimal.equal?(Decimal.add(net, tax), amount)
        assert Decimal.equal?(net, Decimal.round(net, 2))
      end
    end

    test "a zero rate leaves the amount alone" do
      assert {net, tax} = Invoice.split_included_tax(Decimal.new("5.00"), Decimal.new("0"))

      assert Decimal.equal?(net, "5.00")
      assert Decimal.equal?(tax, "0")
    end
  end

  describe "Order.get_country_tax_rate/1" do
    test "takes a rate with a fraction, which core's own helper raises on" do
      assert Decimal.equal?(Order.get_country_tax_rate("FI"), "0.255")
    end

    test "is the country's standard rate, and none for an unknown country" do
      assert Decimal.equal?(Order.get_country_tax_rate("EE"), "0.24")
      assert Decimal.equal?(Order.get_country_tax_rate("ZZ"), "0")
      assert Decimal.equal?(Order.get_country_tax_rate(nil), "0")
    end

    test "is what calculate_totals_for_country/3 taxes at" do
      items = [%{"total" => "100.00"}]

      assert {_subtotal, tax, total} = Order.calculate_totals_for_country(items, "FI")

      assert Decimal.equal?(tax, "25.50")
      assert Decimal.equal?(total, "125.50")
    end
  end
end
