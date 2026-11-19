defmodule PhoenixKitWeb.CommentsLeafSuggestForwardingTest do
  @moduledoc """
  The comment composer's @ / # typeahead (`{:leaf_suggest, _}`) is forwarded
  like its content (`{:leaf_changed, _}`); with the comments package absent
  both are dropped quietly, and anything else is not this forwarder's.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.CommentsForwarding

  @socket %Phoenix.LiveView.Socket{}

  test "both Leaf messages are accepted and never crash the host" do
    for msg <- [
          {:leaf_changed, %{editor_id: "pk-comments:x:new", markdown: "hi"}},
          {:leaf_suggest, %{editor_id: "pk-comments:x:new", trigger: "@", query: "an"}}
        ] do
      assert {:noreply, @socket} = CommentsForwarding.forward_leaf_event(msg, @socket)
    end
  end

  test "another message is not forwarded" do
    assert {:noreply, @socket} = CommentsForwarding.forward_leaf_event({:other, 1}, @socket)
  end

  test "the host LiveViews route :leaf_suggest" do
    for file <- ~w(lib/phoenix_kit_web/live/users/user_details.ex
                   lib/phoenix_kit_web/components/media_browser/embed.ex) do
      assert File.read!(file) =~ "{:leaf_suggest, _}", file
    end
  end
end
