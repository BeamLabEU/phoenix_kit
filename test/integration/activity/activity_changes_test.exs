defmodule PhoenixKit.Integration.ActivityChangesTest do
  @moduledoc """
  The `changes:` option stored for real, `log_user_change/4` writing the
  reserved shape, and both Activity pages rendering it.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  setup do
    # The first account in a fresh sandbox is auto-promoted to Owner.
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, _} = Auth.admin_confirm_user(seed)
    :ok
  end

  defp unique_email, do: "c#{System.unique_integer([:positive])}@example.com"

  defp admin_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, "Admin")
    Repo.get!(Auth.User, user.uuid)
  end

  describe "log/3 with changes:" do
    test "stores the diff under the reserved key and round-trips it" do
      user = admin_user()
      changeset = Ecto.Changeset.change(user, first_name: "Ada", last_name: "Lovelace")

      {:ok, entry} =
        Activity.log("users", "user.renamed",
          actor_uuid: user.uuid,
          metadata: %{"actor_role" => "admin"},
          changes: changeset
        )

      stored = Repo.get!(Activity.Entry, entry.uuid)

      assert stored.metadata["changes"] == %{
               "first_name" => %{"from" => user.first_name, "to" => "Ada"},
               "last_name" => %{"from" => user.last_name, "to" => "Lovelace"}
             }

      assert stored.metadata["actor_role"] == "admin"
    end

    # U+0000 is valid UTF-8, Jason writes it as \u0000, and jsonb refuses
    # that: the insert failed and the entry was lost.
    test "a NUL in a value or in the metadata does not lose the entry" do
      assert {:ok, entry} =
               Activity.log("shop", "order.updated",
                 metadata: %{"note" => "x\0y", "tags" => ["a\0"], "k\0" => 1},
                 changes: {%{note: "ok"}, %{note: "a\0b"}}
               )

      stored = Repo.get!(Activity.Entry, entry.uuid)
      assert stored.metadata["changes"]["note"]["to"] == "a\uFFFDb"
      assert stored.metadata["note"] == "x\uFFFDy"
      assert stored.metadata["tags"] == ["a\uFFFD"]
      assert stored.metadata["k\uFFFD"] == 1

      assert {:ok, [_]} = Activity.log_many([%{action: "x.updated", metadata: %{"n" => "\0"}}])
    end

    test "log/1 and log_many/2 take the :changes key too" do
      {:ok, entry} = Activity.log(%{action: "x.updated", changes: {%{a: 1}, %{a: 2}}})

      assert Repo.get!(Activity.Entry, entry.uuid).metadata["changes"] == %{
               "a" => %{"from" => 1, "to" => 2}
             }

      {:ok, [one]} = Activity.log_many([%{action: "x.updated", changes: {%{a: 1}, %{a: 3}}}])
      assert Repo.get!(Activity.Entry, one.uuid).metadata["changes"]["a"]["to"] == 3
    end
  end

  describe "log_user_change/4" do
    test "writes the reserved changes map, never the flat pairs" do
      user = admin_user()
      changeset = Ecto.Changeset.change(user, first_name: "Grace", custom_fields: %{"x" => 1})

      {:ok, entry} =
        Activity.log_user_change("user.profile_updated", user, changeset, actor_role: "admin")

      assert entry.metadata["changes"] == %{
               "first_name" => %{"from" => user.first_name, "to" => "Grace"}
             }

      assert entry.metadata["actor_role"] == "admin"
      refute Map.has_key?(entry.metadata, "first_name_from")
    end

    test "nothing changed is :noop" do
      user = admin_user()
      changeset = Ecto.Changeset.change(user, custom_fields: %{"x" => 1})
      assert Activity.log_user_change("user.profile_updated", user, changeset) == :noop
    end
  end

  describe "rendering" do
    setup do
      admin = admin_user()

      {:ok, entry} =
        Activity.log("orders", "order.updated",
          actor_uuid: admin.uuid,
          resource_type: "order",
          resource_uuid: Ecto.UUID.generate(),
          metadata: %{"name" => "Order 7"},
          changes:
            {%{status: "draft", note: nil, api_key: "pk_old", body: "short"},
             %{
               status: "sent",
               note: "Call first",
               api_key: "pk_new",
               body: String.duplicate("z", 300)
             }}
        )

      %{admin: admin, entry: entry}
    end

    test "the feed summarizes changes, cutting long sides", %{conn: conn, admin: admin} do
      {:ok, _lv, html} = live(log_in_user(conn, admin), Routes.path("/admin/activity"))

      # Three changes shown alphabetically (api_key, body, note), one more counted.
      assert html =~ "Api key changed"
      assert html =~ "Body short → " <> String.duplicate("z", 60) <> "…"
      refute html =~ String.duplicate("z", 61)
      assert html =~ "Note — → Call first"
      assert html =~ "+1"
      refute html =~ "pk_new"
    end

    test "the entry page shows a Before/After row per field", %{
      conn: conn,
      admin: admin,
      entry: entry
    } do
      {:ok, _lv, html} =
        live(log_in_user(conn, admin), Routes.path("/admin/activity/#{entry.uuid}"))

      assert html =~ "What changed"
      assert html =~ "draft"
      assert html =~ "sent"
      assert html =~ "Call first"
      # The page keeps the stored value whole (300 is under the 500 cap).
      assert html =~ String.duplicate("z", 300)
      refute html =~ "pk_old"
      refute html =~ "pk_new"
    end
  end
end
