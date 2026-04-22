defmodule PhoenixKit.Notifications.Render do
  @moduledoc """
  Human-readable rendering for notifications.

  Maps `{activity.action, activity.metadata}` → `%{icon, text, link, actor_uuid}`
  so the bell dropdown and inbox page don't need to know the action taxonomy.

  Unknown actions fall back to the raw action string with a generic icon, so a
  new action that hasn't been mapped yet still displays safely.
  """

  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Utils.Routes

  @type render_result :: %{
          icon: String.t(),
          text: String.t(),
          link: String.t() | nil,
          actor_uuid: String.t() | nil
        }

  @doc """
  Returns the display payload for a notification.

  `notification.activity` must be preloaded.
  """
  @spec render(Notification.t()) :: render_result()
  def render(%Notification{activity: %_{} = activity}) do
    meta = activity.metadata || %{}
    {default_icon, default_text} = icon_and_text(activity.action, meta)

    # Metadata overrides let callers ship custom display without touching the
    # Render action lookup. Any of the three keys can be present independently.
    %{
      icon: meta_string(meta, "notification_icon") || default_icon,
      text: meta_string(meta, "notification_text") || default_text,
      link: meta_string(meta, "notification_link") || link_for(activity),
      actor_uuid: activity.actor_uuid
    }
  end

  def render(%Notification{} = _notification) do
    # Activity wasn't preloaded — render a safe fallback.
    %{
      icon: "hero-bell",
      text: "You have a new notification.",
      link: nil,
      actor_uuid: nil
    }
  end

  # ── Action → (icon, text) ────────────────────────────────────────────

  defp icon_and_text("user.roles_updated", meta) do
    added = Map.get(meta, "roles_added") || Map.get(meta, "added")

    {"hero-identification",
     "Your roles were updated#{suffix_if(added, " (added: #{inspect(added)})")}."}
  end

  defp icon_and_text("user.status_changed", meta) do
    status = Map.get(meta, "status_to") || Map.get(meta, "status")
    {"hero-user-circle", "Your account status was updated#{suffix_if(status, " to #{status}")}."}
  end

  defp icon_and_text("user.password_changed", _meta) do
    {"hero-lock-closed", "Your password was changed by an administrator."}
  end

  defp icon_and_text("user.password_reset", _meta) do
    {"hero-key", "Your password was reset."}
  end

  defp icon_and_text("user.email_changed", meta) do
    new_email = Map.get(meta, "new_email")
    {"hero-envelope", "Your email was changed#{suffix_if(new_email, " to #{new_email}")}."}
  end

  defp icon_and_text("user.email_confirmed", _meta) do
    {"hero-check-badge", "Your email was confirmed."}
  end

  defp icon_and_text("user.avatar_changed", _meta) do
    {"hero-user-circle", "Your avatar was updated."}
  end

  defp icon_and_text("user.profile_updated", _meta) do
    {"hero-pencil-square", "Your profile was updated."}
  end

  defp icon_and_text("user.note_created", _meta) do
    {"hero-clipboard-document", "An admin added a note on your account."}
  end

  defp icon_and_text("user.note_deleted", _meta) do
    {"hero-clipboard-document", "An admin removed a note from your account."}
  end

  defp icon_and_text("post.liked", _meta) do
    {"hero-heart", "Someone liked your post."}
  end

  defp icon_and_text("post.commented", _meta) do
    {"hero-chat-bubble-left-ellipsis", "Someone commented on your post."}
  end

  defp icon_and_text("comment.liked", _meta) do
    {"hero-heart", "Someone liked your comment."}
  end

  defp icon_and_text("user.followed", _meta) do
    {"hero-user-plus", "Someone started following you."}
  end

  defp icon_and_text(action, _meta) when is_binary(action) do
    {"hero-bell", humanize(action)}
  end

  defp icon_and_text(_action, _meta) do
    {"hero-bell", "New notification."}
  end

  # ── Action → link ────────────────────────────────────────────────────

  defp link_for(%_{action: "user." <> _verb}), do: Routes.path("/dashboard/settings")

  # No default deep-link target: the caller decides what to do when `link` is nil.
  defp link_for(_activity), do: nil

  # ── Helpers ──────────────────────────────────────────────────────────

  defp suffix_if(nil, _), do: ""
  defp suffix_if("", _), do: ""
  defp suffix_if(_value, suffix), do: suffix

  # Returns the metadata string for `key` iff it's a non-empty binary;
  # otherwise nil so the caller can fall through to the default.
  defp meta_string(meta, key) when is_map(meta) and is_binary(key) do
    case Map.get(meta, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp meta_string(_meta, _key), do: nil

  defp humanize(action) do
    action
    |> String.replace(".", " ")
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
