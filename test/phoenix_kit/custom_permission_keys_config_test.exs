defmodule PhoenixKit.CustomPermissionKeysConfigTest do
  @moduledoc """
  Admin tabs have always been declarative; custom permission keys were the odd
  one out, because `register_custom_key/2` touches the database via the Admin
  auto-grant and so has to run after boot. Every host was therefore hand-writing
  an imperative call at the end of its own `Application.start/2`.

  `PhoenixKit.boot/1` now reads them from config. These pin the parsing and the
  fail-loud contract; whether `boot/1` itself is called is the host's business
  (and documented as such).
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Users.Permissions

  setup do
    Permissions.clear_custom_keys()
    previous = Application.get_env(:phoenix_kit, :custom_permission_keys)

    on_exit(fn ->
      Permissions.clear_custom_keys()

      if previous do
        Application.put_env(:phoenix_kit, :custom_permission_keys, previous)
      else
        Application.delete_env(:phoenix_kit, :custom_permission_keys)
      end
    end)

    :ok
  end

  defp boot_with(entries) do
    Application.put_env(:phoenix_kit, :custom_permission_keys, entries)
    PhoenixKit.boot({:ok, self()})
  end

  defp unique_key, do: "cfg_key_#{System.unique_integer([:positive])}"

  describe "keys declared in config" do
    test "a bare string is registered" do
      key = unique_key()

      assert {:ok, _} = boot_with([key])
      assert key in Permissions.all_module_keys()
    end

    test "a {key, opts} tuple carries its label through" do
      key = unique_key()

      assert {:ok, _} = boot_with([{key, [label: "Custom Reports"]}])

      assert key in Permissions.all_module_keys()
      assert Permissions.localized_module_label(key) == "Custom Reports"
    end

    test "an empty config is a no-op" do
      assert {:ok, _} = boot_with([])
    end
  end

  describe "bad config" do
    test "fails app start rather than being skipped" do
      # Config is a deploy-time contract. Logging and carrying on would hide the
      # mistake until a colleague hit a 403 — the exact failure that declaring
      # keys is supposed to prevent.
      assert_raise ArgumentError, ~r/custom_permission_keys/, fn ->
        boot_with([%{key: "wrong shape"}])
      end
    end

    test "an invalid key format still raises from the registrar" do
      assert_raise ArgumentError, ~r/Invalid permission key/, fn ->
        boot_with(["Not A Valid Key"])
      end
    end

    test "a key colliding with a built-in raises" do
      assert_raise ArgumentError, ~r/conflicts with built-in key/, fn ->
        boot_with(["settings"])
      end
    end
  end

  describe "a failed application start" do
    test "passes through untouched, without trying to register anything" do
      # Registering into a half-started application would turn one failure into
      # a confusing second one.
      Application.put_env(:phoenix_kit, :custom_permission_keys, ["never_registered_key"])

      assert PhoenixKit.boot({:error, :some_reason}) == {:error, :some_reason}
      refute "never_registered_key" in Permissions.all_module_keys()
    end
  end
end
