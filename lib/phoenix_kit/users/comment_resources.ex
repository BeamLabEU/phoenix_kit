defmodule PhoenixKit.Users.CommentResources do
  @moduledoc """
  Resolves `"user"` comment resources for the comments moderation admin.

  A comment attached to a user (`resource_type: "user"`, `resource_uuid:
  user_uuid`) resolves to the user's display name + admin detail page
  (`/admin/users/view/:uuid`), with their avatar as the chip thumbnail — so the
  moderation list links to the user instead of showing a bare uuid.

  Registered as the `"user"` handler by `phoenix_kit_comments`'
  `resolve_comment_resources/1` dispatch (gated on this module being loaded).
  Mirrors `PhoenixKit.Annotations.resolve_comment_resources/1` (the `"file"`
  handler).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitWeb.Components.Core.UserInfo

  @spec resolve_comment_resources([binary()]) :: %{binary() => map()}
  def resolve_comment_resources(resource_uuids) when is_list(resource_uuids) do
    from(u in User, where: u.uuid in ^resource_uuids)
    |> RepoHelper.all()
    |> Map.new(fn user ->
      # Raw path — the comments module applies Routes.path/1 once when rendering
      # the chip (pre-applying it here would double-prefix under a url_prefix).
      info = %{
        title: display_name(user),
        path: "/admin/users/view/#{user.uuid}"
      }

      info =
        case avatar_thumb(user) do
          nil -> info
          {url, nil} -> Map.put(info, :thumb_url, url)
          {url, style} -> info |> Map.put(:thumb_url, url) |> Map.put(:thumb_style, style)
        end

      {user.uuid, info}
    end)
  rescue
    _ -> %{}
  end

  # This module is the registered `ResourceLinks` handler for the "user"
  # type, so it names every `@` mention everywhere — including public issue
  # boards. The old `|| user.email` fallback therefore published a full
  # address for any commenter who had not set a name.
  defp display_name(user), do: User.display_name(user)

  # The person's picture by the rule of every face (`UserInfo.avatar_brief/2`:
  # uploaded with its crop, the OAuth provider's, Gravatar), so the comments
  # list shows the same face as a chip or a card (Max, 2026-11-26). It used
  # to skip Gravatar and the crop.
  defp avatar_thumb(user) do
    case UserInfo.avatar_brief(user) do
      %{url: url, style: style} when is_binary(url) -> {url, style}
      _ -> nil
    end
  end
end
