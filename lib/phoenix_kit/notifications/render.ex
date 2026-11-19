defmodule PhoenixKit.Notifications.Render do
  @moduledoc """
  Human-readable rendering for notifications.

  Maps `{activity.action, activity.metadata}` → `%{icon, text, link, actor_uuid}`
  so the bell dropdown and inbox page don't need to know the action taxonomy.

  Unknown actions fall back to the raw action string with a generic icon, so a
  new action that hasn't been mapped yet still displays safely.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Notifications.Notification
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Roles
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

  @doc """
  Why the recipient got this notification: the setting line that sent it and
  a link to that line, or nil when no line owns it (an action no type claims,
  a standalone notification without a type).

      %{key: "projects.handoffs", label: "Projects › A task of yours can be started",
        text: "You get this because “Projects › …” is on.", link: "/…#notif-projects-handoffs"}

  `recipient` decides where the link goes: someone who reaches the admin
  area (`Scope.can_access_admin_area?/1`) to the matrix row on My Settings
  (`/admin/notifications/settings#notif-<key>`); anyone else to the
  Notifications section of their profile settings, the page they have.
  Rendered in `locale` like `render/2`. The inbox and the bell show it under
  every notification; email and Telegram carry its text and link.
  """
  @spec reason(Notification.t(), User.t() | Scope.t() | nil, String.t() | nil) ::
          %{key: String.t(), label: String.t(), text: String.t(), link: String.t()} | nil
  def reason(%Notification{} = notification, recipient, locale \\ nil) do
    reason_for_key(type_key(notification), recipient, locale)
  rescue
    _ -> nil
  end

  @doc "`reason/3` for a setting line's key (a digest's, say); nil for no line."
  @spec reason_for_key(String.t() | nil, User.t() | Scope.t() | nil, String.t() | nil) ::
          %{key: String.t(), label: String.t(), text: String.t(), link: String.t()} | nil
  def reason_for_key(key, recipient, locale) when is_binary(key) do
    RecipientLocale.in_locale(locale, fn ->
      case Types.line_label(key) do
        label when is_binary(label) and label != "" ->
          %{
            key: key,
            label: label,
            text: gettext("You get this because “%{line}” is on.", line: label),
            link: settings_link(recipient, key, locale)
          }

        _ ->
          nil
      end
    end)
  rescue
    _ -> nil
  end

  def reason_for_key(_key, _recipient, _locale), do: nil

  defp type_key(%Notification{activity: %_{action: action}}) when is_binary(action),
    do: Types.key_for_action(action)

  defp type_key(%Notification{metadata: %{} = meta}) do
    case meta["type"] || meta["type_key"] do
      key when is_binary(key) -> if Types.line_label(key), do: key
      _ -> nil
    end
  end

  defp type_key(_), do: nil

  @quote_cap 2000

  @doc """
  The message a notification carries, shown as its own block under its
  line — the comment left in a "mark done" dialog, a reopen reason, the
  comment someone was mentioned in. Set by the module that logs the
  activity, in its metadata (or a standalone notification's):

      "quote" => %{
        "text" => "Measured again, wall A is 3240.",   # required, markdown
        "author_uuid" => "019…",                       # optional, the writer's account
        "author_name" => "Anna Kask"                    # optional, shown when no account
      }

  Answers `%{text:, author_uuid:, author_name:, truncated?:}` or nil (no
  quote, or an empty text). Mention tokens in the text become their
  labels; the text is cut at #{@quote_cap} characters for display
  (`truncated?`). The inbox renders `text` as sanitized markdown; email and
  Telegram carry it as plain text.
  """
  @spec quote(Notification.t()) ::
          %{
            text: String.t(),
            author_uuid: String.t() | nil,
            author_name: String.t() | nil,
            truncated?: boolean()
          }
          | nil
  def quote(%Notification{} = notification) do
    with %{} = q <- quote_meta(notification),
         text when is_binary(text) <- q["text"],
         text = text |> Token.to_plain_text() |> String.trim(),
         true <- text != "" do
      truncated? = String.length(text) > @quote_cap

      %{
        text: if(truncated?, do: String.slice(text, 0, @quote_cap) <> "…", else: text),
        author_uuid: string_or_nil(q["author_uuid"]),
        author_name: string_or_nil(q["author_name"]),
        truncated?: truncated?
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def quote(_), do: nil

  defp quote_meta(%Notification{activity: %_{metadata: %{"quote" => %{} = q}}}), do: q
  defp quote_meta(%Notification{metadata: %{"quote" => %{} = q}}), do: q
  defp quote_meta(_), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  @doc """
  A quote as plain text for a channel without HTML (Telegram, an email's
  text part): `Anna Kask: “…”`, or the text alone without a name.
  """
  @spec quote_text(map() | nil, String.t() | nil) :: String.t() | nil
  def quote_text(nil, _name), do: nil

  def quote_text(%{text: text}, name) when is_binary(name) and name != "",
    do: "#{name}: “#{text}”"

  def quote_text(%{text: text}, _name), do: "“#{text}”"

  @doc false
  # Where `recipient` changes the line `key`: the matrix row for someone who
  # reaches the admin area, else their profile's Notifications section.
  @spec settings_link(User.t() | Scope.t() | nil, String.t(), String.t() | nil) :: String.t()
  def settings_link(recipient, key, locale) do
    if matrix_reader?(recipient),
      do: Routes.path("/admin/notifications/settings", locale: locale) <> "#notif-" <> key,
      else: Routes.path("/profile/settings", locale: locale) <> "#notification-settings"
  end

  # My Settings is a personal admin view: anyone who reaches the admin area
  # opens it (`PhoenixKitWeb.Users.Auth`'s `@personal_admin_views`).
  defp matrix_reader?(%Scope{} = scope), do: Scope.can_access_admin_area?(scope)

  defp matrix_reader?(%User{} = user),
    do: user |> Scope.for_user() |> Scope.can_access_admin_area?()

  defp matrix_reader?(_), do: false

  # ── Action → (icon, text) ────────────────────────────────────────────

  defp icon_and_text("user.roles_updated", meta) do
    added = Map.get(meta, "roles_added") || Map.get(meta, "added")

    text =
      if blank?(added) do
        gettext("Your roles were updated.")
      else
        gettext("Your roles were updated (added: %{roles}).", roles: role_names(added))
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

  # An admin re-framing someone's picture changes how the avatar looks just as
  # a new picture does, so it reads the same.
  defp icon_and_text(action, _meta)
       when action in ["user.avatar_changed", "user.avatar_crop_changed"] do
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

  defp icon_and_text("organization.manager_changed", meta) do
    {"hero-identification",
     gettext("Your access to act for %{organization} was updated.",
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

  # Reaches the inbox through the activity only when someone else removed it (an
  # administrator); the owner's own removal is told by `PhoenixKit.Users.Passkeys`.
  defp icon_and_text("user.passkey_removed", meta) do
    name = Map.get(meta, "passkey_name")

    text =
      if blank?(name) do
        gettext("An administrator removed a passkey from your account.")
      else
        gettext("An administrator removed a passkey from your account: %{name}.", name: name)
      end

    {"hero-finger-print", text}
  end

  # A ping from `PhoenixKit.Mentions.notify/2`. The author's name rides in
  # the metadata (the bell shows no actor of its own); a mention from before
  # the name was stored carries its own `notification_text`, which wins.
  defp icon_and_text("mention.created", %{"actor_name" => name})
       when is_binary(name) and name != "" do
    {"hero-at-symbol", gettext("%{name} mentioned you.", name: name)}
  end

  defp icon_and_text("mention.created", _meta) do
    {"hero-at-symbol", gettext("You were mentioned.")}
  end

  defp icon_and_text("session.account_added", _meta) do
    {"hero-user-plus", gettext("Your account was added to another sign-in session.")}
  end

  # No longer sent: switching between two accounts signed in in the same
  # browser affects nobody else (`MultiSession` logs it without a target).
  # Kept for the rows sent before.
  defp icon_and_text("session.switched", _meta) do
    {"hero-arrows-right-left",
     gettext("You switched to this account from another signed-in account.")}
  end

  defp icon_and_text("user.created", _meta) do
    {"hero-user-plus", gettext("An administrator created your account.")}
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
    user.avatar_crop_changed user.profile_updated user.note_created user.note_deleted user.timezone_mismatch
    organization.manager_added organization.manager_changed organization.manager_removed
    user.passkey_removed
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

  # Role names as the recipient sees them (each role's label in their
  # language), joined. One query, and only for this notification.
  defp role_names(names) when is_list(names) do
    labels = Roles.display_names()
    Enum.map_join(names, ", ", &Map.get(labels, to_string(&1), to_string(&1)))
  end

  defp role_names(name) when is_binary(name), do: role_names([name])
  defp role_names(other), do: inspect(other)

  defp humanize(action) do
    action
    |> String.replace(".", " ")
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
