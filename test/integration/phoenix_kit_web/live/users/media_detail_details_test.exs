defmodule PhoenixKitWeb.Live.Users.MediaDetailDetailsTest do
  @moduledoc """
  The media detail page's title / alt text / description: a tab per language
  of the site, all in one form with one Save, and saving leaves the rest of the
  row alone.

  Sync: the enabled languages are a cached, unsandboxed setting.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.MediaCanvasViewer
  alias PhoenixKitWeb.Users.Auth

  setup %{conn: conn} do
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "et", "name" => "Estonian", "is_default" => false, "is_enabled" => true}
      ]
    })

    on_exit(fn -> Settings.update_setting("languages_enabled", "false") end)

    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp image!(user, attrs) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct!(
        %StorageFile{
          original_file_name: "photo_#{n}.jpg",
          file_name: "photo_#{n}.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          file_checksum: "sha256:details-lv-#{n}",
          user_file_checksum: "user-sha256:details-lv-#{n}",
          size: 1024,
          status: "active",
          user_uuid: user.uuid
        },
        attrs
      )
    )
  end

  defp save(view, details, tags \\ "") do
    view |> element("button[phx-click=toggle_edit]") |> render_click()

    view
    |> form("form[phx-submit=save_metadata]", %{"details" => details, "tags" => tags})
    |> render_submit()
  end

  test "the primary-language page saves the primary text, and keeps the rest of metadata", %{
    conn: conn,
    user: user
  } do
    file = image!(user, metadata: %{"rotation" => 90, "title" => "Old title"})
    {:ok, view, html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    assert html =~ "Old title"
    assert html =~ "English"

    html =
      save(
        view,
        %{"en" => %{"title" => "Harbour", "alt" => "Boats in a harbour"}},
        "sea, boats"
      )

    assert html =~ "Boats in a harbour"

    row = Repo.reload!(file)
    assert row.data == %{"en" => %{"title" => "Harbour", "alt" => "Boats in a harbour"}}
    assert row.metadata["rotation"] == 90
    assert row.metadata["tags"] == ["sea", "boats"]
    assert row.metadata["title"] == "Harbour"
  end

  test "the Estonian page edits the Estonian text: English is a placeholder, never a value", %{
    conn: conn,
    user: user
  } do
    file = image!(user, data: %{"en" => %{"title" => "Harbour", "alt" => "Boats"}})
    {:ok, view, html} = live(conn, Routes.admin_path("/admin/media/#{file.uuid}", "et"))

    # Shown like any reader sees it: the primary text stands in.
    assert html =~ "Estonian"
    assert html =~ "Harbour"

    html = view |> element("button[phx-click=toggle_edit]") |> render_click()
    assert html =~ ~s(placeholder="Harbour")
    # The Estonian input is empty: English is only its placeholder.
    assert html =~ ~r/name="details\[et\]\[title\]" value=""/

    view
    |> form("form[phx-submit=save_metadata]", %{"details" => %{"et" => %{"title" => "Sadam"}}})
    |> render_submit()

    assert Repo.reload!(file).data == %{
             "en" => %{"title" => "Harbour", "alt" => "Boats"},
             "et" => %{"title" => "Sadam"}
           }
  end

  test "an untouched save on a translation page stores nothing under that language", %{
    conn: conn,
    user: user
  } do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}})
    {:ok, view, _html} = live(conn, Routes.admin_path("/admin/media/#{file.uuid}", "et"))

    save(view, %{})

    assert Repo.reload!(file).data == %{"en" => %{"title" => "Harbour"}}
  end

  test "a field that is too long re-renders the form with its error and saves nothing", %{
    conn: conn,
    user: user
  } do
    file = image!(user, [])
    {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    html = save(view, %{"en" => %{"title" => String.duplicate("a", 256)}})

    assert html =~ "should be at most 255"
    assert Repo.reload!(file).data == %{}
  end

  test "every language is a tab in the one form, and the page language is not what picks them", %{
    conn: conn,
    user: user
  } do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam"}})
    {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    html = view |> element("button[phx-click=toggle_edit]") |> render_click()

    # Both languages are in the page, whichever the page is shown in, each with
    # its own text; the second is hidden until its tab is picked.
    assert html =~ ~r/name="details\[en\]\[title\]" value="Harbour"/
    assert html =~ ~r/name="details\[et\]\[title\]" value="Sadam"/
    assert html =~ "role=\"tablist\""
    refute html =~ "Switch the page language"
  end

  test "two languages are saved by one Save, and only the one that changed is written", %{
    conn: conn,
    user: user
  } do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}})
    {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    save(view, %{
      "en" => %{"description" => "Boats."},
      "et" => %{"title" => "Sadam", "description" => "Paadid."}
    })

    assert Repo.reload!(file).data == %{
             "en" => %{"title" => "Harbour", "description" => "Boats."},
             "et" => %{"title" => "Sadam", "description" => "Paadid."}
           }
  end

  test "a language that is invalid saves none of them", %{conn: conn, user: user} do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}})
    {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    html =
      save(view, %{
        "en" => %{"title" => "Changed"},
        "et" => %{"title" => String.duplicate("a", 256)}
      })

    assert html =~ "Estonian"
    assert html =~ "should be at most 255"
    assert Repo.reload!(file).data == %{"en" => %{"title" => "Harbour"}}
  end

  test "an untouched language in the form keeps another editor's newer text", %{
    conn: conn,
    user: user
  } do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam"}})
    {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    {:ok, _} =
      Storage.update_file_details(file, %{"title" => "Sadam 2"}, lang: "et", primary: "en")

    save(view, %{"en" => %{"title" => "Changed"}})

    assert Repo.reload!(file).data == %{
             "en" => %{"title" => "Changed"},
             "et" => %{"title" => "Sadam 2"}
           }
  end

  test "correcting an invalid language also saves changes kept from the first attempt", %{
    conn: conn,
    user: user
  } do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}})
    {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    save(view, %{
      "en" => %{"title" => "Changed"},
      "et" => %{"title" => String.duplicate("a", 256)}
    })

    view
    |> form("form[phx-submit=save_metadata]", %{"details" => %{"et" => %{"title" => "Sadam"}}})
    |> render_submit()

    assert Repo.reload!(file).data == %{
             "en" => %{"title" => "Changed"},
             "et" => %{"title" => "Sadam"}
           }
  end

  test "an untouched empty translation preserves text added after the form loaded", %{
    conn: conn,
    user: user
  } do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}})
    {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

    {:ok, _} = Storage.update_file_details(file, %{"title" => "Sadam"}, lang: "et", primary: "en")
    save(view, %{"en" => %{"title" => "Changed"}})

    assert Repo.reload!(file).data == %{
             "en" => %{"title" => "Changed"},
             "et" => %{"title" => "Sadam"}
           }
  end

  test "the viewer compares posted text with its initial form values", %{user: user} do
    file = image!(user, data: %{"en" => %{"title" => "Harbour"}, "et" => %{"title" => "Sadam"}})

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "mcv-stale",
        file: %{file_uuid: file.uuid},
        details_path: "/admin/media/x",
        edit_target: nil,
        write_scope: nil,
        media_meta_lang: "en",
        media_meta_langs: [%{code: "en"}, %{code: "et"}],
        media_meta_values: %{"en" => %{title: "Harbour"}, "et" => %{title: "Sadam"}},
        media_meta_status_token: 0
      }
    }

    {:ok, _} =
      Storage.update_file_details(file, %{"title" => "Sadam 2"}, lang: "et", primary: "en")

    {:noreply, socket} =
      MediaCanvasViewer.handle_event(
        "save_media_details",
        %{"details" => %{"en" => %{"title" => "Changed"}, "et" => %{"title" => "Sadam"}}},
        socket
      )

    assert socket.assigns.media_meta_status == :saved

    assert Repo.reload!(file).data == %{
             "en" => %{"title" => "Changed"},
             "et" => %{"title" => "Sadam 2"}
           }
  end

  # The viewer sidebar is a LiveComponent nested in other LiveComponents: it
  # has no `@current_locale`, and the Gettext locale is "en" for both
  # dialects. It must still save the dialect the page is in.
  test "the viewer sidebar on an en-GB page saves en-GB, not the other English", %{user: user} do
    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{
          "code" => "en-US",
          "name" => "English (US)",
          "is_default" => true,
          "is_enabled" => true
        },
        %{
          "code" => "en-GB",
          "name" => "English (UK)",
          "is_default" => false,
          "is_enabled" => true
        }
      ]
    })

    file = image!(user, data: %{"en-US" => %{"title" => "Harbor"}})
    Auth.put_gettext_locale("en-GB")

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "mcv-test",
        file: %{file_uuid: file.uuid},
        details_path: "/admin/media/x",
        edit_target: nil,
        write_scope: nil,
        media_meta_status: nil,
        media_meta_status_token: 0
      }
    }

    {:noreply, socket} =
      MediaCanvasViewer.handle_event(
        "save_media_details",
        %{"title" => "Harbour"},
        socket
      )

    assert socket.assigns.media_meta_status == :saved

    assert Repo.reload!(file).data == %{
             "en-US" => %{"title" => "Harbor"},
             "en-GB" => %{"title" => "Harbour"}
           }
  end

  describe "dimensions and EXIF" do
    @exif %{
      "camera" => %{"make" => "Apple", "model" => "iPhone 17 Pro"},
      "gps" => %{"latitude" => 45.5, "longitude" => 10.7}
    }

    test "the file's size in pixels is shown, and a panorama says so", %{conn: conn, user: user} do
      file = image!(user, width: 8947, height: 3317)
      {:ok, _view, html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

      assert html =~ "8947 × 3317 px"
      assert html =~ "29.7 MP"
      assert html =~ "Panorama"

      plain = image!(user, width: 4032, height: 3024)
      {:ok, _view, html} = live(conn, Routes.path("/admin/media/#{plain.uuid}"))
      assert html =~ "4032 × 3024 px"
      refute html =~ "Panorama"
    end

    test "a photo whose EXIF was never read offers to read it", %{conn: conn, user: user} do
      file = image!(user, [])
      {:ok, view, html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

      assert html =~ "EXIF has not been read yet."
      assert has_element?(view, ~s(button[phx-click="read_exif"]))
    end

    test "a photo with EXIF shows its camera and where it was taken", %{conn: conn, user: user} do
      file = image!(user, metadata: %{"exif" => @exif}, latitude: 45.5, longitude: 10.7)
      {:ok, view, html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

      assert html =~ "Apple iPhone 17 Pro"
      assert html =~ "https://www.openstreetmap.org/?mlat=45.5&amp;mlon=10.7"
      assert has_element?(view, ~s(button[phx-click="show_exif"]))
    end

    test "reading an original that cannot be read says so", %{conn: conn, user: user} do
      file = image!(user, [])
      {:ok, view, _html} = live(conn, Routes.path("/admin/media/#{file.uuid}"))

      html = view |> element(~s(button[phx-click="read_exif"])) |> render_click()

      assert html =~ "Could not read the EXIF"
      assert Repo.reload!(file).metadata["exif"] == nil
    end
  end
end
