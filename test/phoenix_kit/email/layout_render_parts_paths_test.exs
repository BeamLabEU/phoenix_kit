defmodule PhoenixKit.Email.LayoutRenderPartsPathsTest do
  @moduledoc """
  `Layout.render_parts/2` without `:paths` reads the host's override roots
  (`Content.override_paths/0`), as `Content.resolve/5` does — a module that
  copies the documented call gets the host's `_header`/`_footer`.

  Synchronous: it sets the global `:template_paths` config, which the async
  email tests read whenever they pass no `:paths` of their own.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Email.Layout

  @moduletag :tmp_dir

  @branding %{"logo_url" => "", "accent_color" => "#1d4ed8"}

  setup %{tmp_dir: root} do
    previous = Application.fetch_env(:phoenix_kit, :template_paths)
    Application.put_env(:phoenix_kit, :template_paths, [root])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :template_paths, value)
        :error -> Application.delete_env(:phoenix_kit, :template_paths)
      end
    end)

    write(root, "_header-newsletters", "html.html", "HOST GROUP HEADER")
    write(root, "_footer", "html.html", "HOST FOOTER")
    :ok
  end

  test "without :paths, the configured template_paths are read", %{tmp_dir: root} do
    parts = Layout.render_parts("s", group: "newsletters", branding: @branding)

    assert {parts.header, parts.footer} == {"HOST GROUP HEADER", "HOST FOOTER"}
    assert parts.sources.footer == {:file, Path.join([root, "_footer", "html.html"])}
  end

  test "paths: nil reads them too; paths: [] is core's parts only" do
    assert Layout.render_parts("s", paths: nil, group: "newsletters", branding: @branding).header ==
             "HOST GROUP HEADER"

    core = Layout.render_parts("s", paths: [], group: "newsletters", branding: @branding)
    assert core.sources == %{header: :default, footer: :default, ignored: []}
  end

  test "render/3 keeps its own default: no :paths is no override roots" do
    {html, sources} = Layout.render("<p>x</p>", "s", group: "newsletters", branding: @branding)

    refute html =~ "HOST"
    assert sources.header == :default
  end

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end
end
