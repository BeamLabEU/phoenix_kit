defmodule PhoenixKitWeb.Live.Users.LibraryActivityUITest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, LibraryOperations}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.{Format, Routes}

  setup do
    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [], plugins: []})
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)

    {:ok, role} =
      Roles.create_role(%{name: "Library activity UI #{System.unique_integer([:positive])}"})

    for key <- ~w(storage storage.create_library),
        do: Permissions.grant_permission(role.uuid, key)

    user = user!(role)
    other = user!(role)

    {:ok, library} =
      Libraries.create_user_library(Scope.for_user(user), %{"name" => "My checked library"})

    {:ok, foreign} =
      Libraries.create_user_library(Scope.for_user(other), %{"name" => "Secret other library"})

    %{user: user, other: other, library: library, foreign: foreign, role: role}
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "activity-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp path(query \\ %{}) do
    Routes.path("/profile/settings/media") <>
      if query == %{}, do: "", else: "?" <> URI.encode_query(query)
  end

  test "Activity is a nested tab; verification defaults to originals and its log survives reload",
       ctx do
    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), path())
    assert has_element?(view, "[role=tab][phx-value-view=activity]", "Activity")

    view
    |> element("[phx-click=verify_library][phx-value-uuid='#{ctx.library.uuid}']")
    |> render_click()

    assert has_element?(view, "#profile-library-settings-activity-verify")

    assert has_element?(
             view,
             "#profile-library-settings-activity-mode option[value=presence][selected]"
           )

    refute has_element?(view, "#profile-library-settings-activity-previews[checked]")
    assert render(view) =~ "without changing files"

    view
    |> form("#profile-library-settings-activity-verify",
      verification: %{library_uuid: ctx.library.uuid, mode: "presence"}
    )
    |> render_submit()

    [run] = LibraryOperations.list(Scope.for_user(ctx.user)).runs
    assert run.args["mode"] == "presence"
    refute run.args["include_previews"]
    assert has_element?(view, "#profile-library-settings-activity-log", "Queued")
    assert has_element?(view, "#profile-library-settings-activity-log", "Operation started")
    assert render(view) =~ "Originals only"

    {:ok, reloaded, _} =
      live(
        log_in_user(build_conn(), ctx.user),
        path(%{"media_view" => "activity", "run" => run.uuid})
      )

    assert has_element?(reloaded, "#profile-library-settings-activity-log", "Operation started")
    refute render(reloaded) =~ ctx.foreign.name
  end

  test "verification choices identify library content size and storage", ctx do
    n = System.unique_integer([:positive])

    {:ok, _file} =
      Storage.create_file(%{
        original_file_name: "photo.png",
        file_name: "picker-#{n}.png",
        file_path: "picker/#{n}.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        size: 2048,
        status: "active",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        user_uuid: ctx.user.uuid,
        library_uuid: ctx.library.uuid
      })

    {:ok, empty} =
      Libraries.create_user_library(Scope.for_user(ctx.user), %{"name" => "Empty library"})

    {:ok, view, _} =
      live(
        log_in_user(ctx.conn, ctx.user),
        path(%{"media_view" => "activity", "verify" => ctx.library.uuid})
      )

    selector = "#profile-library-settings-activity-library option[value='#{ctx.library.uuid}']"
    assert has_element?(view, selector, "My checked library · 1 file")
    assert has_element?(view, selector, Format.bytes(2048))
    assert has_element?(view, selector, "#{Settings.get_project_title()}'s storage")

    assert has_element?(
             view,
             "#profile-library-settings-activity-library option[value='#{empty.uuid}']",
             "Empty library · 0 files · 0 B"
           )

    refute has_element?(
             view,
             "#profile-library-settings-activity-library option[value='#{ctx.foreign.uuid}']"
           )
  end

  test "View log opens a visible dialog and keeps it open across refreshes", ctx do
    {:ok, run, _} = LibraryOperations.verify(Scope.for_user(ctx.user), ctx.library.uuid, %{})
    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), path(%{"media_view" => "activity"}))
    refute has_element?(view, "dialog#profile-library-settings-activity-log")

    view |> element("#library-operation-#{run.uuid} [phx-click=run_details]") |> render_click()

    assert has_element?(
             view,
             "dialog#profile-library-settings-activity-log[data-show=true]",
             "Operation started"
           )

    assert has_element?(
             view,
             "dialog#profile-library-settings-activity-log [phx-click=close_run]"
           )

    log_path = assert_patch(view)
    assert URI.decode_query(URI.parse(log_path).query)["run"] == run.uuid

    send(view.pid, :refresh_library_storage)

    assert has_element?(
             view,
             "dialog#profile-library-settings-activity-log[data-show=true]",
             "Operation started"
           )

    view
    |> element("dialog#profile-library-settings-activity-log [phx-click=close_run]")
    |> render_click()

    refute has_element?(view, "dialog#profile-library-settings-activity-log")
    closed_path = assert_patch(view)
    refute Map.has_key?(URI.decode_query(URI.parse(closed_path).query), "run")
    render_patch(view, log_path)

    assert has_element?(
             view,
             "dialog#profile-library-settings-activity-log[data-show=true]",
             "Operation started"
           )
  end

  test "deep verification and previews are explicit choices; cancellation cannot bypass the cooldown",
       ctx do
    {:ok, view, _} =
      live(
        log_in_user(ctx.conn, ctx.user),
        path(%{"media_view" => "activity", "verify" => ctx.library.uuid})
      )

    view
    |> form("#profile-library-settings-activity-verify",
      verification: %{library_uuid: ctx.library.uuid, mode: "checksum", include_previews: true}
    )
    |> render_submit()

    [run] = LibraryOperations.list(Scope.for_user(ctx.user)).runs
    assert run.args["mode"] == "checksum"
    assert run.args["include_previews"]
    assert render(view) =~ "Originals and previews"
    view |> element("[phx-click=run_control][phx-value-action=pause]") |> render_click()
    assert Jobs.get_run(run.uuid).state == "paused"
    view |> element("[phx-click=run_control][phx-value-action=resume]") |> render_click()
    assert Jobs.get_run(run.uuid).state == "queued"
    view |> element("[phx-click=run_control][phx-value-action=cancel]") |> render_click()
    assert Jobs.get_run(run.uuid).state == "cancelled"
    refute has_element?(view, "[phx-click=run_control][phx-value-action=retry]")
    assert LibraryOperations.list(Scope.for_user(ctx.user)).total == 1
    view |> element("dialog [phx-click=close_run]") |> render_click()
    view |> element("[phx-click=open_verify]") |> render_click()
    assert render(view) =~ "can be checked again on"

    assert has_element?(
             view,
             "#profile-library-settings-activity-verify button[disabled]",
             "Start verification"
           )
  end

  test "global busy state disables new checks and forged submissions cannot bypass it", ctx do
    {:ok, _, _} = LibraryOperations.verify(Scope.for_user(ctx.user), ctx.library.uuid, %{})

    {:ok, view, _} =
      live(
        log_in_user(ctx.conn, ctx.other),
        path(%{"media_view" => "activity", "verify" => ctx.foreign.uuid})
      )

    assert has_element?(
             view,
             "#profile-library-settings-activity-verify button[disabled]",
             "Start verification"
           )

    assert render(view) =~ "Only one verification can be active across all libraries"
    refute render(view) =~ ctx.library.name

    view
    |> form("#profile-library-settings-activity-verify",
      verification: %{library_uuid: ctx.foreign.uuid, mode: "checksum"}
    )
    |> render_submit()

    assert render(view) =~ "Only one verification can be active across all libraries"
    assert LibraryOperations.list(Scope.for_user(ctx.other)).total == 0
    refute render(view) =~ ctx.library.name
  end

  test "forged run details and verification inputs expose nothing from another library", ctx do
    {:ok, own, _} = LibraryOperations.verify(Scope.for_user(ctx.user), ctx.library.uuid, %{})

    {:ok, foreign, _} =
      Jobs.System.start(PhoenixKit.Modules.Storage.Jobs.Reconcile, {"library", ctx.foreign.uuid})

    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.user), path(%{"media_view" => "activity"}))

    view
    |> element("#library-operation-#{own.uuid} [phx-click=run_details]")
    |> render_click(%{"uuid" => foreign.uuid})

    assert render(view) =~ "you no longer have access"
    refute has_element?(view, "#profile-library-settings-activity-log")
    refute render(view) =~ ctx.foreign.name
    view |> element("[phx-click=open_verify]") |> render_click()

    view
    |> form("#profile-library-settings-activity-verify",
      verification: %{library_uuid: ctx.library.uuid, mode: "presence"}
    )
    |> render_submit(%{
      "verification" => %{"library_uuid" => ctx.foreign.uuid, "mode" => "presence"}
    })

    assert render(view) =~ "Verification could not be started"
    assert LibraryOperations.list(Scope.for_user(ctx.other)).total == 1
  end

  test "revoked ownership is checked again when a control event arrives", ctx do
    {:ok, run, _} = LibraryOperations.verify(Scope.for_user(ctx.user), ctx.library.uuid, %{})

    {:ok, view, _} =
      live(
        log_in_user(ctx.conn, ctx.user),
        path(%{"media_view" => "activity", "run" => run.uuid})
      )

    Repo.update_all(from(l in Storage.Library, where: l.uuid == ^ctx.library.uuid),
      set: [owner_uuid: ctx.other.uuid, is_default: false]
    )

    view |> element("[phx-click=run_control][phx-value-action=cancel]") |> render_click()
    assert Jobs.get_run(run.uuid).state == "queued"
    refute has_element?(view, "#profile-library-settings-activity-log")
    assert render(view) =~ "no longer have access"
  end

  test "copy jobs are visible, and history pages and selected logs are scoped to library membership",
       ctx do
    {:ok, run, _} =
      Jobs.System.start(PhoenixKit.Modules.Storage.Jobs.Reconcile, {"library", ctx.library.uuid})

    {:ok, view, html} =
      live(
        log_in_user(ctx.conn, ctx.user),
        path(%{"media_view" => "activity", "run" => run.uuid})
      )

    assert html =~ "Copying and updating"
    assert has_element?(view, "#profile-library-settings-activity-log", "Operation started")

    {:ok, other_view, _} =
      live(
        log_in_user(build_conn(), ctx.other),
        path(%{"media_view" => "activity", "run" => run.uuid})
      )

    refute has_element?(other_view, "#profile-library-settings-activity-log")
    refute render(other_view) =~ ctx.library.name
  end
end
