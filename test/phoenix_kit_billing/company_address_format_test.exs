defmodule PhoenixKitBilling.CompanyAddressFormatTest do
  @moduledoc """
  `PhoenixKitBilling.format_company_address/1` — the address block on every
  printable document and in the financial emails.

  A Ukrainian address reads postal code first, then the region, the locality
  and the street, on one line; every other country keeps the street-first
  block it always had. The country is named in the document's language.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling, as: Billing

  @ua %{
    "address_line1" => "вул. Петра Юрченка, 19, кв. 302",
    "address_line2" => "",
    "city" => "м. Полтава",
    "state" => "Полтавська обл.",
    "postal_code" => "36007",
    "country" => "UA"
  }

  defp in_locale(locale, fun), do: Gettext.with_locale(PhoenixKitBilling.Gettext, locale, fun)

  describe "a Ukrainian address" do
    test "reads postal code, region, locality, street on one line, then the country" do
      assert in_locale("uk", fn -> Billing.format_company_address(@ua) end) ==
               "36007, Полтавська обл., м. Полтава, вул. Петра Юрченка, 19, кв. 302\nУкраїна"
    end

    test "leaves out the parts that are blank" do
      address = %{@ua | "state" => "", "address_line2" => nil}

      assert in_locale("uk", fn -> Billing.format_company_address(address) end) ==
               "36007, м. Полтава, вул. Петра Юрченка, 19, кв. 302\nУкраїна"
    end

    test "names the country in the document's language" do
      assert in_locale("en", fn -> Billing.format_company_address(@ua) end) =~ "\nUkraine"
      assert in_locale("ru", fn -> Billing.format_company_address(@ua) end) =~ "\nУкраина"
    end
  end

  test "a Russian address reads postal code first too" do
    address = %{
      "address_line1" => "ул. Тверская, 1",
      "city" => "г. Москва",
      "postal_code" => "125009",
      "country" => "RU"
    }

    assert in_locale("ru", fn -> Billing.format_company_address(address) end) ==
             "125009, г. Москва, ул. Тверская, 1\nРоссийская Федерация"
  end

  describe "any other country" do
    test "keeps the street-first block" do
      address = %{
        "address_line1" => "Narva mnt 5",
        "address_line2" => "Office 3",
        "city" => "Tallinn",
        "state" => "",
        "postal_code" => "10117",
        "country" => "EE"
      }

      assert in_locale("en", fn -> Billing.format_company_address(address) end) ==
               "Narva mnt 5\nOffice 3\nTallinn 10117\nEstonia"

      assert in_locale("et", fn -> Billing.format_company_address(address) end) ==
               "Narva mnt 5\nOffice 3\nTallinn 10117\nEesti"
    end

    test "prints an unknown country code as it is" do
      assert in_locale("en", fn ->
               Billing.format_company_address(%{"city" => "Atlantis", "country" => "XX"})
             end) == "Atlantis\nXX"
    end

    test "an empty map is an empty address" do
      assert Billing.format_company_address(%{}) == ""
    end
  end
end
