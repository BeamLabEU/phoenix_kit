defmodule PhoenixKit.Notifications.Render do
  @moduledoc """
  Human-readable rendering for notifications.

  Maps `{activity.action, activity.metadata}` → `%{icon, text, link, actor_uuid}`
  so the bell dropdown and inbox page don't need to know the action taxonomy.

  Unknown actions fall back to the raw action string with a generic icon, so a
  new action that hasn't been mapped yet still displays safely.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @type render_result :: %{
          icon: String.t(),
          text: String.t(),
          link: String.t() | nil,
          actor_uuid: String.t() | nil
        }

  @doc """
  Returns the display payload for a notification.

  `notification.activity` must be preloaded. `locale` is the recipient's current
  locale (base code, e.g. `"en"`); it's threaded into the built link so the
  click-through lands on the right locale-prefixed path. When `nil`, link
  building falls back to `Routes.path`'s `determine_locale/0` (the process
  Gettext locale) — used by callers that don't track a locale (e.g. the admin
  inbox). The metadata `notification_link` override is returned verbatim and is
  expected to already be prefix/locale-correct (built via `Routes.path/1`).
  """
  @spec render(Notification.t(), String.t() | nil) :: render_result()
  def render(notification, locale \\ nil)

  def render(%Notification{} = notification, locale) do
    # Every default string below is a msgid, and these render on a background
    # worker or on behalf of another user — so the recipient's locale arrives
    # as an argument and has to be installed on the process for the lookup.
    # `nil` means "leave the current locale alone" (the admin inbox, which
    # renders in the viewer's own language).
    RecipientLocale.in_locale(locale, fn -> do_render(notification, locale) end)
  end

  defp do_render(%Notification{activity: %_{} = activity}, locale) do
    meta = activity.metadata || %{}
    {default_icon, default_text} = icon_and_text(activity.action, meta)

    # Metadata overrides let callers ship custom display without touching the
    # Render action lookup. Any of the three keys can be present independently.
    %{
      icon: meta_string(meta, "notification_icon") || default_icon,
      text: meta_string(meta, "notification_text") || default_text,
      link: meta_string(meta, "notification_link") || link_for(activity, locale),
      actor_uuid: activity.actor_uuid
    }
  end

  defp do_render(%Notification{} = notification, _locale) do
    # Standalone notification (V126): `activity` is nil, so this clause —
    # not the `%_{}` activity clause above — matches. (An activity-linked
    # row that wasn't preloaded carries `%Ecto.Association.NotLoaded{}`,
    # which is a struct and would match the clause above; every read path
    # preloads `:activity`, so that case doesn't reach Render.) Read the
    # display content from the notification's own metadata (same override
    # keys as activity metadata); fall back to a safe generic notice.
    meta = notification.metadata || %{}

    %{
      icon: meta_string(meta, "notification_icon") || "hero-bell",
      text: meta_string(meta, "notification_text") || gettext("You have a new notification."),
      link: meta_string(meta, "notification_link"),
      actor_uuid: nil
    }
  end

  # ── Action → (icon, text) ────────────────────────────────────────────

  defp icon_and_text("user.roles_updated", meta) do
    added = Map.get(meta, "roles_added") || Map.get(meta, "added")

    text =
      if blank?(added) do
        gettext("Your roles were updated.")
      else
        gettext("Your roles were updated (added: %{roles}).", roles: inspect(added))
      end

    {"hero-identification", text}
  end

  defp icon_and_text("user.status_changed", meta) do
    status = Map.get(meta, "status_to") || Map.get(meta, "status")

    text =
      if blank?(status) do
        gettext("Your account status was updated.")
      else
        gettext("Your account status was updated to %{status}.", status: status)
      end

    {"hero-user-circle", text}
  end

  defp icon_and_text("user.password_changed", _meta) do
    {"hero-lock-closed", gettext("Your password was changed by an administrator.")}
  end

  defp icon_and_text("user.password_reset", _meta) do
    {"hero-key", gettext("Your password was reset.")}
  end

  defp icon_and_text("user.email_changed", meta) do
    new_email = Map.get(meta, "new_email")

    text =
      if blank?(new_email) do
        gettext("Your email was changed.")
      else
        gettext("Your email was changed to %{email}.", email: new_email)
      end

    {"hero-envelope", text}
  end

  defp icon_and_text("user.email_confirmed", _meta) do
    {"hero-check-badge", gettext("Your email was confirmed.")}
  end

  defp icon_and_text("user.email_unconfirmed", _meta) do
    {"hero-exclamation-circle", gettext("Your email is no longer confirmed.")}
  end

  defp icon_and_text("user.avatar_changed", _meta) do
    {"hero-user-circle", gettext("Your avatar was updated.")}
  end

  defp icon_and_text("user.profile_updated", _meta) do
    {"hero-pencil-square", gettext("Your profile was updated.")}
  end

  defp icon_and_text("organization.manager_added", meta) do
    {"hero-user-plus",
     gettext("You can now act for %{organization}.",
       organization: meta_string(meta, "organization_name") || gettext("the organization")
     )}
  end

  defp icon_and_text("organization.manager_removed", meta) do
    {"hero-user-minus",
     gettext("Your access to act for %{organization} was removed.",
       organization: meta_string(meta, "organization_name") || gettext("the organization")
     )}
  end

  defp icon_and_text("user.timezone_mismatch", meta) do
    case meta_string(meta, "detected_timezone") do
      nil ->
        {"hero-globe-alt", gettext("Your timezone looks wrong for where you are.")}

      zone ->
        {"hero-globe-alt",
         gettext("You appear to be in %{zone}, which is not your saved timezone.", zone: zone)}
    end
  end

  defp icon_and_text("user.note_created", _meta) do
    {"hero-clipboard-document", gettext("An admin added a note on your account.")}
  end

  defp icon_and_text("user.note_deleted", _meta) do
    {"hero-clipboard-document", gettext("An admin removed a note from your account.")}
  end

  defp icon_and_text("post.liked", _meta) do
    {"hero-heart", gettext("Someone liked your post.")}
  end

  defp icon_and_text("post.commented", _meta) do
    {"hero-chat-bubble-left-ellipsis", gettext("Someone commented on your post.")}
  end

  defp icon_and_text("comment.liked", _meta) do
    {"hero-heart", gettext("Someone liked your comment.")}
  end

  defp icon_and_text("user.followed", _meta) do
    {"hero-user-plus", gettext("Someone started following you.")}
  end

  # Both session actions reach the inbox because `Activity.log/1` fans out on
  # `target_uuid`, and both name the account that was ADDED — so the recipient
  # is the person whose account someone else is now signed into. Without these
  # clauses they render as the humanized action string ("Session impersonated"),
  # which reads like a system log line rather than a notice addressed to them.
  defp icon_and_text("session.impersonated", _meta) do
    {"hero-identification", gettext("An administrator signed in to your account for support.")}
  end

  defp icon_and_text("session.account_added", _meta) do
    {"hero-user-plus", gettext("Your account was added to another sign-in session.")}
  end

  defp icon_and_text(action, _meta) when is_binary(action) do
    {"hero-bell", humanize(action)}
  end

  defp icon_and_text(_action, _meta) do
    {"hero-bell", gettext("New notification.")}
  end

  # ── Action → link ────────────────────────────────────────────────────

  # Core account actions that land on the user's settings page. These are the
  # only links core can build itself; everything else (social/module actions)
  # must ship a `notification_link` in metadata (see moduledoc). Matched
  # explicitly — NOT via a broad `"user." <> _` prefix, which used to wrongly
  # capture `user.followed` (a connections action) and send it to settings.
  @account_actions ~w(
    user.roles_updated user.status_changed user.password_changed user.password_reset
    user.email_changed user.email_confirmed user.email_unconfirmed user.avatar_changed
    user.profile_updated user.note_created user.note_deleted user.timezone_mismatch
    organization.manager_added organization.manager_removed
  )

  defp link_for(%_{action: action}, locale) when action in @account_actions do
    Routes.user_settings_path(locale: locale)
  end

  # No default deep-link target for module-owned actions (user.followed, post.*,
  # comment.*) or unknown actions, nor for user.deleted (the account is gone).
  # The caller decides what to do when `link` is nil; a deep-link must come from
  # the emitter's `notification_link` metadata.
  defp link_for(_activity, _locale), do: nil

  # ── Helpers ──────────────────────────────────────────────────────────

  # A metadata detail is "blank" when absent or empty — the caller then picks
  # the shorter of two complete sentences rather than concatenating a suffix
  # onto a translated stem, which no translator could reorder.
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

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
