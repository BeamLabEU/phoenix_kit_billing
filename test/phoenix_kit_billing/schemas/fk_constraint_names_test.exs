defmodule PhoenixKitBilling.Schemas.FkConstraintNamesTest do
  @moduledoc """
  Every `foreign_key_constraint/3` in this package must name the constraint
  explicitly.

  The billing tables are created by core's migration chain, which names its
  foreign keys `fk_<table>_<column>` — not Ecto's `<table>_<column>_fkey`
  default. `foreign_key_constraint(:user_uuid)` therefore registers a name
  Postgres never reports, the error never matches, and a bad reference comes
  back as a raised `Ecto.ConstraintError` (a 500 to the caller) instead of
  `{:error, changeset}` with a field error.

  This went unnoticed because the only tests that insert a row with a real FK
  used an unpersisted fixture user, so they raised for a *different* reason
  and the suite could not run at all without a reachable database.
  """
  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order

  @missing_user "00000000-0000-4000-8000-000000000000"

  describe "a reference to a nonexistent row is a changeset error, not a raise" do
    test "Invoice.user_uuid" do
      assert {:error, changeset} =
               Repo.insert(
                 Invoice.changeset(%Invoice{}, %{
                   user_uuid: @missing_user,
                   invoice_number: "INV-FK-#{System.unique_integer([:positive])}",
                   total: Decimal.new("10.00"),
                   currency: "EUR"
                 })
               )

      assert %{user_uuid: [_ | _]} = errors_on(changeset)
    end

    test "Order.user_uuid" do
      assert {:error, changeset} =
               Repo.insert(
                 Order.changeset(%Order{}, %{
                   user_uuid: @missing_user,
                   order_number: "ORD-FK-#{System.unique_integer([:positive])}",
                   total: Decimal.new("10.00"),
                   currency: "EUR",
                   billing_snapshot: %{"email" => "g@example.com"}
                 })
               )

      assert %{user_uuid: [_ | _]} = errors_on(changeset)
    end

    test "BillingProfile.user_uuid" do
      assert {:error, changeset} =
               Repo.insert(
                 BillingProfile.changeset(%BillingProfile{}, %{
                   user_uuid: @missing_user,
                   type: "company",
                   company_name: "FK Probe OÜ"
                 })
               )

      assert %{user_uuid: [_ | _]} = errors_on(changeset)
    end
  end

  describe "the declared names match what the database actually calls them" do
    test "every FK on the billing tables is registered under its real name" do
      # Reading pg_constraint rather than hardcoding: if core renames one, this
      # fails here with the real name rather than at a customer's insert.
      real =
        Repo.query!("""
        SELECT conrelid::regclass::text, conname
        FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid::regclass::text IN
              ('phoenix_kit_invoices', 'phoenix_kit_orders', 'phoenix_kit_billing_profiles')
        """).rows
        |> MapSet.new(fn [table, name] -> {table, name} end)

      declared =
        MapSet.new([
          {"phoenix_kit_invoices", "fk_invoices_user_uuid"},
          {"phoenix_kit_invoices", "fk_invoices_order_uuid"},
          {"phoenix_kit_orders", "fk_orders_user_uuid"},
          {"phoenix_kit_orders", "fk_orders_billing_profile_uuid"},
          {"phoenix_kit_billing_profiles", "fk_billing_profiles_user_uuid"}
        ])

      assert MapSet.subset?(declared, real),
             """
             A constraint named in a changeset no longer exists in the database.
             Missing: #{inspect(MapSet.to_list(MapSet.difference(declared, real)))}
             """
    end
  end
end
