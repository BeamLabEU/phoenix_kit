defmodule PhoenixKitWeb.CommentsForwarding do
  @moduledoc """
  Forwards Leaf rich-text editor process messages to the optional
  `phoenix_kit_comments` package.

  The embedded `CommentsComponent`'s Leaf composer reports its content to the
  *host* LiveView via a `{:leaf_changed, _}` process message — LiveComponents
  can't receive `handle_info` themselves. The host must forward that message
  back into the component, or "Post Comment" silently posts empty content.

  `phoenix_kit_comments` is an optional sibling dependency with no compile-order
  guarantee, so the call is resolved at runtime via `apply/3` (never a
  compile-time-bound `mod.fun(...)` call) and degrades to a no-op when the
  package is absent.

  Used by `PhoenixKitWeb.Components.MediaBrowser.Embed` (macro-injected handler),
  which delegates its `{:leaf_changed, _}` `handle_info` clause here so the
  optional-dep contract lives in one place.
  """

  require Logger

  @doc """
  Forwards a `{:leaf_changed, _}` message to the comments component.

  Always returns `{:noreply, socket}`, so it can be used directly as the body of
  a host `handle_info({:leaf_changed, _} = msg, socket)` clause. When the
  comments package is absent (or its `forward_leaf_event/2` contract drifts) the
  message is dropped gracefully — and contract drift is logged.
  """
  def forward_leaf_changed(msg, socket) do
    # credo:disable-for-next-line Credo.Check.Design.AliasUsage
    mod = PhoenixKitComments.Web.CommentsComponent

    if Code.ensure_loaded?(mod) and function_exported?(mod, :forward_leaf_event, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(mod, :forward_leaf_event, [msg, socket]) do
        {:noreply, _} = result ->
          result

        :pass ->
          {:noreply, socket}

        other ->
          # Optional cross-package contract: forward_leaf_event/2 is expected to
          # return {:noreply, socket} or :pass. Anything else shouldn't crash
          # the host LiveView — degrade gracefully and log so a contract drift
          # in phoenix_kit_comments is diagnosable.
          Logger.warning(
            "PhoenixKitComments.Web.CommentsComponent.forward_leaf_event/2 " <>
              "returned an unexpected value (#{inspect(other)}); ignoring."
          )

          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end
end
