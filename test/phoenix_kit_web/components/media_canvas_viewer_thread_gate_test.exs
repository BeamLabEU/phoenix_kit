defmodule PhoenixKitWeb.Components.MediaCanvasViewerThreadGateTest do
  @moduledoc """
  The sidebar's comments thread is drawn only for a host that leaves `comments`
  and `authors` alone: the thread prints every commenter's name and avatar, and
  core cannot strip them from a component of another package.

  `PhoenixKitComments` is an optional sibling package that core does not depend
  on, so a stand-in that says "enabled" is defined for the length of each test.
  The thread's component is not there either, so rendering it raises naming it:
  "the thread is drawn" is asserted as that raise (as the reply popup is in
  `MediaCanvasViewerEmbedOptionsTest`). Synchronous: the stand-in is global.
  """
  use ExUnit.Case, async: false

  import PhoenixKitWeb.MediaCanvasViewerFixtures

  @user %{uuid: "01900000-0000-7000-8000-0000000000aa", email: "a@example.com"}

  setup do
    if Code.ensure_loaded?(PhoenixKitComments),
      do: raise("a real PhoenixKitComments is loaded: this stand-in would replace it")

    Code.compile_string("""
    defmodule PhoenixKitComments do
      def enabled?, do: true
    end
    """)

    on_exit(fn ->
      :code.purge(PhoenixKitComments)
      :code.delete(PhoenixKitComments)
    end)
  end

  defp sidebar(overrides) do
    render_html(
      Map.merge(
        %{
          sidebar_collapsed: false,
          current_user: @user,
          file_row: nil,
          media_tags: []
        },
        overrides
      )
    )
  end

  test "default: the thread is drawn (the control)" do
    assert_raise UndefinedFunctionError, ~r/CommentsComponent/, fn -> sidebar(%{}) end
  end

  test "comments: false draws no thread" do
    refute sidebar(%{comments: false}) =~ "leaf-comments-compact"
  end

  test "authors: false draws no thread" do
    refute sidebar(%{authors: false}) =~ "leaf-comments-compact"
  end

  test "authors: true is the default spelled out" do
    assert_raise UndefinedFunctionError, ~r/CommentsComponent/, fn ->
      sidebar(%{authors: true})
    end
  end
end
