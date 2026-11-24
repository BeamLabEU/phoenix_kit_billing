defmodule PhoenixKitBilling.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every admin tab registered by `PhoenixKitBilling.admin_tabs/0`
      carries `gettext_backend: PhoenixKitBilling.Gettext`.
    * Locale switching on the module's own backend produces translated
      labels for at least one well-known msgid (regression guard for
      the `priv/gettext/<locale>/LC_MESSAGES/default.po` shipping with
      the package).
    * Falls back to the raw msgid for an unknown locale.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitBilling.Gettext, as: BillingGettext

  setup do
    original = Gettext.get_locale(BillingGettext)
    on_exit(fn -> Gettext.put_locale(BillingGettext, original) end)
    :ok
  end

  describe "tab wiring (admin_tabs/0, settings_tabs/0, user_dashboard_tabs/0)" do
    test "every registered tab carries the module's own gettext backend" do
      for fun <- [:admin_tabs, :settings_tabs, :user_dashboard_tabs],
          tab <- apply(PhoenixKitBilling, fun, []) do
        assert %{gettext_backend: PhoenixKitBilling.Gettext, gettext_domain: "default"} = tab,
               "Tab #{inspect(tab.id)} from #{fun}/0 is missing or wrong gettext wiring " <>
                 "(got backend=#{inspect(tab.gettext_backend)} " <>
                 "domain=#{inspect(tab.gettext_domain)})"
      end
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'Billing' tab to 'Биллинг'" do
      Gettext.put_locale(BillingGettext, "ru")

      parent = Enum.find(PhoenixKitBilling.admin_tabs(), &(&1.id == :admin_billing))
      assert Tab.localized_label(parent) == "Биллинг"
    end

    test "et locale resolves the parent 'Billing' tab to 'Arveldus'" do
      Gettext.put_locale(BillingGettext, "et")

      parent = Enum.find(PhoenixKitBilling.admin_tabs(), &(&1.id == :admin_billing))
      assert Tab.localized_label(parent) == "Arveldus"
    end

    for {locale, orders, profiles} <- [
          {"de", "Meine Bestellungen", "Rechnungsprofile"},
          {"fr", "Mes commandes", "Profils de facturation"}
        ] do
      test "#{locale} locale resolves the customer-facing user tabs" do
        Gettext.put_locale(BillingGettext, unquote(locale))
        tabs = PhoenixKitBilling.user_dashboard_tabs()

        assert tabs
               |> Enum.find(&(&1.id == :dashboard_orders))
               |> Tab.localized_label() == unquote(orders)

        assert tabs
               |> Enum.find(&(&1.id == :dashboard_billing_profiles))
               |> Tab.localized_label() == unquote(profiles)
      end
    end

    test "the customer pages' sample strings resolve per locale" do
      samples = %{
        "de" => [
          {"No orders yet", "Noch keine Bestellungen"},
          {"Your order history, invoices, and payments",
           "Ihr Bestellverlauf, Ihre Rechnungen und Zahlungen"},
          {"Refund", "Erstattung"},
          {"My Billing Profiles", "Meine Rechnungsprofile"},
          {"Are you sure you want to delete this billing profile?",
           "Möchten Sie dieses Rechnungsprofil wirklich löschen?"},
          {"Billing profile created successfully", "Rechnungsprofil erfolgreich erstellt"},
          {"Save Changes", "Änderungen speichern"}
        ],
        "fr" => [
          {"No orders yet", "Aucune commande pour le moment"},
          {"Your order history, invoices, and payments",
           "Votre historique de commandes, vos factures et vos paiements"},
          {"Refund", "Remboursement"},
          {"My Billing Profiles", "Mes profils de facturation"},
          {"Are you sure you want to delete this billing profile?",
           "Voulez-vous vraiment supprimer ce profil de facturation ?"},
          {"Billing profile created successfully", "Profil de facturation créé avec succès"},
          {"Save Changes", "Enregistrer les modifications"}
        ]
      }

      for {locale, pairs} <- samples, {msgid, expected} <- pairs do
        Gettext.put_locale(BillingGettext, locale)

        assert Gettext.dgettext(BillingGettext, "default", msgid) == expected,
               "#{locale}: #{inspect(msgid)}"
      end
    end

    test "plain 'Paid' resolves to the order-list label, not a print-document context" do
      Gettext.put_locale(BillingGettext, "de")
      assert Gettext.dgettext(BillingGettext, "default", "Paid") == "Bezahlt"
      Gettext.put_locale(BillingGettext, "fr")
      assert Gettext.dgettext(BillingGettext, "default", "Paid") == "Payé"
    end

    test "unknown locale falls back to the raw msgid" do
      Gettext.put_locale(BillingGettext, "zz")

      parent = Enum.find(PhoenixKitBilling.admin_tabs(), &(&1.id == :admin_billing))
      assert Tab.localized_label(parent) == parent.label
    end
  end

  describe "customer pages behind the user menu tabs" do
    @customer_sources ~w(
      web/user_orders.ex
      web/user_orders.html.heex
      web/user_billing_profiles.ex
      web/user_billing_profile_form.ex
      web/components/billing_profile_fields.ex
    )

    # Words that are the same in the target language (or a loanword there).
    @identical %{
      "de" => ~w(Region),
      "fr" => ~w(Date Type Contact Options)
    }

    @customer_msgids (for file <- @customer_sources,
                          source = File.read!(Path.join(["lib", "phoenix_kit_billing", file])),
                          [_, msgid] <-
                            Regex.scan(~r/(?<![a-z_])gettext\("((?:[^"\\]|\\.)*)"/, source) do
                        msgid
                      end)
                     |> Enum.uniq()

    test "the source scan found the customer strings" do
      assert length(@customer_msgids) > 80
      assert "No orders yet" in @customer_msgids
      assert "My Billing Profiles" in @customer_msgids
    end

    test "none of them carries an interpolation or plural form this guard cannot judge" do
      refute Enum.any?(@customer_msgids, &String.contains?(&1, "%{"))
    end

    for locale <- ~w(de fr) do
      test "every customer string is translated in #{locale}" do
        Gettext.put_locale(BillingGettext, unquote(locale))
        identical = Map.fetch!(@identical, unquote(locale))

        untranslated =
          for msgid <- @customer_msgids,
              msgid not in identical,
              Gettext.dgettext(BillingGettext, "default", msgid) == msgid,
              do: msgid

        assert untranslated == []
      end
    end
  end
end
