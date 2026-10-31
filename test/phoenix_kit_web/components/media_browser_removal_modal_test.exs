defmodule PhoenixKitWeb.Components.MediaBrowser.RemovalModalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.MediaBrowser.{Helpers, RemovalModal}

  defp render_modal(kind, selected_file_count) do
    pending = %{
      failed?: false,
      kind: kind,
      folders: 1,
      selected_file_count: selected_file_count,
      free: ["inside", "nested" | if(selected_file_count > 0, do: ["loose"], else: [])],
      places: [],
      token: "test-token",
      error: nil,
      free_names: ["inside.png", "nested.png"],
      free_hidden: selected_file_count,
      release_label: nil
    }

    render_component(&RemovalModal.removal_modal/1, id: "mb", myself: "mb", pending: pending)
  end

  for kind <- [:trash, :delete] do
    test "#{kind}: folder contents do not turn a folder-only action into a mixed selection" do
      html = render_modal(unquote(kind), 0)

      title =
        if unquote(kind) == :trash,
          do: "Move 1 folder and its contents to trash?",
          else: "Delete 1 folder and its contents for good?"

      assert html =~ title
      refute html =~ "files and 1 folder"

      if unquote(kind) == :delete do
        assert length(String.split(html, "This cannot be undone.")) == 2
      end
    end

    test "#{kind}: mixed selection counts match the client confirmation, warning once" do
      html = render_modal(unquote(kind), 1)

      title =
        html
        |> Floki.parse_document!()
        |> Floki.find("#mb-removal-title")
        |> Floki.text()
        |> String.trim()

      assert title ==
               Helpers.delete_selected_confirm(
                 MapSet.new(["loose"]),
                 MapSet.new(["folder"]),
                 unquote(kind) == :delete
               )

      if unquote(kind) == :delete do
        assert length(String.split(html, "This cannot be undone.")) == 2
      end
    end
  end
end
