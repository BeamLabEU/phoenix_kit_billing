defmodule PhoenixKitBilling.PathsTest do
  @moduledoc """
  `Paths.payment_confirmation/2` built `.../invoices/:id/payment/:txn_uuid`,
  but the route actually registered in `Web.Routes` (and mirrored in
  `test/support/test_router.ex`) is
  `.../invoices/:invoice_uuid/payment-confirmation/:transaction_uuid` — the
  `-confirmation` segment was silently dropped. Nothing currently calls
  `Paths.payment_confirmation/2` (an app hand-rolls the URL instead in
  `invoice_detail.html.heex`), so the mismatch never 404'd in practice; this
  pins the helper against the real route segment so a future caller doesn't
  inherit a broken link.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Paths

  test "credit_note/2 matches the credit-note print route segment" do
    assert Paths.credit_note("inv-1", "txn-1") =~ "/invoices/inv-1/credit-note/txn-1"
  end

  test "payment_confirmation/2 matches the payment-confirmation print route segment" do
    assert Paths.payment_confirmation("inv-1", "txn-1") =~
             "/invoices/inv-1/payment-confirmation/txn-1"
  end
end
