defmodule PhoenixKitWeb.Components.MediaBrowserShowPathTest do
  @moduledoc """
  `show_path` (default `true`): the list view's "Path" column — the header and
  the cell of every folder and file row — is drawn unless the host passes
  `show_path={false}`. A host that embeds the browser for an outside person
  hides it so the folder chain above the scope folder never reaches them.

  Rendered straight from `MediaBrowser.ListView.list_view/1`, the function
  component that draws the table: no database involved.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitWeb.Components.MediaBrowser.ListView

  defp file do
    %{
      file_uuid: "01900000-0000-7000-8000-000000000001",
      filename: "plan.pdf",
      file_type: "document",
      mime_type: "application/pdf",
      size: 1024,
      inserted_at: ~U[2026-05-19 12:00:00Z],
      folder_path: "Orders / 1234 / Measurements",
      urls: %{}
    }
  end

  defp folder do
    %{
      uuid: "01900000-0000-7000-8000-000000000002",
      name: "Photos",
      color: nil,
      description: nil,
      inserted_at: ~U[2026-05-19 12:00:00Z]
    }
  end

  defp assigns(overrides) do
    Map.merge(
      %{
        current_folder: nil,
        drag: false,
        editing_folder_description: nil,
        featured: nil,
        file_view: "folders",
        filter_trash: false,
        folder_actions: false,
        folder_description_text: "",
        folders: [folder()],
        id: "mb-path-test",
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        readonly: false,
        removal_guarded: false,
        renaming_folder: nil,
        renaming_source: nil,
        renaming_text: "",
        scope: nil,
        scope_folder_id: nil,
        select_mode: false,
        selected_files: MapSet.new(),
        selected_folders: MapSet.new(),
        uploaded_files: [file()]
      },
      overrides
    )
  end

  defp render_table(overrides) do
    overrides
    |> assigns()
    |> ListView.list_view()
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "default: the Path header and a Path cell on the folder row and on the file row" do
    doc = render_table(%{})

    assert count(doc, "th[data-col=path]") == 1
    assert count(doc, "td[data-col=path]") == 2
    assert LazyHTML.text(doc) =~ "Orders / 1234 / Measurements"
  end

  test "show_path: true is the default spelled out" do
    doc = render_table(%{show_path: true})

    assert count(doc, "th[data-col=path]") == 1
    assert count(doc, "td[data-col=path]") == 2
  end

  test "show_path: false draws no Path header, no cell, and not the chain" do
    doc = render_table(%{show_path: false})

    assert count(doc, "th[data-col=path]") == 0
    assert count(doc, "td[data-col=path]") == 0
    refute LazyHTML.text(doc) =~ "Orders / 1234"
    # The rest of the table is untouched: name, description, type, size, date
    # and the menu column are still there.
    assert count(doc, "thead th") == 7
    assert LazyHTML.text(doc) =~ "plan.pdf"
  end

  test "the folder edit rows span the columns that are drawn" do
    editing = [
      %{renaming_folder: folder().uuid, renaming_text: "Photos", renaming_source: "content"},
      %{editing_folder_description: folder().uuid}
    ]

    for edit <- editing do
      shown = render_table(edit)
      assert count(shown, ~s(td[colspan="6"])) == 1
      assert count(shown, ~s(td[colspan="5"])) == 0

      hidden = render_table(Map.put(edit, :show_path, false))
      assert count(hidden, ~s(td[colspan="5"])) == 1
      assert count(hidden, ~s(td[colspan="6"])) == 0
    end
  end
end
