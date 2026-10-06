defmodule PhoenixKit.Integration.BootUpdateModeTest do
  @moduledoc """
  `mix phoenix_kit.update` and `mix phoenix_kit.doctor` start the host app with
  `update_mode` on, and the host's `Application.start/2` ends in
  `PhoenixKit.boot/1`. In that mode `Settings.get_setting/1` answers nil without
  reading, while writes still go through — so a one-shot step whose "already
  done" flag is read through it does its work again on every such run.

  The one that hurt: the Admin auto-grant of a custom permission key. Its flag
  is what keeps an Owner's revocation standing; read as nil, every update or
  doctor run handed the revoked key back to Admin.
  """
  # async: false — flips `update_mode`, the custom-key config, the custom keys
  # in :persistent_term and the module registry, all process-global.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  defmodule LegacyProbe do
    @moduledoc false
    def module_key, do: "boot_update_mode_probe"
    def module_name, do: "Boot update-mode probe"
    def enabled?, do: true

    def migrate_legacy do
      case :persistent_term.get({__MODULE__, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, :legacy_migration_ran)
        nil -> :ok
      end

      :ok
    end
  end

  setup do
    previous_keys = Application.get_env(:phoenix_kit, :custom_permission_keys)
    previous_mode = Application.get_env(:phoenix_kit, :update_mode)

    on_exit(fn ->
      restore(:custom_permission_keys, previous_keys)
      restore(:update_mode, previous_mode)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore(key, value), do: Application.put_env(:phoenix_kit, key, value)

  defp key, do: "boot_um_#{System.unique_integer([:positive])}"

  defp admin_uuid do
    Enum.find(Roles.list_roles(), &(&1.name == "Admin")).uuid
  end

  # Boot as a host's `Application.start/2` does; `update_mode` as the update
  # and doctor tasks set it.
  defp boot(keys, update_mode: update_mode?) do
    Application.put_env(:phoenix_kit, :custom_permission_keys, keys)
    Application.put_env(:phoenix_kit, :update_mode, update_mode?)

    try do
      assert {:ok, _} = PhoenixKit.boot({:ok, self()})
    after
      Application.put_env(:phoenix_kit, :update_mode, false)
    end
  end

  defp unregister_on_exit(key), do: on_exit(fn -> Permissions.unregister_custom_key(key) end)

  describe "custom permission keys" do
    test "a key the Owner revoked from Admin stays revoked through an update-mode boot" do
      key = key()
      unregister_on_exit(key)

      boot([key], update_mode: false)
      assert Permissions.role_has_permission?(admin_uuid(), key)

      :ok = Permissions.revoke_permission(admin_uuid(), key)

      boot([key], update_mode: true)
      refute Permissions.role_has_permission?(admin_uuid(), key)

      # and the next ordinary boot respects it too
      boot([key], update_mode: false)
      refute Permissions.role_has_permission?(admin_uuid(), key)
    end

    # A host may still register its keys itself at the end of
    # `Application.start/2` (the pre-`boot/1` way) — that runs under the update
    # and doctor tasks just the same.
    test "a revoked key stays revoked when the host registers it itself under update_mode" do
      key = key()
      unregister_on_exit(key)

      :ok = Permissions.register_custom_key(key)
      :ok = Permissions.revoke_permission(admin_uuid(), key)

      Application.put_env(:phoenix_kit, :update_mode, true)

      try do
        :ok = Permissions.register_custom_key(key)
      after
        Application.put_env(:phoenix_kit, :update_mode, false)
      end

      refute Permissions.role_has_permission?(admin_uuid(), key)
    end

    test "an ordinary boot still grants a new key to Admin, once" do
      key = key()
      unregister_on_exit(key)

      refute Permissions.role_has_permission?(admin_uuid(), key)
      boot([key], update_mode: false)
      assert Permissions.role_has_permission?(admin_uuid(), key)
    end
  end

  describe "module legacy migrations" do
    setup do
      ModuleRegistry.register(LegacyProbe)
      :persistent_term.put({LegacyProbe, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({LegacyProbe, :test_pid})
        ModuleRegistry.unregister(LegacyProbe)
      end)

      :ok
    end

    test "run on an ordinary boot" do
      boot([], update_mode: false)
      assert_received :legacy_migration_ran
    end

    test "do not run on an update-mode boot" do
      boot([], update_mode: true)
      refute_received :legacy_migration_ran
    end
  end
end
