defmodule PhoenixKit.Migrations.Postgres.HelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Postgres.Helpers

  describe "validate_prefix!/1" do
    test "accepts conventional lower-case identifiers" do
      assert :ok = Helpers.validate_prefix!("public")
      assert :ok = Helpers.validate_prefix!("auth")
      assert :ok = Helpers.validate_prefix!("companyplexus")
      assert :ok = Helpers.validate_prefix!("my_app_2")
      assert :ok = Helpers.validate_prefix!("_private")
    end

    test "rejects identifiers that need quoting" do
      for bad <- ["MyApp", "my-app", "1schema", "sp ace", "we\"ird", ""] do
        assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
          Helpers.validate_prefix!(bad)
        end
      end
    end

    test "rejects SQL-injection shaped prefixes" do
      assert_raise ArgumentError, fn ->
        Helpers.validate_prefix!("public; DROP TABLE phoenix_kit_users;--")
      end
    end

    test "rejects non-binary values" do
      assert_raise ArgumentError, ~r/expected a string/, fn ->
        Helpers.validate_prefix!(nil)
      end

      assert_raise ArgumentError, ~r/expected a string/, fn ->
        Helpers.validate_prefix!(:auth)
      end
    end

    # The V26/V56 conventions embed the prefix into a handful of index
    # names (longest base 42 bytes — see `Helpers`'
    # `@longest_embedded_object_name`), so a long enough prefix silently
    # truncates at Postgres's 63-byte NAMEDATALEN instead of raising —
    # confirmed live against a real chain (`PhoenixKit.Migrations.Repair`
    # never converges past a 21-byte prefix). 20 bytes is the exact budget:
    # 63 - 1 (the embedded separator) - 42.
    test "accepts a prefix at the 63-byte NAMEDATALEN budget" do
      assert :ok = Helpers.validate_prefix!(String.duplicate("a", 20))
    end

    test "rejects a prefix one byte over the budget" do
      assert_raise ArgumentError, ~r/63-byte NAMEDATALEN/, fn ->
        Helpers.validate_prefix!(String.duplicate("a", 21))
      end
    end
  end

  describe "the embedded-name length budget stays in sync with the manifest" do
    # DB-free: reads the manifest's SOURCE TEXT directly rather than
    # compiling/loading it as a module, so this test needs neither a
    # database nor a compile-time dependency from this low-level helper
    # module onto the generated manifest. Ties `Helpers`'
    # `@longest_embedded_object_name` (currently 42, hardcoded — mirroring
    # `dev_docs/squash/verify.exs`'s own identical constant) to the actual
    # manifest content: if a future migration embeds a longer
    # `__PK_NAME_EXEMPT__`/`__PK_NAME_ALWAYS__` name, this fails loudly
    # instead of `validate_prefix!/1`'s budget silently going stale.
    test "no __PK_NAME_*__ base name in expected_schema.ex exceeds 42 bytes" do
      manifest_path =
        Path.expand("../../../lib/phoenix_kit/migrations/expected_schema.ex", __DIR__)

      source = File.read!(manifest_path)

      longest =
        ~r/__PK_NAME_(?:EXEMPT|ALWAYS)__([a-zA-Z0-9_]+)/
        |> Regex.scan(source)
        |> Enum.map(fn [_whole, base] -> byte_size(base) end)
        |> Enum.max(fn -> 0 end)

      assert longest <= 42,
             "expected_schema.ex now embeds a #{longest}-byte prefixed name — bump " <>
               "Helpers.@longest_embedded_object_name (and re-derive the prefix length " <>
               "cap) to match"
    end
  end

  describe "qualify_table/2" do
    test "qualifies with the prefix" do
      assert Helpers.qualify_table("phoenix_kit_users", "auth") == "auth.phoenix_kit_users"
    end

    test "nil prefix qualifies explicitly as public" do
      assert Helpers.qualify_table("phoenix_kit_users", nil) == "public.phoenix_kit_users"
    end
  end

  describe "uuid_v7_call/1" do
    test "always schema-qualifies the function call" do
      assert Helpers.uuid_v7_call("auth") == "auth.uuid_generate_v7()"
      assert Helpers.uuid_v7_call("public") == "public.uuid_generate_v7()"
      assert Helpers.uuid_v7_call(nil) == "public.uuid_generate_v7()"
    end
  end
end
