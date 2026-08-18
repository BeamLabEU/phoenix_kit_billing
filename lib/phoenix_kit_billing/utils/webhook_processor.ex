defmodule PhoenixKitBilling.WebhookProcessor do
  @moduledoc """
  Processes normalized webhook events from payment providers.

  This module handles the business logic for webhook events after they've
  been verified and normalized by the provider modules. It ensures:

  - **Idempotency**: Events are tracked by event_id to prevent double-processing
  - **Error handling**: Failed events are logged with retry counts
  - **Business logic**: Invoices are marked paid, receipts generated, etc.

  ## Event Types

  - `checkout.completed` - Checkout session completed (payment succeeded)
  - `checkout.expired` - Checkout session expired
  - `payment.succeeded` - Direct payment succeeded (for saved cards)
  - `payment.failed` - Payment failed
  - `refund.created` - Refund was processed
  - `setup.completed` - Setup session completed (card saved)

  ## Usage

      # Called by BillingWebhookController
      WebhookProcessor.process(normalized_event)
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Notifications, PaymentMethod, Transaction, WebhookEvent}

  require Logger

  @doc """
  Processes a normalized webhook event.

  Checks for idempotency, processes the event, and logs the result.

  ## Returns

  - `{:ok, result}` - Event processed successfully
  - `{:error, :duplicate_event}` - Event already processed
  - `{:error, reason}` - Processing failed
  """
  @spec process(map()) :: {:ok, any()} | {:error, atom() | term()}
  def process(%{event_id: _event_id, provider: _provider, type: _type} = event) do
    case upsert_webhook_event(event) do
      {:new, webhook_event} ->
        run_and_mark(webhook_event, event)

      {:retry, webhook_event} ->
        Logger.info(
          "Retrying previously-failed webhook event " <>
            "#{webhook_event.provider}/#{webhook_event.event_id} " <>
            "(prior attempts: #{webhook_event.retry_count})"
        )

        run_and_mark(webhook_event, event)

      {:already_processed, _webhook_event} ->
        {:error, :duplicate_event}

      {:max_retries, webhook_event} ->
        Logger.error(
          "Webhook event #{webhook_event.provider}/#{webhook_event.event_id} " <>
            "exceeded the retry limit (#{webhook_event.retry_count} attempts); not reprocessing."
        )

        {:error, :max_retries_exceeded}

      {:error, reason} ->
        Logger.error("Failed to log webhook event before processing: #{inspect(reason)}")
        {:error, :event_log_failed}
    end
  rescue
    e ->
      Logger.error("Webhook processing error: #{Exception.format(:error, e, __STACKTRACE__)}")
      {:error, :processing_error}
  end

  defp run_and_mark(webhook_event, event) do
    result = process_event(event)
    mark_event_processed(webhook_event, result)
    result
  end

  # ===========================================
  # Event Handlers
  # ===========================================

  defp process_event(%{type: "checkout.completed", data: data}) do
    Logger.info("Processing checkout.completed: #{inspect(data)}")

    case data do
      %{mode: "payment", invoice_uuid: invoice_uuid} when not is_nil(invoice_uuid) ->
        # One-time payment for invoice
        process_invoice_payment(invoice_uuid, data)

      %{mode: "setup", user_uuid: user_uuid} when not is_nil(user_uuid) ->
        # Setup session - card saved
        process_setup_completed(data)

      _ ->
        Logger.warning("Unhandled checkout.completed mode: #{inspect(data)}")
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "checkout.expired", data: data}) do
    Logger.info("Checkout session expired: #{inspect(data[:session_id])}")
    # Clear checkout session from order if needed
    {:ok, :expired}
  end

  defp process_event(%{type: "payment.succeeded", data: data}) do
    Logger.info("Processing payment.succeeded: #{inspect(data)}")

    case data do
      %{invoice_uuid: invoice_uuid} when not is_nil(invoice_uuid) ->
        # Payment for invoice (e.g., subscription renewal)
        process_invoice_payment(invoice_uuid, data)

      _ ->
        Logger.warning("Payment succeeded without invoice_uuid: #{inspect(data)}")
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "payment.failed", data: data}) do
    Logger.warning("Payment failed: #{inspect(data)}")

    case data do
      %{invoice_uuid: invoice_uuid} when not is_nil(invoice_uuid) ->
        # Update invoice/subscription status
        process_payment_failure(invoice_uuid, data)

      _ ->
        {:ok, :ignored}
    end
  end

  defp process_event(%{type: "refund.created", data: data}) do
    Logger.info("Processing refund.created: #{inspect(data)}")
    # Record refund transaction
    process_refund(data)
  end

  defp process_event(%{type: "setup.completed", data: data}) do
    Logger.info("Processing setup.completed: #{inspect(data)}")
    # Save payment method for user
    process_setup_completed(data)
  end

  defp process_event(%{type: type}) do
    Logger.debug("Unhandled webhook event type: #{type}")
    {:ok, :unhandled}
  end

  # ===========================================
  # Business Logic
  # ===========================================

  defp process_invoice_payment(invoice_uuid, data) do
    invoice_uuid = parse_id(invoice_uuid)

    with {:ok, invoice} <- get_invoice(invoice_uuid),
         :ok <- validate_invoice_status(invoice) do
      # Determine amount from event data
      amount = calculate_payment_amount(invoice, data)

      # Record the payment
      payment_attrs = %{
        amount: amount,
        payment_method: to_string(data[:provider] || "stripe"),
        description: "Online payment via #{data[:provider] || "Stripe"}",
        provider_transaction_id: data[:charge_id] || data[:payment_intent_id],
        provider_data: data
      }

      # Pass nil for admin_user - system/webhook initiated payment
      #
      # `record_payment/3` returns the recorded `%Transaction{}`, NOT the
      # invoice - and a transaction has no `:status`, so reading one raised
      # KeyError on the success path. Until provider payments started
      # inserting at all this branch was never reached, which is why the
      # mismatch went unnoticed: the payment committed, the webhook 500'd,
      # and the provider retried a charge that had already been recorded.
      case Billing.record_payment(invoice, payment_attrs, nil) do
        {:ok, %Transaction{}} ->
          updated_invoice = Billing.get_invoice!(invoice.uuid)
          Logger.info("Payment recorded for invoice #{updated_invoice.invoice_number}")

          # Generate receipt if fully paid
          if updated_invoice.status == "paid" do
            maybe_generate_and_send_receipt(updated_invoice)
          end

          _ = Notifications.payment_received(updated_invoice, amount)

          {:ok, updated_invoice}

        {:error, reason} ->
          Logger.error("Failed to record payment for invoice #{invoice_uuid}: #{inspect(reason)}")
          _ = Notifications.payment_failed(invoice, reason)
          {:error, reason}
      end
    else
      {:error, :invoice_not_found} ->
        Logger.warning("Invoice not found for webhook: #{invoice_uuid}")
        {:error, :invoice_not_found}

      {:error, :already_paid} ->
        Logger.debug("Invoice #{invoice_uuid} already paid")
        {:ok, :already_paid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Receipt generation/sending is best-effort after a successful payment:
  # the payment itself already succeeded, so a receipt failure must not fail
  # the webhook. We log non-`:ok` results rather than discarding them.
  #
  # `generate_receipt/1` stamps `receipt_number` onto the *returned* struct, so
  # we must send from that struct — `send_receipt/2` rejects an invoice whose
  # `receipt_number` is still nil with `{:error, :receipt_not_generated}`.
  defp maybe_generate_and_send_receipt(invoice) do
    case Billing.generate_receipt(invoice) do
      {:ok, invoice_with_receipt} ->
        send_receipt(invoice_with_receipt)

      other ->
        Logger.warning(
          "Receipt generation skipped for #{invoice.invoice_number}: #{inspect(other)}"
        )
    end
  end

  defp send_receipt(invoice) do
    case Billing.send_receipt(invoice, []) do
      {:ok, _updated_invoice, {:error, email_reason}} ->
        Logger.warning(
          "Receipt saved for #{invoice.invoice_number} but its email was not sent: " <>
            "#{inspect(email_reason)}"
        )

      {:ok, _updated_invoice, _email_result} ->
        :ok

      other ->
        Logger.warning("Receipt send skipped for #{invoice.invoice_number}: #{inspect(other)}")
    end
  end

  defp process_payment_failure(invoice_uuid, data) do
    invoice_uuid = parse_id(invoice_uuid)

    # Log the failure for dunning/retry logic
    Logger.warning(
      "Payment failed for invoice #{invoice_uuid}: #{data[:error_code]} - #{data[:error_message]}"
    )

    # If this invoice is tied to a subscription, update subscription status
    # This will be handled by the subscription renewal worker

    {:ok, :logged}
  end

  defp process_refund(data) do
    charge_id = data[:charge_id] || data[:payment_intent_id]

    with {:ok, charge_id} <- ensure_present(charge_id, :no_charge_id),
         {:ok, original_tx} <- find_transaction_by_provider_id(charge_id),
         {:ok, invoice} <- get_invoice(original_tx.invoice_uuid),
         {:ok, amount} <- refund_amount(data, invoice, original_tx) do
      refund_attrs = %{
        amount: amount,
        payment_method: original_tx.payment_method,
        description: refund_description(data),
        provider_transaction_id: data[:refund_id] || data[:charge_id],
        provider_data: data
      }

      case Billing.record_refund(invoice, refund_attrs, nil) do
        {:ok, transaction} ->
          Logger.info(
            "Refund recorded for invoice #{invoice.invoice_number}: " <>
              "#{Decimal.to_string(transaction.amount)} #{transaction.currency}"
          )

          {:ok, transaction}

        {:error, :exceeds_paid_amount} ->
          Logger.warning(
            "Refund webhook amount exceeds paid_amount for invoice #{invoice.invoice_number}; " <>
              "ignoring as a duplicate or partial-already-applied refund."
          )

          {:ok, :already_refunded}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_charge_id} ->
        Logger.warning("Refund webhook missing charge_id: #{inspect(data)}")
        {:ok, :ignored}

      {:error, :transaction_not_found} ->
        Logger.warning("Refund webhook references unknown charge: #{inspect(charge_id)}")
        {:ok, :ignored}

      {:error, :invoice_not_found} ->
        Logger.warning("Refund webhook's original transaction has no matching invoice")
        {:ok, :ignored}
    end
  end

  defp process_setup_completed(data) do
    user_uuid = data[:user_uuid]
    pm_id = data[:provider_payment_method_id]

    cond do
      is_nil(user_uuid) or is_nil(pm_id) ->
        Logger.debug("setup.completed missing user_uuid or provider_payment_method_id")
        {:ok, :ignored}

      payment_method_exists?(data[:provider] || "stripe", pm_id) ->
        {:ok, :already_saved}

      true ->
        attrs = %{
          provider: to_string(data[:provider] || "stripe"),
          provider_payment_method_id: pm_id,
          provider_customer_id: data[:customer_id],
          user_uuid: user_uuid,
          type: data[:type] || "card",
          brand: data[:brand],
          last4: data[:last4],
          exp_month: data[:exp_month],
          exp_year: data[:exp_year],
          status: "active",
          metadata: data[:metadata] || %{}
        }

        case %PaymentMethod{} |> PaymentMethod.changeset(attrs) |> repo().insert() do
          {:ok, pm} ->
            Logger.info("Payment method saved for user #{user_uuid}: #{pm.uuid}")
            {:ok, pm}

          {:error, changeset} ->
            Logger.error(
              "Failed to save payment method from setup.completed: #{inspect(changeset.errors)}"
            )

            {:error, changeset}
        end
    end
  end

  defp find_transaction_by_provider_id(charge_id) do
    case repo().get_by(Transaction, provider_transaction_id: charge_id) do
      nil -> {:error, :transaction_not_found}
      tx -> {:ok, tx}
    end
  end

  defp refund_amount(data, invoice, original_tx) do
    cond do
      is_integer(data[:amount_refunded]) ->
        {:ok, Decimal.div(Decimal.new(data[:amount_refunded]), 100)}

      is_integer(data[:amount]) ->
        {:ok, Decimal.div(Decimal.new(data[:amount]), 100)}

      true ->
        # Default to refunding the full original transaction, capped at
        # the invoice's currently paid_amount (record_refund will reject
        # anything larger).
        original = Decimal.abs(original_tx.amount)
        cap = invoice.paid_amount || Decimal.new(0)
        {:ok, if(Decimal.compare(original, cap) == :gt, do: cap, else: original)}
    end
  end

  defp refund_description(data) do
    data[:reason] || data[:description] || "Provider refund webhook"
  end

  defp ensure_present(nil, error), do: {:error, error}
  defp ensure_present(value, _error), do: {:ok, value}

  defp payment_method_exists?(provider, provider_pm_id) do
    repo().exists?(
      from(pm in PaymentMethod,
        where:
          pm.provider == ^to_string(provider) and
            pm.provider_payment_method_id == ^provider_pm_id
      )
    )
  end

  # ===========================================
  # Idempotency & Event Logging
  # ===========================================

  defp upsert_webhook_event(%{event_id: event_id, provider: provider, type: type} = event) do
    attrs = %{
      provider: to_string(provider),
      event_id: event_id,
      event_type: type,
      # `event` is a %Providers.Types.WebhookEventData{} struct, which does not
      # implement Access — bracket syntax (`event[:raw_payload]`) raises. Use
      # Map.get/2 to read the struct field safely.
      payload: Map.get(event, :raw_payload) || %{},
      processed: false,
      retry_count: 0
    }

    %WebhookEvent{}
    |> WebhookEvent.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, webhook_event} ->
        {:new, webhook_event}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :provider) or Keyword.has_key?(errors, :event_id) do
          existing =
            repo().one(
              from(we in WebhookEvent,
                where: we.provider == ^to_string(provider) and we.event_id == ^event_id
              )
            )

          cond do
            is_nil(existing) -> {:error, :event_log_failed}
            existing.processed -> {:already_processed, existing}
            WebhookEvent.max_retries_exceeded?(existing) -> {:max_retries, existing}
            true -> {:retry, existing}
          end
        else
          {:error, {:invalid_event, errors}}
        end
    end
  end

  defp mark_event_processed(%WebhookEvent{} = webhook_event, {:ok, _}) do
    webhook_event
    |> WebhookEvent.processed_changeset()
    |> repo().update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not mark webhook event processed: #{inspect(reason)}")
        :ok
    end
  end

  defp mark_event_processed(%WebhookEvent{} = webhook_event, {:error, reason}) do
    webhook_event
    |> WebhookEvent.failed_changeset(inspect(reason))
    |> repo().update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, fail_reason} ->
        Logger.warning("Could not mark webhook event failed: #{inspect(fail_reason)}")
        :ok
    end
  end

  # ===========================================
  # Helpers
  # ===========================================

  defp repo, do: RepoHelper.repo()

  defp get_invoice(invoice_id) do
    case Billing.get_invoice(invoice_id) do
      nil -> {:error, :invoice_not_found}
      invoice -> {:ok, invoice}
    end
  end

  defp validate_invoice_status(%{status: "paid"}) do
    {:error, :already_paid}
  end

  # Delegates to `Invoice.payable?/1` rather than repeating the status list.
  # The two drifted: this gate admitted "draft", which `record_payment/3` now
  # rejects as `:not_payable` - so a draft invoice passed here only to have
  # its payment dropped downstream and the webhook retried forever. One
  # authority on what may take money, not two.
  defp validate_invoice_status(%Invoice{} = invoice) do
    if Invoice.payable?(invoice),
      do: :ok,
      else: {:error, {:invalid_status, invoice.status}}
  end

  defp validate_invoice_status(%{status: status}) do
    {:error, {:invalid_status, status}}
  end

  defp calculate_payment_amount(invoice, data) do
    # Use amount from webhook if available, otherwise use invoice total
    case data do
      %{amount_total: amount_cents} when is_integer(amount_cents) ->
        Decimal.div(Decimal.new(amount_cents), 100)

      %{amount: amount_cents} when is_integer(amount_cents) ->
        Decimal.div(Decimal.new(amount_cents), 100)

      _ ->
        # Use remaining balance on invoice
        Decimal.sub(invoice.total, invoice.paid_amount || Decimal.new(0))
    end
  end

  defp parse_id(id) when is_binary(id), do: id
  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(_), do: nil
end
