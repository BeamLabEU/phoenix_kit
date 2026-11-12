defmodule PhoenixKitWeb.Components.MediaCanvasViewerExtraInfoTest do
  @moduledoc """
  `MediaCanvasViewer.extra_info/1`: the rows other modules add to a file's details
  (`config :phoenix_kit, :media_file_info`). Only well-formed rows, only http(s) links,
  and a module that raises adds nothing and breaks nothing.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  defmodule Rows do
    @moduledoc false
    def source(%StorageFile{uuid: uuid}),
      do: [%{label: "Source:", text: "site.example · #{uuid}", href: "https://site.example/p/1"}]

    def odd(_row),
      do: [
        %{label: "Link:", text: "javascript", href: "javascript:alert(1)"},
        %{label: "No text"},
        "not a row",
        %{label: "Plain:", text: "kept"}
      ]

    def broken(_row), do: raise("broken")
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :media_file_info)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :media_file_info, previous),
        else: Application.delete_env(:phoenix_kit, :media_file_info)
    end)

    %{row: %StorageFile{uuid: "f1"}}
  end

  test "nothing configured, nothing added", %{row: row} do
    Application.delete_env(:phoenix_kit, :media_file_info)
    assert MediaCanvasViewer.extra_info(row) == []
  end

  test "each module's rows, in order; only http(s) links; bad rows and failures dropped", %{
    row: row
  } do
    Application.put_env(:phoenix_kit, :media_file_info, [
      {Rows, :source},
      {Rows, :broken},
      {Rows, :odd},
      :junk
    ])

    assert MediaCanvasViewer.extra_info(row) == [
             %{label: "Source:", text: "site.example · f1", href: "https://site.example/p/1"},
             %{label: "Link:", text: "javascript", href: nil},
             %{label: "Plain:", text: "kept", href: nil}
           ]
  end
end
