defmodule PhoenixKitWeb.Live.Users.OwnStorageUITest do
  @moduledoc """
  The Media tab's creation form for a library on the user's own storage
  (V206): closed until "Create library" is pressed, shown only to a user who
  may use it, asking for an integration and a bucket and nothing the integration
  already knows, a bucket list read from the integration, both modes and several
  integrations end to end through the component, a failed bucket check creating
  nothing, the choice shown on the library and never changeable, and the
  admin's view of it (the toggle, and a Storage column that names the bucket and
  never a credential).
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Components.LibrarySettings

  setup do
    original = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, "test-secret-for-own-storage-ui")

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :secret_key_base, original),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)
    end)

    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", true)

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Own storage UI #{n}"})

    for key <- ~w(storage storage.create_library storage.own_storage integrations) do
      {:ok, _} = Permissions.grant_permission(role.uuid, key)
    end

    {:ok, plain} = Roles.create_role(%{name: "Plain UI #{n}"})

    for key <- ~w(storage storage.create_library) do
      {:ok, _} = Permissions.grant_permission(plain.uuid, key)
    end

    {:ok, site} =
      Storage.create_bucket(%{
        name: "ui-site-#{n}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_own_storage_ui"),
        enabled: true
      })

    %{role: role, plain: plain, site: site}
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "own-ui-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp connection!(user, attrs \\ %{}, name \\ "mine") do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("object_storage", name, nil, owner: {:user, user.uuid})

    {:ok, _} =
      Integrations.save_setup(
        uuid,
        Map.merge(%{"access_key" => "AKIA", "secret_key" => "secret-value"}, attrs),
        nil,
        owner: {:user, user.uuid}
      )

    uuid
  end

  # The component mounted the way a LiveView would, with a probe that answers
  # (and, when asked, a bucket listing that answers too).
  defp mount!(user, probe \\ fn _params -> :ok end, list \\ nil) do
    {:ok, socket} =
      LibrarySettings.update(
        %{id: "profile-library-settings", scope: scope(user), probe: probe, list: list},
        %Phoenix.LiveView.Socket{}
      )

    socket
  end

  defp event(socket, name, params \\ %{}) do
    {:noreply, socket} = LibrarySettings.handle_event(name, params, socket)
    socket
  end

  defp form_change(socket, library) do
    {:noreply, socket} =
      LibrarySettings.handle_event("form_change", %{"library" => library}, socket)

    socket
  end

  defp create(socket, library) do
    {:noreply, socket} = LibrarySettings.handle_event("create", %{"library" => library}, socket)
    socket
  end

  # The form as the browser posts it: one row of the library's buckets per
  # integration, `targets[0]`, `targets[1]`…
  defp own(connection, extra \\ %{}) do
    storage =
      Map.merge(
        %{
          "kind" => "own",
          "mode" => "only",
          "targets" => %{"0" => %{"integration_uuid" => connection, "bucket_name" => "my-photos"}}
        },
        extra
      )

    %{"name" => "Photos", "storage" => storage}
  end

  defp open_create(%{} = socket), do: event(socket, "open_create")

  # The component's markup for the state a socket is in.
  defp html(socket) do
    render_component(
      &LibrarySettings.render/1,
      Map.put(socket.assigns, :myself, %Phoenix.LiveComponent.CID{cid: 1})
    )
  end

  describe "who sees it" do
    test "the page is the list; the form opens on Create library", %{conn: conn, role: role} do
      user = user!(role)

      {:ok, view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      assert html =~ "Create library"
      refute html =~ "New library"
      refute html =~ "Where its files are kept"

      html = view |> element("#profile-library-settings-open-create") |> render_click()

      assert html =~ "New library"
      assert html =~ "Where its files are kept"
      assert html =~ "My own storage"

      html =
        view
        |> element("#profile-library-settings-create-modal button", "Cancel")
        |> render_click()

      refute html =~ "New library"
    end

    test "a user who may not sees only the plain form", %{conn: conn, plain: plain} do
      user = user!(plain)

      {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      html = view |> element("#profile-library-settings-open-create") |> render_click()

      assert html =~ "New library"
      refute html =~ "Where its files are kept"
      refute html =~ "My own storage"
    end

    test "nor when the site has not allowed it", %{conn: conn, role: role} do
      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", false)
      user = user!(role)

      {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      html = view |> element("#profile-library-settings-open-create") |> render_click()

      refute html =~ "My own storage"
    end
  end

  describe "the form" do
    test "lists the user's own integrations only", %{role: role} do
      user = user!(role)
      other = user!(role)
      mine = connection!(user)
      _theirs = connection!(other)

      socket = mount!(user)

      assert [%{uuid: ^mine}] = socket.assigns.connections
    end

    test "with no integration it sends the user to add one", %{
      conn: conn,
      role: role
    } do
      user = user!(role)

      {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))
      view |> element("#profile-library-settings-open-create") |> render_click()

      html =
        view
        |> form("#profile-library-settings-create", %{
          library: %{name: "P", storage: %{kind: "own"}}
        })
        |> render_change()

      assert html =~ "Connect your storage first"
      assert html =~ "Add an integration"
      assert html =~ ~s(integrations/new?provider=object_storage)
      refute html =~ "List buckets"
    end

    test "asks for an integration and a bucket, and nothing the integration already knows", %{
      conn: conn,
      role: role
    } do
      user = user!(role)
      _ = connection!(user, %{"endpoint" => "t3.storage.dev"}, "Tigris for photos")

      {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))
      view |> element("#profile-library-settings-open-create") |> render_click()

      html =
        view
        |> form("#profile-library-settings-create", %{
          library: %{name: "P", storage: %{kind: "own"}}
        })
        |> render_change()

      assert html =~ "Integration"
      assert html =~ "Bucket"
      assert html =~ "List buckets"
      assert html =~ "How it is used"
      assert html =~ "More backup storage can be added later"
      refute html =~ "cannot be changed once it is created"
      # The one integration is already chosen, and says what it is.
      assert html =~ "Tigris for photos"
      assert html =~ "Tigris · t3.storage.dev"
      refute html =~ "Provider"
      refute html =~ "Region"
      refute html =~ "Endpoint"
    end

    test "lists the buckets of the integration to choose from", %{role: role} do
      user = user!(role)
      uuid = connection!(user)
      listing = fn _bucket -> {:ok, ["archive", "photos"]} end

      socket =
        user
        |> mount!(fn _ -> :ok end, listing)
        |> open_create()
        |> form_change(%{"storage" => %{"kind" => "own"}})
        |> event("list_buckets", %{"index" => "0"})

      assert {^uuid, {:ok, ["archive", "photos"]}} = socket.assigns.bucket_lists[0]

      html = html(socket)
      assert html =~ "Choose a bucket..."
      assert html =~ "2 buckets found."
      assert html =~ "Type a name"

      # Typing a name instead puts the text field back.
      socket = event(socket, "type_bucket", %{"index" => "0"})
      refute Map.has_key?(socket.assigns.bucket_lists, 0)
    end

    test "a key that may not list buckets says to type the name", %{role: role} do
      user = user!(role)
      _ = connection!(user)

      refused = fn _bucket ->
        {:error, "This key is not allowed to list buckets (a key limited to one bucket cannot)."}
      end

      socket =
        user
        |> mount!(fn _ -> :ok end, refused)
        |> open_create()
        |> form_change(%{"storage" => %{"kind" => "own"}})
        |> event("list_buckets", %{"index" => "0"})

      html = html(socket)
      assert html =~ "not allowed to list buckets"
      # The text field stays: nothing is lost.
      assert html =~ ~s(name="library[storage][targets][0][bucket_name]")
    end

    test "an integration with no buckets says so", %{role: role} do
      user = user!(role)
      _ = connection!(user)

      socket =
        user
        |> mount!(fn _ -> :ok end, fn _ -> {:ok, []} end)
        |> open_create()
        |> event("list_buckets", %{"index" => "0"})

      assert {_, {:error, message}} = socket.assigns.bucket_lists[0]
      assert message =~ "No buckets found"
    end

    test "choosing another integration drops the bucket and its list", %{role: role} do
      user = user!(role)
      first = connection!(user, %{}, "first")
      second = connection!(user, %{}, "second")

      socket =
        user
        |> mount!(fn _ -> :ok end, fn _ -> {:ok, ["a-bucket"]} end)
        |> open_create()
        |> form_change(%{
          "name" => "P",
          "storage" => %{
            "kind" => "own",
            "targets" => %{"0" => %{"integration_uuid" => first, "bucket_name" => "a-bucket"}}
          }
        })
        |> event("list_buckets", %{"index" => "0"})

      assert Map.has_key?(socket.assigns.bucket_lists, 0)
      assert [%{"bucket_name" => "a-bucket"}] = socket.assigns.form["targets"]

      # Another integration: the old bucket named one of the other account.
      socket =
        form_change(socket, %{
          "storage" => %{
            "targets" => %{"0" => %{"integration_uuid" => second, "bucket_name" => "a-bucket"}}
          }
        })

      assert [%{"integration_uuid" => ^second, "bucket_name" => ""}] =
               socket.assigns.form["targets"]

      refute Map.has_key?(socket.assigns.bucket_lists, 0)
    end

    test "what the user typed is kept while they stay on the integration", %{role: role} do
      user = user!(role)
      uuid = connection!(user)

      socket =
        user
        |> mount!()
        |> open_create()
        |> form_change(%{
          "name" => "P",
          "storage" => %{
            "kind" => "own",
            "targets" => %{"0" => %{"integration_uuid" => uuid, "bucket_name" => "typed-name"}}
          }
        })
        |> form_change(%{"name" => "P2", "storage" => %{"mode" => "backup"}})

      assert socket.assigns.form["name"] == "P2"
      assert socket.assigns.form["mode"] == "backup"
      assert [%{"bucket_name" => "typed-name"}] = socket.assigns.form["targets"]
    end

    test "more integrations can be added up to the limit, and removed", %{role: role} do
      user = user!(role)
      socket = user |> mount!() |> open_create()

      socket = socket |> event("add_target") |> event("add_target") |> event("add_target")
      assert length(socket.assigns.form["targets"]) == 3

      socket = event(socket, "remove_target", %{"index" => "1"})
      assert length(socket.assigns.form["targets"]) == 2

      socket =
        socket
        |> event("remove_target", %{"index" => "0"})
        |> event("remove_target", %{"index" => "0"})

      assert length(socket.assigns.form["targets"]) == 1
    end
  end

  describe "creating" do
    test "only mode: the library, its bucket and its profile", %{role: role} do
      user = user!(role)
      socket = user |> mount!() |> open_create() |> create(own(connection!(user)))

      assert {:success, message} = socket.assigns.message
      assert message =~ "Photos"

      assert [%{library: library}] = socket.assigns.owned

      assert %{mode: :only, bucket: %{bucket_name: "my-photos"}, buckets: [_]} =
               socket.assigns.own_storage[to_string(library.uuid)]

      # The form closes and starts over.
      assert socket.assigns.dialog == nil
      assert socket.assigns.form["kind"] == "site"
    end

    test "the bucket takes its provider, region and endpoint from the integration", %{role: role} do
      user = user!(role)

      uuid =
        connection!(user, %{
          "service" => "cloudflare_r2",
          "account_id" => "acct",
          "endpoint" => "acct.r2.cloudflarestorage.com",
          "region" => "auto"
        })

      socket = user |> mount!() |> create(own(uuid))

      assert [%{library: library}] = socket.assigns.owned
      %{bucket: bucket} = socket.assigns.own_storage[to_string(library.uuid)]
      assert bucket.provider == "r2"
      assert bucket.region == "auto"
      assert bucket.endpoint == "acct.r2.cloudflarestorage.com"
      assert bucket.integration_uuid == uuid
    end

    test "backup mode", %{role: role, site: site} do
      user = user!(role)
      socket = user |> mount!() |> create(own(connection!(user), %{"mode" => "backup"}))

      assert [%{library: library}] = socket.assigns.owned
      assert %{mode: :backup} = socket.assigns.own_storage[to_string(library.uuid)]

      profile = Profiles.get_profile(library.storage_profile_uuid)
      assert Enum.any?(profile.buckets, &(to_string(&1.bucket_uuid) == to_string(site.uuid)))
    end

    test "a copy on a second integration: the first is main, the second a backup", %{role: role} do
      user = user!(role)
      aws = connection!(user, %{"service" => "aws_s3"}, "aws")
      tigris = connection!(user, %{"endpoint" => "t3.storage.dev"}, "tigris")

      socket =
        user
        |> mount!()
        |> create(
          own(aws, %{
            "targets" => %{
              "0" => %{"integration_uuid" => aws, "bucket_name" => "photos-aws"},
              "1" => %{"integration_uuid" => tigris, "bucket_name" => "photos-tigris"}
            }
          })
        )

      assert {:success, _} = socket.assigns.message
      assert [%{library: library}] = socket.assigns.owned

      assert %{mode: :only, buckets: [main, copy]} =
               socket.assigns.own_storage[to_string(library.uuid)]

      assert {main.role, main.bucket.bucket_name, main.bucket.provider} ==
               {"primary", "photos-aws", "s3"}

      assert {copy.role, copy.bucket.bucket_name, copy.bucket.provider} ==
               {"backup", "photos-tigris", "tigris"}

      profile = Profiles.get_profile(library.storage_profile_uuid)
      assert profile.copies_cloud == 2
      assert profile.min_copies_on_write == 1

      rendered = html(socket)
      assert rendered =~ "Your bucket: photos-aws"
      assert rendered =~ "Backed up to: photos-tigris"
      assert rendered =~ "aws · Amazon S3"
      assert rendered =~ "tigris · Tigris"
      refute rendered =~ "secret-value"
    end

    test "every bucket is checked, and the one that fails is named", %{role: role} do
      user = user!(role)
      aws = connection!(user, %{}, "aws")
      tigris = connection!(user, %{}, "tigris")
      asked = :ets.new(:asked, [:public, :bag])

      probe = fn params ->
        :ets.insert(asked, {params["bucket_name"]})
        if params["bucket_name"] == "photos-tigris", do: {:error, "Bucket not found"}, else: :ok
      end

      socket =
        user
        |> mount!(probe)
        |> create(
          own(aws, %{
            "targets" => %{
              "0" => %{"integration_uuid" => aws, "bucket_name" => "photos-aws"},
              "1" => %{"integration_uuid" => tigris, "bucket_name" => "photos-tigris"}
            }
          })
        )

      assert {:error, message} = socket.assigns.message
      assert message =~ "photos-tigris: Bucket not found"
      assert socket.assigns.owned == []
      assert Storage.list_owned_buckets(user.uuid) == []
      assert Enum.sort(:ets.tab2list(asked)) == [{"photos-aws"}, {"photos-tigris"}]
    end

    test "the same bucket twice is refused", %{role: role} do
      user = user!(role)
      aws = connection!(user)

      socket =
        user
        |> mount!()
        |> create(
          own(aws, %{
            "targets" => %{
              "0" => %{"integration_uuid" => aws, "bucket_name" => "photos"},
              "1" => %{"integration_uuid" => aws, "bucket_name" => "photos"}
            }
          })
        )

      assert {:error, message} = socket.assigns.message
      assert message =~ "same bucket"
      assert socket.assigns.owned == []
    end

    test "an empty extra row is left out", %{role: role} do
      user = user!(role)
      aws = connection!(user)

      socket =
        user
        |> mount!()
        |> create(
          own(aws, %{
            "targets" => %{
              "0" => %{"integration_uuid" => aws, "bucket_name" => "photos"},
              "1" => %{"integration_uuid" => "", "bucket_name" => ""}
            }
          })
        )

      assert {:success, _} = socket.assigns.message
      assert [%{library: library}] = socket.assigns.owned
      assert %{buckets: [_]} = socket.assigns.own_storage[to_string(library.uuid)]
    end

    test "a connection that changes while creating is explained and leaves nothing", %{role: role} do
      user = user!(role)
      uuid = connection!(user)

      probe = fn _params ->
        {:ok, _} =
          Integrations.save_setup(uuid, %{"access_key" => "changed"}, nil,
            owner: {:user, user.uuid}
          )

        :ok
      end

      socket = user |> mount!(probe) |> create(own(uuid))

      assert {:error, message} = socket.assigns.message
      assert message =~ "changed during testing"
      assert socket.assigns.owned == []
      assert socket.assigns.creating == false
      assert Storage.list_owned_buckets(user.uuid) == []
      assert Storage.Libraries.list_user_libraries(user.uuid) == []
    end

    test "a bucket that fails its check creates nothing and says why", %{role: role} do
      user = user!(role)
      failing = fn _params -> {:error, "The bucket can be read but not written to"} end

      socket = user |> mount!(failing) |> create(own(connection!(user)))

      assert {:error, message} = socket.assigns.message
      assert message =~ "The bucket can be read but not written to"
      assert socket.assigns.owned == []
      assert Storage.list_owned_buckets(user.uuid) == []
    end

    test "an integration whose endpoint is not allowed is explained", %{role: role} do
      user = user!(role)
      uuid = connection!(user, %{"endpoint" => "https://10.0.0.5"})

      socket = user |> mount!() |> create(own(uuid))

      assert {:error, message} = socket.assigns.message
      assert message =~ "endpoint"
      assert socket.assigns.owned == []
    end

    test "choosing nothing is explained", %{role: role} do
      user = user!(role)

      socket =
        user
        |> mount!()
        |> create(
          own("", %{"targets" => %{"0" => %{"integration_uuid" => "", "bucket_name" => ""}}})
        )

      assert {:error, message} = socket.assigns.message
      assert message =~ "Choose an integration and a bucket"
      assert socket.assigns.owned == []
    end

    test "a plain library needs none of it", %{role: role} do
      user = user!(role)
      socket = user |> mount!() |> create(%{"name" => "Plain", "storage" => %{"kind" => "site"}})

      assert {:success, _} = socket.assigns.message
      assert [%{library: %{storage_profile_uuid: nil}}] = socket.assigns.owned
    end

    test "a user who may not use their own storage cannot ask for it", %{plain: plain} do
      user = user!(plain)

      socket = user |> mount!() |> create(own(Ecto.UUID.generate()))

      # Their own-storage fields are ignored: the library is made on the site's storage.
      assert [%{library: %{storage_profile_uuid: nil}}] = socket.assigns.owned
      assert Storage.list_owned_buckets(user.uuid) == []
    end
  end

  describe "the library afterwards" do
    test "says where it keeps its files, and cannot be moved", %{conn: conn, role: role} do
      user = user!(role)
      socket = user |> mount!() |> create(own(connection!(user)))
      [%{library: library}] = socket.assigns.owned

      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      assert html =~ "Your bucket: my-photos"
      assert html =~ "including the copies in your own bucket"
      assert {:error, :user_storage_locked} = Profiles.set_library_profile(library, nil)
    end
  end

  test "library dialogs and tabs survive a fresh page and browser navigation", %{
    conn: conn,
    role: role
  } do
    user = user!(role)
    socket = user |> mount!() |> create(own(connection!(user)))
    [%{library: library}] = socket.assigns.owned
    conn = log_in_user(conn, user)
    path = Routes.path("/profile/settings/media")
    {:ok, view, _} = live(conn, path)
    view |> element("#library-menu-#{library.uuid} button", "Settings") |> render_click()
    settings_path = assert_patch(view)
    assert URI.decode_query(URI.parse(settings_path).query)["library"] == library.uuid
    assert URI.decode_query(URI.parse(settings_path).query)["dialog"] == "settings"
    prefix = "#profile-library-settings-preferences-#{library.uuid}"
    view |> element(prefix <> " [role=tab][phx-value-tab=storage]") |> render_click()
    storage_tab_path = assert_patch(view)
    assert URI.decode_query(URI.parse(storage_tab_path).query)["settings_tab"] == "storage"

    {:ok, restored, _} = live(conn, storage_tab_path)
    assert has_element?(restored, prefix <> "-storage:not([hidden])")
    restored |> element(prefix <> " button[phx-value-kind=storage]") |> render_click()
    backup_path = assert_patch(restored)
    assert URI.decode_query(URI.parse(backup_path).query)["dialog"] == "storage"
    {:ok, backup, html} = live(conn, backup_path)
    assert has_element?(backup, "#profile-library-settings-storage-modal")
    assert html =~ "my-photos"
    backup |> element("#profile-library-settings-storage-modal button", "Close") |> render_click()
    assert_patch(backup, path)
    refute has_element?(backup, "#profile-library-settings-storage-modal")
    render_patch(backup, backup_path)
    assert has_element?(backup, "#profile-library-settings-storage-modal")
    render_patch(backup, storage_tab_path)
    assert has_element?(backup, prefix <> "-storage:not([hidden])")
  end

  test "storage cards identify integrations and picker hides current buckets across connections",
       %{role: role} do
    user = user!(role)
    attrs = %{"service" => "tigris", "endpoint" => "t3.storage.dev"}
    first = connection!(user, attrs, "Fotki2-tigris")
    alias_connection = connection!(user, attrs, "Another key")

    socket =
      user
      |> mount!(fn _ -> :ok end, fn _ -> {:ok, ["my-photos", "other-photos", "fresh"]} end)
      |> create(own(first))

    [%{library: library}] = socket.assigns.owned

    socket =
      create(
        socket,
        Map.put(
          own(first, %{
            "targets" => %{"0" => %{"integration_uuid" => first, "bucket_name" => "other-photos"}}
          }),
          "name",
          "Other library"
        )
      )

    socket = event(socket, "open_dialog", %{"kind" => "storage", "uuid" => library.uuid})

    socket =
      form_change(socket, %{
        "storage" => %{"targets" => %{"0" => %{"integration_uuid" => alias_connection}}}
      })

    socket = event(socket, "list_buckets", %{"index" => "0"})
    html = html(socket)
    assert html =~ "Fotki2-tigris"
    assert html =~ "Tigris"
    assert html =~ "hero-circle-stack"
    assert html =~ "Primary"
    {:ok, doc} = Floki.parse_fragment(html)
    select = Floki.find(doc, "#profile-library-settings-backup-bucket-0")
    assert Floki.find(select, "option[value=my-photos]") == []
    assert Floki.find(select, "option[value=other-photos]") |> Floki.text() =~ "Other library"
    assert Floki.find(select, "option[value=fresh]") != []
  end

  test "a deep link cannot open another account's library dialog", %{conn: conn, role: role} do
    owner = user!(role)
    socket = owner |> mount!() |> create(own(connection!(owner)))
    [%{library: library}] = socket.assigns.owned
    other = user!(role)

    path =
      Routes.path("/profile/settings/media") <>
        "?" <> URI.encode_query(%{"library" => library.uuid, "dialog" => "storage"})

    {:ok, view, _} = live(log_in_user(conn, other), path)
    refute has_element?(view, "#profile-library-settings-storage-modal")
  end

  test "backup failures appear inside the open popup and clear when reopened", %{role: role} do
    user = user!(role)
    socket = user |> mount!() |> create(own(connection!(user)))
    [%{library: library}] = socket.assigns.owned
    backup = connection!(user, %{}, "Backup")

    {:ok, socket} =
      LibrarySettings.update(
        %{
          id: socket.assigns.id,
          scope: scope(user),
          probe: fn _ -> {:error, "R2 refused the test upload (HTTP 403)"} end
        },
        socket
      )

    socket = event(socket, "open_dialog", %{"kind" => "storage", "uuid" => library.uuid})

    socket =
      event(socket, "add_storage", %{
        "library" =>
          own(backup, %{
            "targets" => %{
              "0" => %{"integration_uuid" => backup, "bucket_name" => "backup-photos"}
            }
          })
      })

    {:ok, doc} = Floki.parse_fragment(html(socket))

    alert =
      Floki.find(
        doc,
        "#profile-library-settings-storage-modal #profile-library-settings-storage-message[role=alert]"
      )

    assert Floki.text(alert) =~ "R2 refused the test upload"
    assert Floki.find(doc, "#profile-library-settings > .alert") == []
    assert socket.assigns.dialog == {:storage, library.uuid}

    socket =
      socket
      |> event("close_dialog")
      |> event("open_dialog", %{"kind" => "storage", "uuid" => library.uuid})

    refute html(socket) =~ "R2 refused the test upload"
  end

  test "progress refreshes in the open popup without losing form values", %{
    conn: conn,
    role: role
  } do
    user = user!(role)
    socket = user |> mount!() |> create(own(connection!(user)))
    [%{library: library}] = socket.assigns.owned
    conn = log_in_user(conn, user)

    path =
      Routes.path("/profile/settings/media") <>
        "?" <> URI.encode_query(%{"dialog" => "storage", "library" => library.uuid})

    {:ok, view, _} = live(conn, path)
    modal = "#profile-library-settings-storage-modal"

    assert has_element?(
             view,
             modal <> " #profile-library-settings-storage-progress",
             "Storage ready"
           )

    view
    |> form("#profile-library-settings-add-storage",
      library: %{storage: %{targets: %{"0" => %{bucket_name: "unsaved-backup"}}}}
    )
    |> render_change()

    # The actual refresh message sent by the recurring timer.
    send(view.pid, :refresh_library_storage)
    assert has_element?(view, modal <> " input[value=unsaved-backup]")

    assert has_element?(
             view,
             modal <> " [aria-label='Storage activity']",
             "Updates automatically"
           )
  end

  test "an existing library can add backup storage and see progress", %{role: role} do
    user = user!(role)
    socket = user |> mount!() |> create(own(connection!(user)))
    [%{library: library}] = socket.assigns.owned
    second = connection!(user, %{}, "backup")
    socket = event(socket, "open_dialog", %{"kind" => "storage", "uuid" => library.uuid})
    assert html(socket) =~ "Storage and backups"
    assert html(socket) =~ "Storage ready"

    socket =
      event(socket, "add_storage", %{
        "library" =>
          own(second, %{
            "targets" => %{
              "0" => %{"integration_uuid" => second, "bucket_name" => "backup-photos"}
            }
          })
      })

    assert {:success, message} = socket.assigns.message
    assert message =~ "copied and verified"
    assert socket.assigns.dialog == {:storage, library.uuid}
    assert html(socket) =~ "Updates automatically"
    assert html(socket) =~ "stored copies"
    assert Enum.count(Profiles.for_library(library).buckets, &(&1.role == "backup")) == 1
  end

  test "integration list and edit show usage, refuse removal and permit a safe rename", %{
    conn: conn,
    role: role
  } do
    user = user!(role)
    uuid = connection!(user, %{"service" => "aws_s3", "region" => "eu-central-1"})
    _socket = user |> mount!() |> create(own(uuid))
    conn = log_in_user(conn, user)
    {:ok, list, html} = live(conn, Routes.path("/profile/settings/integrations"))
    assert html =~ "Used by"
    assert html =~ "Photos"
    assert html =~ "my-photos"
    assert has_element?(list, "button[phx-click=remove_connection][disabled]")
    html = render_click(list, "remove_connection", %{"uuid" => uuid})
    assert html =~ "cannot be removed"
    assert {:ok, _} = Integrations.get_integration_by_uuid(uuid, {:user, user.uuid})

    {:ok, edit, html} = live(conn, Routes.path("/profile/settings/integrations/#{uuid}"))
    assert html =~ "Used by"
    assert html =~ "Photos"
    refute html =~ "secret-value"
    assert has_element?(edit, "input[type=hidden][name=service][value=aws_s3]")
    refute has_element?(edit, "select[name=service]")
    assert has_element?(edit, "button[phx-click=delete_connection][disabled]")
    assert has_element?(edit, "fieldset[disabled] select[name=region]")
    html = render_click(edit, "select_provider", %{"provider" => "telegram"})
    refute html =~ "Bot Token"

    render_submit(edit, "save", %{
      "name" => "Safely renamed",
      "access_key" => "AKIA",
      "secret_key" => ""
    })

    render_async(edit)

    assert {:ok, %{name: "Safely renamed", data: %{"secret_key" => "secret-value"}}} =
             Integrations.get_integration_by_uuid(uuid, {:user, user.uuid})
  end

  describe "the admin's view" do
    test "the list names the storage and never a credential", %{role: role} do
      user = user!(role)
      _ = mount!(user) |> create(own(connection!(user, %{"endpoint" => "https://8.8.8.8"})))

      {:ok, admin} = admin_with_storage_settings()

      {:ok, _view, html} =
        live(log_in_user(build_conn(), admin), Routes.path("/admin/settings/media"))

      # The Libraries tab is the one with the user library list.
      html = render_libraries_tab(html, admin)

      assert html =~ "Own S3 bucket"
      refute html =~ "secret-value"
      refute html =~ "AKIA"
    end
  end

  defp admin_with_storage_settings do
    {admin, _token} = create_admin_user()
    {:ok, admin}
  end

  defp render_libraries_tab(_html, admin) do
    {:ok, view, _html} =
      live(log_in_user(build_conn(), admin), Routes.path("/admin/settings/media"))

    render_patch(view, Routes.path("/admin/settings/media?tab=libraries"))
  end

  describe "removing the connection a library's bucket uses" do
    test "both personal pages explain why removal is blocked", %{conn: conn, role: role} do
      user = user!(role)
      connection = connection!(user)
      _ = user |> mount!() |> create(own(connection))

      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, Routes.path("/profile/settings/integrations"))
      assert html =~ "1 storage bucket uses this connection and prevents its removal."

      {:ok, _view, html} = live(conn, Routes.path("/profile/settings/integrations/#{connection}"))
      assert html =~ "1 storage bucket uses this connection and prevents its removal."
    end

    test "a connection nothing uses keeps the plain question", %{conn: conn, role: role} do
      user = user!(role)
      _ = connection!(user)

      {:ok, _view, html} =
        live(log_in_user(conn, user), Routes.path("/profile/settings/integrations"))

      assert html =~ "Remove this connection?"
      refute html =~ "keeps its files in a bucket"
    end
  end

  describe "Object Storage as a personal connection" do
    test "is offered only while the site allows users their own buckets" do
      keys = fn -> Enum.map(Providers.personal_offered(), & &1.key) end

      assert "object_storage" in keys.()

      {:ok, _} = Settings.update_boolean_setting("storage_user_buckets_enabled", false)

      refute "object_storage" in keys.()
      assert "telegram" in keys.()
    end
  end

  test "the new personal connection page opens on the provider named in ?provider=", %{
    conn: conn,
    role: role
  } do
    user = user!(role)

    {:ok, _view, html} =
      live(
        log_in_user(conn, user),
        Routes.path("/profile/settings/integrations/new?provider=object_storage")
      )

    # The form for that provider, not the list of providers to choose from.
    assert html =~ "Object Storage"
    refute html =~ "Telegram"
  end

  test "the profile's tabs stay on the add and edit pages of a personal integration", %{
    conn: conn,
    role: role
  } do
    user = user!(role)
    connection = connection!(user)
    conn = log_in_user(conn, user)

    for path <- [
          "/profile/settings/integrations",
          "/profile/settings/integrations/new",
          "/profile/settings/integrations/#{connection}"
        ] do
      {:ok, _view, html} = live(conn, Routes.path(path))

      assert html =~ "Security", path
      assert html =~ "Sessions", path
      assert html =~ ~s(aria-selected="true") or html =~ "tab-active", path
    end
  end
end
