defmodule PhoenixKit.Users.ApiPersonalKeysPermissionTest do
  @moduledoc """
  The `api_personal_keys` permission (a person's own API keys, "My API keys") as a key:
  a flat core section key, always enabled, opt-in for Admin. The database side (the boot
  sweep, an explicit grant) is in `test/integration/users/api_personal_keys_permission_test.exs`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Permissions

  @key "api_personal_keys"

  test "it is a core section key, known everywhere a key must be known" do
    assert @key in Permissions.core_section_keys()
    assert @key in Permissions.all_module_keys()
    assert MapSet.member?(Permissions.enabled_module_keys(), @key)
    assert Permissions.valid_module_key?(@key)
    assert Permissions.feature_enabled?(@key)
  end

  test "it is flat: not a sub-permission of api, and not a feature module key" do
    assert Permissions.parent_key(@key) == nil
    refute @key in Permissions.sub_permission_keys()
    refute @key in Permissions.feature_module_keys()
  end

  test "it is opt-in for Admin and excluded from the operator baseline" do
    assert @key in Permissions.opt_in_admin_keys()
    assert @key in Permissions.admin_baseline_exclusions()
    assert :ok = Permissions.auto_grant_to_admin_roles(@key)
  end

  test "it has a label, an icon other than the superadmin's, and a description" do
    assert Permissions.module_label(@key) == "Personal API keys"
    assert Permissions.module_icon(@key) =~ "hero-"
    refute Permissions.module_icon(@key) == Permissions.module_icon("*")
    refute Permissions.module_description(@key) == ""
  end

  test "the label is in the template and translated in every shipped locale" do
    root = Path.expand("../../..", __DIR__)

    for file <-
          [
            "priv/gettext/default.pot"
            | for(
                l <- ~w(de en es et fr it pl ru uk),
                do: "priv/gettext/#{l}/LC_MESSAGES/default.po"
              )
          ] do
      {:ok, po} = Expo.PO.parse_file(Path.join(root, file))

      message =
        Enum.find(po.messages, &(IO.iodata_to_binary(&1.msgid) == "Personal API keys"))

      assert message, "#{file} lacks the label"
      msgstr = IO.iodata_to_binary(message.msgstr)
      if file =~ ~r{/(en/|default\.pot)}, do: assert(msgstr == ""), else: assert(msgstr != "")
    end
  end

  test "the descriptions tell the two API permissions apart" do
    assert Permissions.module_description("api") =~ "all"
    assert Permissions.module_description(@key) =~ "own"
  end
end
