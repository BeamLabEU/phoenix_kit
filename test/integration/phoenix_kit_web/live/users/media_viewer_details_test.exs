defmodule PhoenixKitWeb.Live.Users.MediaViewerDetailsTest do
  @moduledoc """
  The viewer sidebar's title / alt text / description: a tab per language of
  the site, all in one form with one Save (the writes are `Storage`'s), and a save
  leaves the rest of the row alone.

  Sync: the enabled languages are a cached, unsandboxed setting.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Settings
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
end
