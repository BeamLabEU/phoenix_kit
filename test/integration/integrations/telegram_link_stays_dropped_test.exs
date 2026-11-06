defmodule PhoenixKit.Integration.Integrations.TelegramLinkStaysDroppedTest do
  @moduledoc """
  A chat linked to the site bot is a standing credential: once the link is dropped, or
  the account's credentials are replaced, nothing may bring it back. Each test here reaches
  for one way a writer that holds the user's `custom_fields` from earlier used to do that:
  writing the map (or the channel's part of it) back restores the chat the drop removed.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.ManagedOrganizations
  alias PhoenixKit.Utils.Routes

  @chat 7_001
  @page Routes.path("/admin/notifications/settings")

  setup %{conn: conn} do
    {:ok, %{uuid: site}} = Integrations.add_connection("telegram", "site bot")
    {:ok, _} = Integrations.save_setup(site, %{"bot_token" => "111:SITE"})
    :ok = SiteBot.select(site)

    # The settings page sits in the admin area.
    {user, _token} = create_admin_user()
    {:ok, _} = Linking.link_chat(user, site, @chat)

    %{conn: log_in_user(conn, user), user: Auth.get_user!(user.uuid), site: site}
  end

  defp linked?(site), do: Linking.linked_user(site, @chat) != nil

  describe "the notification settings page, opened before the drop" do
    test "Save does not put the link back", %{conn: conn, user: user, site: site} do
      {:ok, view, html} = live(conn, @page)
      assert html =~ "notification_channel[telegram]"

      :ok = Linking.drop_links(user.uuid)
      refute linked?(site)

      view |> form("#notification-settings-form") |> render_submit()

      refute linked?(site)
    end

    test "saving a cadence does not put the link back", %{conn: conn, user: user, site: site} do
      {:ok, view, _html} = live(conn, @page)
      [type | _] = Types.list()

      :ok = Linking.drop_links(user.uuid)

      render_submit(view, "save_cadences", %{"cadence" => %{"telegram" => %{type.key => "daily"}}})

      refute linked?(site)
      config = ChannelConfig.for_channel(Auth.get_user!(user.uuid), "telegram")
      assert config["cadences"][type.key] == "daily"
    end

    test "Save after Disconnect does not connect the chat again", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, view, _html} = live(conn, @page)

      :ok = Linking.unlink(user)

      view |> form("#notification-settings-form") |> render_submit()

      refute linked?(site)
    end
  end

  describe "ChannelConfig.update/3" do
    test "works on the row as it stands, not on the user it is handed", %{user: stale, site: site} do
      :ok = Linking.drop_links(stale.uuid)

      # What the delivery worker does: it loaded the user before a send that failed.
      {:ok, updated} =
        ChannelConfig.update(stale, "telegram", &Map.put(&1, "status", "disabled"))

      refute linked?(site)
      assert ChannelConfig.for_channel(updated, "telegram")["status"] == "disabled"
    end

    test "keeps what the session put on the struct", %{user: user} do
      {:ok, updated} =
        ChannelConfig.update(%{user | active_role_uuid: "kept"}, "telegram", & &1)

      assert updated.active_role_uuid == "kept"
    end

    test "answers :not_found for a user that is gone" do
      gone = %{F.person() | uuid: UUIDv7.generate()}

      assert ChannelConfig.update(gone, "telegram", & &1) == {:error, :not_found}
    end
  end

  describe "Auth.update_user_fields/2 with a struct from before the drop" do
    test "a custom field saved after it does not put the link back", %{user: stale, site: site} do
      :ok = Linking.drop_links(stale.uuid)

      {:ok, updated} = Auth.update_user_fields(stale, %{"avatar_crop" => %{"x" => 1}})

      refute linked?(site)
      assert updated.custom_fields["avatar_crop"] == %{"x" => 1}
    end

    test "a key written since is kept, and the struct's session fields come back", %{user: stale} do
      {:ok, _} = Auth.merge_user_custom_fields(stale, %{"later" => "kept"})

      {:ok, updated} =
        Auth.update_user_fields(%{stale | active_role_uuid: "kept"}, %{"field" => "value"})

      assert updated.custom_fields["later"] == "kept"
      assert updated.custom_fields["field"] == "value"
      assert updated.active_role_uuid == "kept"
    end

    test "a new avatar still drops the old crop", %{user: user} do
      {:ok, user} =
        Auth.update_user_fields(user, %{"avatar_file_uuid" => "a", "avatar_crop" => %{"x" => 1}})

      {:ok, updated} = Auth.update_user_fields(user, %{"avatar_file_uuid" => "b"})

      assert updated.custom_fields["avatar_file_uuid"] == "b"
      assert updated.custom_fields["avatar_crop"] == nil
    end
  end

  describe "converting an organization" do
    setup %{site: site} do
      Settings.update_setting("enable_organization_accounts", "true")
      on_exit(fn -> Settings.update_setting("enable_organization_accounts", "false") end)

      org = F.person(%{account_type: "organization", organization_name: "Independent"})
      chat = @chat + 1
      {:ok, _} = Linking.link_chat(org, site, chat)

      %{org: org, chat: chat, created_by: F.person()}
    end

    test "a chat linked before it was managed does not wake up when it is independent again",
         %{org: org, chat: chat, site: site, created_by: created_by} do
      assert Linking.linked_user(site, chat).uuid == org.uuid

      {:ok, _} =
        ManagedOrganizations.host_convert_to_managed(org.uuid, F.person().uuid, created_by)

      {:ok, independent} =
        ManagedOrganizations.host_convert_to_independent(
          org.uuid,
          %{
            email: "new-owner-#{System.unique_integer([:positive])}@example.com",
            password: "BrandNewPassword123!"
          },
          created_by
        )

      refute independent.managed_by_members
      assert Linking.linked_user(site, chat) == nil
    end

    test "a link stored while it was managed is gone when it is independent again", %{
      org: org,
      chat: chat,
      site: site,
      created_by: created_by
    } do
      {:ok, _} =
        ManagedOrganizations.host_convert_to_managed(org.uuid, F.person().uuid, created_by)

      # A row from before links were dropped on conversion: stored, inert.
      {:ok, _} =
        ChannelConfig.update(
          org,
          "telegram",
          &Map.merge(&1, %{"site_chat_id" => to_string(chat), "site_connection_uuid" => site})
        )

      {:ok, _} =
        ManagedOrganizations.host_convert_to_independent(
          org.uuid,
          %{
            email: "new-owner-#{System.unique_integer([:positive])}@example.com",
            password: "BrandNewPassword123!"
          },
          created_by
        )

      assert Linking.linked_user(site, chat) == nil
    end
  end
end
