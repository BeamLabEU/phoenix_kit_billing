defmodule PhoenixKitBilling.PotDriftTest do
  @moduledoc """
  Catches drift between registered tab labels and the gettext catalogues.

  Tab labels live as plain strings inside `Tab.new!(label: ...)` calls and
  are NOT picked up by `mix gettext.extract`, so `priv/gettext/default.pot`
  is maintained manually (see the file's own header). Without a guard, a
  newly-added tab will render in raw English under `ru`/`et` because no
  `msgid` exists for its label.

  These tests run unconditionally — they parse files and read struct
  fields preserved on every `phoenix_kit` release, so they don't depend
  on the `gettext_backend` API from BeamLabEU/phoenix_kit#522.
  """

  use ExUnit.Case, async: true

  @pot_path "priv/gettext/default.pot"
  @locales ~w(en ru et uk)

  defp tab_labels do
    for fun <- [:admin_tabs, :settings_tabs, :user_dashboard_tabs],
        tab <- apply(PhoenixKitBilling, fun, []),
        uniq: true,
        do: tab.label
  end

  defp pot_msgids(path) do
    %Expo.Messages{messages: messages} = Expo.PO.parse_file!(path)

    for %Expo.Message.Singular{msgid: msgid} <- messages,
        text = IO.iodata_to_binary(msgid),
        text != "",
        into: MapSet.new(),
        do: text
  end

  defp po_translations(locale) do
    path = Path.join(["priv/gettext", locale, "LC_MESSAGES/default.po"])
    %Expo.Messages{messages: messages} = Expo.PO.parse_file!(path)

    for %Expo.Message.Singular{msgid: msgid, msgstr: msgstr} <- messages,
        id = IO.iodata_to_binary(msgid),
        id != "",
        into: %{},
        do: {id, IO.iodata_to_binary(msgstr)}
  end

  describe "default.pot covers every registered tab label" do
    test "no tab label is missing a msgid" do
      msgids = pot_msgids(@pot_path)

      missing = Enum.reject(tab_labels(), &MapSet.member?(msgids, &1))

      assert missing == [],
             "Tab labels missing from #{@pot_path}: #{inspect(missing)}. " <>
               "Add them to the .pot template and run `mix gettext.merge priv/gettext`."
    end
  end

  describe "every locale .po has a non-empty msgstr for every msgid" do
    for locale <- @locales -- ["en"] do
      test "#{locale}/LC_MESSAGES/default.po translates every msgid" do
        translations = po_translations(unquote(locale))

        untranslated =
          for {msgid, msgstr} <- translations, msgstr == "", do: msgid

        assert untranslated == [],
               "Locale #{unquote(locale)} has empty msgstr for: #{inspect(untranslated)}. " <>
                 "Run `mix gettext.merge priv/gettext --locale #{unquote(locale)}` " <>
                 "and fill in the translations."
      end
    end

    test "en/LC_MESSAGES/default.po is identity-translated (msgstr == msgid)" do
      translations = po_translations("en")

      mismatches =
        for {msgid, msgstr} <- translations, msgstr != msgid, do: {msgid, msgstr}

      assert mismatches == [],
             "English catalogue has non-identity translations: #{inspect(mismatches)}. " <>
               "English msgstr should match msgid exactly (it's the source language)."
    end
  end
end
