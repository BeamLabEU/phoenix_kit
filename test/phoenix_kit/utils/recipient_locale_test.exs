defmodule PhoenixKit.Utils.RecipientLocaleTest do
  use ExUnit.Case, async: true
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Test.ModuleGettext
  alias PhoenixKit.Utils.RecipientLocale

  doctest PhoenixKit.Utils.RecipientLocale

  describe "preferred/1" do
    test "returns the stored dialect verbatim" do
      assert RecipientLocale.preferred(user_with("en-GB")) == "en-GB"
    end

    test "treats an absent, empty, or non-string preference as no preference" do
      for fields <- [%{}, %{"preferred_locale" => ""}, %{"preferred_locale" => nil}] do
        assert RecipientLocale.preferred(%{custom_fields: fields}) == nil
      end
    end

    test "returns nil for a recipient that carries no custom_fields at all" do
      # The magic-link registration path delivers to a bare address: no account
      # exists yet, so there is nowhere for a preference to live.
      assert RecipientLocale.preferred("someone@example.com") == nil
      assert RecipientLocale.preferred(%{email: "someone@example.com"}) == nil
      assert RecipientLocale.preferred(%{custom_fields: nil}) == nil
    end
  end

  describe "base/1" do
    test "narrows a dialect to its base language for Gettext" do
      assert RecipientLocale.base(user_with("pt-BR")) == "pt"
    end

    test "leaves a bare base code alone" do
      assert RecipientLocale.base(user_with("uk")) == "uk"
    end

    test "returns nil with no preference, meaning 'leave the locale alone'" do
      assert RecipientLocale.base(%{custom_fields: %{}}) == nil
      assert RecipientLocale.base("someone@example.com") == nil
    end
  end

  describe "for_rendering/1" do
    test "prefers the recipient's own dialect over the site default" do
      assert RecipientLocale.for_rendering(user_with("uk")) == "uk"
    end

    test "keeps the dialect rather than narrowing it" do
      # Template resolution tries "en-GB" before "en", so pre-truncating here
      # would silently discard a dialect-specific translation.
      assert RecipientLocale.for_rendering(user_with("en-GB")) == "en-GB"
    end

    test "always answers with a usable locale, whatever the recipient is" do
      # The contract every caller depends on: never nil, so a template lookup
      # always has something to key on. The exact site default is Settings'
      # business and varies by install.
      for recipient <- [%{custom_fields: %{}}, "someone@example.com", %{email: "a@b.c"}, nil] do
        assert locale = RecipientLocale.for_rendering(recipient)
        assert is_binary(locale) and locale != ""
      end
    end
  end

  describe "in_locale/2" do
    test "a dialect renders the base language's translation" do
      # The catalogue is keyed on base codes and looked up exactly: installing
      # "es-ES" as-is matched nothing and every default came out in English.
      spanish = RecipientLocale.in_locale("es", fn -> gettext("Confirm your account") end)

      refute spanish == "Confirm your account"

      for dialect <- ["es-ES", "es-MX", "ES-es"] do
        assert RecipientLocale.in_locale(dialect, fn -> gettext("Confirm your account") end) ==
                 spanish
      end
    end

    test "a locale the catalogue has is installed as it is" do
      assert RecipientLocale.in_locale("ru", fn -> Gettext.get_locale(PhoenixKitWeb.Gettext) end) ==
               "ru"
    end

    test "a dialect the catalogue has stays a dialect; one it lacks narrows to its base" do
      # Gettext names a dialect catalogue with an underscore, `pt_BR`, while
      # preferences and Languages codes use a hyphen.
      known = ["en", "pt", "pt_BR"]

      assert RecipientLocale.gettext_locale("pt-BR", known) == "pt_BR"
      assert RecipientLocale.gettext_locale("pt_BR", known) == "pt_BR"
      assert RecipientLocale.gettext_locale("pt-br", known) == "pt_BR"
      assert RecipientLocale.gettext_locale("pt-PT", known) == "pt"
      assert RecipientLocale.gettext_locale("en", known) == "en"
      assert RecipientLocale.gettext_locale("", known) == "en"
    end

    test "an underscore-spelled locale the catalogue lacks narrows to its base too" do
      assert RecipientLocale.gettext_locale("pt_BR", ["en", "pt"]) == "pt"

      spanish = RecipientLocale.in_locale("es", fn -> gettext("Confirm your account") end)

      assert RecipientLocale.in_locale("es_ES", fn -> gettext("Confirm your account") end) ==
               spanish
    end

    test "restores the previous locale" do
      before = Gettext.get_locale(PhoenixKitWeb.Gettext)
      RecipientLocale.in_locale("de-DE", fn -> :ok end)
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == before
    end
  end

  # A feature module's own backend (billing's `EmailDefaults` translate through
  # `PhoenixKitBilling.Gettext`) has no locale of its own on the process and
  # reads the global one. `in_locale/2` used to set only the core backend's, so
  # module texts came out in the sending process's language.
  describe "in_locale/2 and a feature module's own Gettext backend" do
    @module ModuleGettext

    setup do
      # Each test runs in its own process, but pin the starting point: no
      # global locale and no backend locale, as on a fresh Oban worker.
      Process.delete(Gettext)
      Process.delete(PhoenixKitWeb.Gettext)
      Process.delete(@module)
      :ok
    end

    test "a dialect recipient reads the module's base-language catalogue" do
      assert module_text() == "Your invoice"

      for locale <- ["es-ES", "es", "es_ES", "ES-es"] do
        assert RecipientLocale.in_locale(locale, &module_text/0) == "Su factura"
      end

      # Module catalogues are named for base codes; a `pt-BR` recipient reads
      # the module's `pt`, where an exact `pt_BR` would have matched nothing.
      assert RecipientLocale.in_locale("pt-BR", &module_text/0) == "A sua fatura"
    end

    test "the global locale is the base code, not the dialect" do
      assert RecipientLocale.in_locale("pt-BR", fn -> Gettext.get_locale() end) == "pt"
      assert RecipientLocale.in_locale("", fn -> Gettext.get_locale() end) == "en"
    end

    test "overrides the sender's own locale and restores it afterwards" do
      # The admin's LiveView sends an invoice: the web set both locales to the
      # admin's language before the send.
      Gettext.put_locale("pt")
      Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")

      assert RecipientLocale.in_locale("es-ES", &module_text/0) == "Su factura"

      assert Gettext.get_locale() == "pt"
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "ru"
      assert module_text() == "A sua fatura"
    end

    test "leaves no locale behind on a process that had none" do
      RecipientLocale.in_locale("es", fn -> :ok end)

      assert Process.get(Gettext) == nil
      assert Process.get(PhoenixKitWeb.Gettext) == nil
    end

    test "restores both locales when the function raises" do
      Gettext.put_locale("pt")
      Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")

      assert_raise RuntimeError, "boom", fn ->
        RecipientLocale.in_locale("es-ES", fn -> raise "boom" end)
      end

      assert Gettext.get_locale() == "pt"
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "ru"
    end

    test "restores both locales when the function throws or exits" do
      assert catch_throw(RecipientLocale.in_locale("es", fn -> throw(:thrown) end)) == :thrown
      assert catch_exit(RecipientLocale.in_locale("es", fn -> exit(:gone) end)) == :gone

      assert Process.get(Gettext) == nil
      assert Process.get(PhoenixKitWeb.Gettext) == nil
    end

    test "nests: the inner recipient wins inside, the outer one is back after" do
      result =
        RecipientLocale.in_locale("es-ES", fn ->
          outer_before = module_text()
          inner = RecipientLocale.in_locale("pt-BR", &module_text/0)

          {outer_before, inner, module_text(), Gettext.get_locale(PhoenixKitWeb.Gettext)}
        end)

      assert result == {"Su factura", "A sua fatura", "Su factura", "es"}
      assert Process.get(Gettext) == nil
    end

    test "a nil locale leaves the module backend's locale alone" do
      Gettext.put_locale("pt")
      assert RecipientLocale.in_locale(nil, &module_text/0) == "A sua fatura"
    end

    test "a locale the module backend set for itself is not overridden" do
      Gettext.put_locale(@module, "pt")
      assert RecipientLocale.in_locale("es", &module_text/0) == "A sua fatura"
    end

    test "the core backend still gets its own choice, unchanged" do
      # The core reads `gettext_locale/1` (exact catalogue, then the `pt_BR`
      # spelling, then the base); the global base code does not replace it.
      assert RecipientLocale.in_locale("es-ES", fn ->
               Gettext.get_locale(PhoenixKitWeb.Gettext)
             end) == RecipientLocale.gettext_locale("es-ES")

      assert RecipientLocale.in_locale("es-ES", fn -> gettext("Confirm your account") end) ==
               Gettext.with_locale(PhoenixKitWeb.Gettext, "es", fn ->
                 gettext("Confirm your account")
               end)
    end

    defp module_text, do: Gettext.dgettext(@module, "default", "Your invoice")
  end

  defp user_with(locale), do: %{custom_fields: %{"preferred_locale" => locale}}
end
