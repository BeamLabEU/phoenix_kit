defmodule PhoenixKitWeb.Live.StorageHistoryTest do
  @moduledoc """
  The History tab of Settings → Media: who changed the storage settings and what the
  storage jobs did, read from the Activity log; loaded when the tab opens, filtered,
  paged, and kept current as entries arrive.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Jobs
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.Jobs.Reconcile
  alias PhoenixKit.Modules.Storage.{Libraries, Profiles}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user), user: user, actor: [actor_uuid: user.uuid]}
  end

  defp history(conn) do
    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
    render_patch(view, Routes.path("/admin/settings/media?tab=history"))
    view
  end

  test "lists who changed what, newest first, with the person and the change", ctx do
    {:ok, profile} = Profiles.create_profile(%{name: "Cold storage"}, ctx.actor)
    {:ok, _} = Profiles.update_profile(profile, %{copies_local: 2}, ctx.actor)

    view = history(ctx.conn)
    html = render(view)

    assert html =~ "storage.profile.created"
    assert html =~ "storage.profile.updated"
    assert html =~ ctx.user.email
    assert html =~ "Copies local"
    assert html =~ "1 → 2"

    entry =
      Repo.one!(
        from e in Entry,
          where: e.action == "storage.profile.updated" and e.resource_uuid == ^profile.uuid
      )

    assert has_element?(view, "#media-history-list-#{entry.uuid}", "Cold storage")
  end

  test "is empty of other modules' entries", ctx do
    PhoenixKit.Activity.log("posts", "post.created", actor_uuid: ctx.user.uuid)

    {:ok, _} =
      Libraries.create_system_library(
        %{name: "History #{System.unique_integer([:positive])}"},
        ctx.actor
      )

    html = ctx.conn |> history() |> render()

    refute html =~ "post.created"
    assert html =~ "storage.library.created"
  end

  test "includes global storage settings with their actor, but excludes unrelated settings",
       ctx do
    view = history(ctx.conn)

    {:ok, _} =
      Settings.update_boolean_setting("storage_annotated_thumbnails_enabled", true,
        actor_uuid: ctx.user.uuid
      )

    {:ok, _} =
      Settings.update_setting("history_unrelated_setting", "changed", actor_uuid: ctx.user.uuid)

    assert render(view) =~ "storage_annotated_thumbnails_enabled"
    refute render(view) =~ "history_unrelated_setting"
    view |> form("#media-history-filter", %{"filter" => "changes"}) |> render_change()
    assert render(view) =~ "storage_annotated_thumbnails_enabled"
    assert render(view) =~ ctx.user.email
    view |> form("#media-history-filter", %{"filter" => "runs"}) |> render_change()
    refute render(view) =~ "storage_annotated_thumbnails_enabled"
  end

  test "periodic refresh picks up entries committed by a caller-owned transaction", ctx do
    view = history(ctx.conn)

    {:ok, _} =
      Repo.transaction(fn -> Profiles.create_profile(%{name: "Quiet commit"}, ctx.actor) end)

    refute render(view) =~ "Quiet commit"
    send(view.pid, :refresh_library_sync)

    # The refresh reaches the tab as a `send_update/2` the page sends to itself, so it
    # lands a moment after the page has handled the message: wait for it, not for luck.
    assert eventually(fn -> render(view) =~ "Quiet commit" end)
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end

  test "saving global storage settings through the page records the signed-in actor", ctx do
    {:ok, view, _} = live(ctx.conn, Routes.path("/admin/settings/media"))
    render_change(view, "update_storage_form", %{"form_max_upload_size_mb" => "1234"})
    render_click(view, "apply_storage_settings")

    entry =
      Repo.one!(
        from e in Entry,
          where: e.action == "setting.changed",
          where: fragment("?->>'key' = 'storage_max_upload_size_mb'", e.metadata),
          order_by: [desc: e.uuid],
          limit: 1
      )

    assert entry.actor_uuid == ctx.user.uuid
    assert entry.metadata["source"] == "settings"
    render_patch(view, Routes.path("/admin/settings/media?tab=history"))
    assert has_element?(view, "#media-history-list-#{entry.uuid}", "storage_max_upload_size_mb")
  end

  test "a historical actor is identified as a user rather than the system", ctx do
    actor = Ecto.UUID.generate()

    {:ok, entry} =
      Audit.log("storage.profile.created", "storage_profile", Ecto.UUID.generate(),
        actor_uuid: actor
      )

    view = history(ctx.conn)
    row = "#media-history-list-#{entry.uuid}"
    assert has_element?(view, row, "User #{String.slice(actor, 0, 8)}")
    refute has_element?(view, row, "System")
  end

  test "media managers without dashboard access receive no forbidden Activity links", ctx do
    admin = Roles.get_role_by_name("Admin")
    :ok = Permissions.revoke_permission(admin.uuid, "dashboard")
    {:ok, profile} = Profiles.create_profile(%{name: "Restricted details"}, ctx.actor)
    view = history(ctx.conn)
    assert render(view) =~ profile.name
    refute has_element?(view, "#media-history-list a[title='View details']")
  end

  test "every field of an entry can be read in place, with no access to the Activity page", ctx do
    admin = Roles.get_role_by_name("Admin")
    :ok = Permissions.revoke_permission(admin.uuid, "dashboard")

    {:ok, bucket} =
      Storage.create_bucket(
        %{
          name: "Many fields",
          provider: "local",
          endpoint: Path.join(System.tmp_dir!(), "pk_history_fields"),
          enabled: true,
          priority: 0
        },
        ctx.actor
      )

    {:ok, _} =
      Storage.update_bucket(
        bucket,
        %{name: "Many fields v2", priority: 3, max_size_mb: 500, region: "eu"},
        ctx.actor
      )

    view = history(ctx.conn)

    # the one-line summary stops at three fields; the disclosure holds all four
    assert has_element?(view, "#media-history-list details summary", "Show every field")

    for field <- ["Name", "Priority", "Max size mb", "Region"] do
      assert has_element?(view, "#media-history-list details dt", field)
    end

    refute has_element?(view, "#media-history-list a[title='View details']")
  end

  test "forged pagination and filters cannot crash or overflow the query", ctx do
    view = history(ctx.conn)
    target = find_live_child_target(view)

    for page <- [1, %{}, "999999999999999999999999999999999999999999", "-1", "1x"] do
      render_click(with_target(view, target), "page", %{"page" => page})
      assert has_element?(view, "#media-history-list")
    end

    render_change(with_target(view, target), "filter", %{"filter" => "forged"})
    assert has_element?(view, "#media-history-list")
  end

  defp find_live_child_target(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#media-history-filter")
    |> Floki.attribute("phx-target")
    |> hd()
    |> String.to_integer()
  end

  test "the filter separates settings changes from job runs", ctx do
    {:ok, _} = Profiles.create_profile(%{name: "Filtered"}, ctx.actor)

    {:ok, library} =
      Libraries.create_system_library(
        %{name: "Runs #{System.unique_integer([:positive])}"},
        ctx.actor
      )

    {:ok, _run, :started} = Jobs.System.start(Reconcile, {"library", to_string(library.uuid)})

    view = history(ctx.conn)
    assert render(view) =~ "job.started"
    assert render(view) =~ "storage.profile.created"

    view |> form("#media-history-filter", %{"filter" => "runs"}) |> render_change()
    assert render(view) =~ "job.started"
    refute render(view) =~ "storage.profile.created"

    view |> form("#media-history-filter", %{"filter" => "changes"}) |> render_change()
    refute render(view) =~ "job.started"
    assert render(view) =~ "storage.profile.created"
  end

  test "pages through a long history", ctx do
    for n <- 1..30,
        do:
          Audit.log(
            "storage.profile.created",
            "storage_profile",
            Ecto.UUID.generate(),
            ctx.actor,
            %{"name" => "P#{n}"}
          )

    view = history(ctx.conn)
    assert render(view) =~ "Page 1 of 2"

    view |> element("#media-history button", "Next") |> render_click()
    assert render(view) =~ "Page 2 of 2"
  end

  test "refresh clamps a page whose entries have been removed", ctx do
    for n <- 1..30,
        do:
          Audit.log("job.started", "job_run", Ecto.UUID.generate(), [], %{"title" => "Run #{n}"})

    view = history(ctx.conn)
    view |> form("#media-history-filter", %{"filter" => "runs"}) |> render_change()
    view |> element("#media-history button", "Next") |> render_click()
    assert render(view) =~ "Page 2 of 2"
    Repo.delete_all(from e in Entry, where: e.resource_type == "job_run")
    send(view.pid, :refresh_library_sync)
    assert has_element?(view, "#media-history-list", "Nothing recorded yet.")
    refute render(view) =~ "Page 2"
  end

  test "follows the log while the tab is open", ctx do
    view = history(ctx.conn)
    refute render(view) =~ "Brand new profile"

    {:ok, _} = Profiles.create_profile(%{name: "Brand new profile"}, ctx.actor)

    assert render(view) =~ "Brand new profile"
  end

  test "reads nothing until the tab is opened", ctx do
    {:ok, _} = Profiles.create_profile(%{name: "Not yet"}, ctx.actor)
    {:ok, view, _html} = live(ctx.conn, Routes.path("/admin/settings/media"))

    refute render(view) =~ "storage.profile.created"
    refute has_element?(view, "#media-history-list")
  end

  test "the Settings changes made through the page are attributed to the person", ctx do
    view = history(ctx.conn)
    render_patch(view, Routes.path("/admin/settings/media?tab=profiles"))
    view |> element("#media-profiles button", "New profile") |> render_click()

    view
    |> form("#media-profiles-new", %{"profile" => %{"name" => "Made in the UI"}})
    |> render_submit()

    render_patch(view, Routes.path("/admin/settings/media?tab=history"))
    html = render(view)

    assert html =~ "storage.profile.created"

    entry =
      Repo.one!(
        from e in Entry,
          where: e.action == "storage.profile.created",
          where: fragment("?->>'name' = ?", e.metadata, "Made in the UI")
      )

    assert entry.actor_uuid == ctx.user.uuid
    assert html =~ "Made in the UI"
  end

  test "each row opens its entry on the Activity page", ctx do
    {:ok, profile} = Profiles.create_profile(%{name: "Linked"}, ctx.actor)
    {:ok, _} = Profiles.update_profile(profile, %{copies_local: 3}, ctx.actor)

    entry =
      Repo.one!(
        from e in Entry,
          where:
            e.action == "storage.profile.updated" and e.resource_uuid == ^to_string(profile.uuid)
      )

    {:ok, view, html} = live(ctx.conn, Routes.path("/admin/activity/#{entry.uuid}"))

    assert html =~ "storage.profile.updated"
    assert render(view) =~ "storage_profile"
    assert html =~ "Copies local"
  end
end
