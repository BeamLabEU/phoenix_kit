defmodule PhoenixKitWeb.GettextTest.StubPlural do
  @moduledoc false
  @behaviour Gettext.Plural

  # Distinctive `plural_info` so a test can tell this module was used
  # instead of `Gettext.Plural` (which returns the locale or `{locale, forms}`).
  @impl true
  def init(%{locale: locale}), do: {:stub, locale}

  @impl true
  def nplurals({:stub, _locale}), do: 2

  @impl true
  def plural({:stub, _locale}, _n), do: 7
end

defmodule PhoenixKitWeb.GettextTest do
  @moduledoc """
  The backend stores translations in a compact lookup table instead of one
  function clause per message. These tests pin the Gettext.Backend contract
  so a future simplification cannot silently change lookup, plural forms,
  interpolation, or the extract-surface metadata.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Gettext.Compiler
  alias PhoenixKitWeb.GettextTest.StubPlural

  @backend PhoenixKitWeb.Gettext

  # German's real rule is `n != 1`; this fixture's header inverts it to
  # `n == 1`, so header-derived and locale-table-derived forms disagree.
  @fixture_priv "test/support/gettext_fixtures"

  setup do
    previous = Gettext.get_locale(@backend)
    on_exit(fn -> Gettext.put_locale(@backend, previous) end)
    :ok
  end

  describe "backend metadata" do
    test "known_locales includes every shipped catalogue" do
      locales = Gettext.known_locales(@backend)

      assert Enum.sort(locales) == ~w(de en es et fr it pl ru uk)
    end

    test "extract-surface callbacks stay populated" do
      assert @backend.__gettext__(:otp_app) == :phoenix_kit
      assert @backend.__gettext__(:priv) == "priv/gettext"
      assert @backend.__gettext__(:default_domain) == "default"
      assert @backend.__gettext__(:interpolation) == Gettext.Interpolation.Default
      assert is_binary(@backend.__gettext__(:default_locale))
    end

    test "unchanged PO files do not request a mix recompile" do
      refute @backend.__mix_recompile__?()
    end

    test "warming the catalogue is idempotent" do
      assert @backend.warm_catalog() == :ok
      assert @backend.warm_catalog() == :ok
      assert {hash, catalog} = :persistent_term.get({@backend, :catalog})
      assert is_binary(hash) and is_map(catalog)
    end

    # The persistent_term key outlives the module. After a `.po` edit the
    # recompiled module carries a new catalogue, and a term cached by the OLD
    # module must not keep answering — it did, until the VM restarted.
    test "a catalogue cached by an earlier compile of the module is replaced" do
      key = {@backend, :catalog}
      current = :persistent_term.get(key, nil)

      on_exit(fn -> if current, do: :persistent_term.put(key, current) end)

      :persistent_term.put(key, {"hash of an older compile", %{}})

      assert Gettext.with_locale(@backend, "ru", fn ->
               Gettext.dgettext(@backend, "default", "Save")
             end) != "Save"

      assert {hash, catalog} = :persistent_term.get(key)
      assert hash != "hash of an older compile"
      assert map_size(catalog) > 0
    end
  end

  describe "compile-time catalogue" do
    test "reads :priv from the given opts, not a hardcoded default" do
      snapshot = Compiler.snapshot(priv: @fixture_priv)

      assert snapshot.known_locales == ["de"]
      assert Map.has_key?(snapshot.plural_infos, {"de", "default"})
    end

    test "plural forms come from the PO header, not the built-in locale table" do
      %{plural_infos: %{{"de", "default"} => info}} = Compiler.snapshot(priv: @fixture_priv)

      # Gettext's built-in German rule (`n != 1`).
      assert Gettext.Plural.plural("de", 1) == 0
      assert Gettext.Plural.plural("de", 2) == 1

      # The fixture header (`n == 1`) wins, so the forms swap.
      assert Gettext.Plural.plural(info, 1) == 1
      assert Gettext.Plural.plural(info, 2) == 0
    end

    test "honours the plural module it is handed" do
      %{plural_infos: %{{"de", "default"} => info}} =
        Compiler.snapshot(
          priv: @fixture_priv,
          plural_forms: StubPlural
        )

      assert info == {:stub, "de"}
      assert StubPlural.plural(info, 2) == 7
    end

    test "plural entries carry the PO source line, not a dummy 1" do
      snapshot = Compiler.snapshot(priv: @fixture_priv)
      catalog = :erlang.binary_to_term(snapshot.binary)

      {:plural, _msgid_plural, _forms, {path, line}} =
        catalog["de"]["default"][{nil, "%{count} thing"}]

      assert path =~ "default.po"
      assert line == 12
    end

    test "shipped catalogues with a Plural-Forms header store header-derived info" do
      snapshot = Compiler.snapshot(priv: "priv/gettext")
      info = snapshot.plural_infos[{"pl", "default"}]

      refute is_binary(info)
      assert Gettext.Plural.plural(info, 1) == Gettext.Plural.plural("pl", 1)
      assert Gettext.Plural.plural(info, 2) == Gettext.Plural.plural("pl", 2)
      assert Gettext.Plural.plural(info, 5) == Gettext.Plural.plural("pl", 5)
    end
  end

  describe "singular lookup" do
    test "English falls through empty msgstr to the msgid" do
      Gettext.put_locale(@backend, "en")
      assert Gettext.gettext(@backend, "Dashboard") == "Dashboard"
    end

    test "Russian returns the translated string" do
      Gettext.put_locale(@backend, "ru")
      assert Gettext.gettext(@backend, "Dashboard") == "Панель управления"
    end

    test "a missing msgid returns the msgid" do
      Gettext.put_locale(@backend, "ru")
      assert Gettext.gettext(@backend, "definitely-not-a-msgid") == "definitely-not-a-msgid"
    end

    test "errors domain is a separate catalogue" do
      Gettext.put_locale(@backend, "ru")
      assert Gettext.dgettext(@backend, "errors", "can't be blank") == "не может быть пустым"
    end
  end

  describe "interpolation" do
    test "substitutes bindings in a translated string" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.gettext(@backend, "Welcome to the %{project_title} administration panel",
               project_title: "Acme"
             ) == "Добро пожаловать в панель администрирования Acme"
    end

    test "missing bindings keep the placeholder and do not raise" do
      Gettext.put_locale(@backend, "en")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Gettext.gettext(
                   @backend,
                   "Welcome to the %{project_title} administration panel"
                 ) == "Welcome to the %{project_title} administration panel"
        end)

      assert log =~ "missing Gettext bindings: [:project_title]"
    end
  end

  describe "plural lookup" do
    # Russian: 1 → form 0, 2 → form 1, 5 → form 2.
    @msgid "%{count} file permanently deleted"
    @msgid_plural "%{count} files permanently deleted"

    test "picks the singular, paucal, and plural Russian forms" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.ngettext(@backend, @msgid, @msgid_plural, 1) ==
               "1 файл удалён навсегда"

      assert Gettext.ngettext(@backend, @msgid, @msgid_plural, 2) ==
               "2 файла удалено навсегда"

      assert Gettext.ngettext(@backend, @msgid, @msgid_plural, 5) ==
               "5 файлов удалено навсегда"
    end

    test "errors domain plurals interpolate count" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.dngettext(
               @backend,
               "errors",
               "should have %{count} item(s)",
               "should have %{count} item(s)",
               3
             ) == "должно быть 3 элемента"
    end

    test "Polish picks all three header-declared forms" do
      Gettext.put_locale(@backend, "pl")

      forms =
        for n <- [1, 2, 5],
            do: Gettext.ngettext(@backend, @msgid, @msgid_plural, n)

      assert [_, _, _] = Enum.uniq(forms)
    end

    test "a missing plural msgid interpolates the English fallback" do
      Gettext.put_locale(@backend, "ru")

      assert Gettext.ngettext(@backend, "%{count} widget", "%{count} widgets", 4) == "4 widgets"
    end
  end
end
