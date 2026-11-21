defmodule PhoenixKit.Notifications.Push do
  @moduledoc """
  Browser push notifications (the boss's request, 2026-11-20; the plan,
  decided with Max on 2026-11-21, is in the PhoenixKit notes as "PhoenixKit
  push notifications — plan").

  ## How it fits

  `push` is a notification channel like email and Telegram
  (`PhoenixKit.Notifications.Channels.Push`): the delivery worker hands it an
  envelope when the reader routed the notification's type to "Browser". The
  channel does not send at once: it **queues** the notice (`queue/1`) and a
  job sends **one push per user per short window** (`group_seconds/0`, 30 s by
  default) — one notice says "New notification", several say "3
  notifications pending" (`PhoenixKit.Notifications.Push.GroupWorker`). Each
  device is then sent to on its own (`PhoenixKit.Notifications.Push.SendWorker`),
  so one dead device never holds up the others.

  ## Devices and accounts

  A browser turns push on with its subscription (`subscribe/3`): one
  **installation** per browser (its endpoint, keys, the VAPID key it was made
  with, the browser's own id from a cookie), and one **binding** per account
  that opted in there — made by that account itself, signed in for real; a
  borrowed (impersonated) session is refused. Logging out, or removing the
  account from the switcher, drops that account's binding on that browser
  (`forget_browser/2`); the last binding gone, the installation goes too.

  ## What a push says

  By default nothing that could be confidential on a locked screen: the
  site's name and "New notification" / "N notifications pending". A site may
  show the notification's line instead (`show_line?/0`, setting
  `push_show_line`). The quoted comment is never sent. A notification the
  reader can no longer see (the type's `visible` check) is not pushed at all.
  The click opens `PhoenixKitWeb.PushOpenController` with an opaque,
  encrypted handle — never the notification's or the user's uuid in the
  clear.

  ## Settings

  `push_enabled` (default on), `push_show_line` (default off),
  `push_group_seconds` (default 30). Messages are kept by the push service
  for up to 7 days while a device is off (`ttl/0`); a newer push of the same
  user replaces an older one still waiting there (`Topic`).
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Push.{Binding, GroupWorker, Installation, Pending, WebPush}
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @channel "push"
  @max_devices 10
  @ttl 7 * 24 * 3600
  @handle_age 7 * 24 * 3600

  # ── Settings ──────────────────────────────────────────────────────────

  @doc "Whether the site offers browser push (`push_enabled`, default on)."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting("push_enabled", true)

  @doc "Whether a push shows the notification's line (`push_show_line`, default off)."
  @spec show_line?() :: boolean()
  def show_line?, do: Settings.get_boolean_setting("push_show_line", false)

  @doc "The grouping window in seconds (`push_group_seconds`, default 30, 5–600)."
  @spec group_seconds() :: pos_integer()
  def group_seconds do
    case Integer.parse(to_string(Settings.get_setting("push_group_seconds", "30"))) do
      {n, ""} -> n |> max(5) |> min(600)
      _ -> 30
    end
  end

  @doc "How long a push service keeps a message for a device that is off (7 days)."
  def ttl, do: @ttl

  @doc "The most devices one account may have."
  def max_devices, do: @max_devices

  # ── Devices ───────────────────────────────────────────────────────────

  @doc """
  Turns push on for `user` in this browser. `subscription` is the browser's
  `PushSubscription` as JSON (`endpoint`, `keys.p256dh`, `keys.auth`).

  Options: `:browser_id` (the browser's own id, from its cookie), `:label`
  ("Chrome on Mac"), `:impersonated` (must be exactly `false`).

  The first time an account turns push on, its per-type choices start as its
  email ones (Max, 2026-11-21), shown on the settings page to change.

  Errors: `:not_enabled`, `:impersonated`, `:not_allowed` (a managed
  organization, a service user, an inactive account), `:bad_subscription`,
  `:endpoint_refused`, `:too_many_devices`.
  """
  @spec subscribe(User.t(), map(), keyword()) :: {:ok, Installation.t()} | {:error, atom()}
  def subscribe(%User{} = user, subscription, opts \\ []) do
    with :ok <- if(enabled?(), do: :ok, else: {:error, :not_enabled}),
         :ok <- if(opts[:impersonated] == false, do: :ok, else: {:error, :impersonated}),
         :ok <- allowed_account(user),
         {:ok, endpoint, p256dh, auth} <- parse_subscription(subscription),
         :ok <- if(WebPush.endpoint_ok?(endpoint), do: :ok, else: {:error, :endpoint_refused}),
         :ok <- device_room(user, endpoint) do
      RepoHelper.repo().transaction(fn ->
        installation = upsert_installation(endpoint, p256dh, auth, opts)
        bind(installation, user)
        installation
      end)
      |> tap(fn
        {:ok, _} -> start_with_email_types(user)
        _ -> :ok
      end)
    end
  end

  defp allowed_account(%User{is_active: true, managed_by_members: false} = user) do
    if Map.get(user, :api_only, false) == true, do: {:error, :not_allowed}, else: :ok
  end

  defp allowed_account(_user), do: {:error, :not_allowed}

  @doc false
  def parse_subscription(%{
        "endpoint" => endpoint,
        "keys" => %{"p256dh" => p256dh, "auth" => auth}
      })
      when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) and
             byte_size(p256dh) <= 255 and byte_size(auth) <= 255 do
    with {:ok, key} <- Base.url_decode64(String.trim_trailing(p256dh, "="), padding: false),
         65 <- byte_size(key),
         {:ok, secret} <- Base.url_decode64(String.trim_trailing(auth, "="), padding: false),
         16 <- byte_size(secret) do
      {:ok, endpoint, p256dh, auth}
    else
      _ -> {:error, :bad_subscription}
    end
  end

  def parse_subscription(_), do: {:error, :bad_subscription}

  defp device_room(user, endpoint) do
    hash = hash(endpoint)

    count =
      from(b in Binding,
        join: i in Installation,
        on: i.uuid == b.installation_uuid,
        where: b.user_uuid == ^user.uuid and i.endpoint_hash != ^hash,
        select: count()
      )
      |> RepoHelper.repo().one()

    if count < @max_devices, do: :ok, else: {:error, :too_many_devices}
  end

  defp upsert_installation(endpoint, p256dh, auth, opts) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = %{
      endpoint: endpoint,
      endpoint_hash: hash(endpoint),
      p256dh: p256dh,
      auth: auth,
      label: opts[:label] |> to_string() |> String.slice(0, 160),
      browser_id: clean_browser_id(opts[:browser_id]),
      vapid_key_id: WebPush.vapid_key_id() || "unknown",
      inserted_at: now,
      updated_at: now
    }

    {1, [installation]} =
      RepoHelper.repo().insert_all(Installation, [attrs],
        on_conflict:
          {:replace, [:endpoint, :p256dh, :auth, :label, :browser_id, :vapid_key_id, :updated_at]},
        conflict_target: :endpoint_hash,
        returning: true
      )

    installation
  end

  defp bind(installation, user) do
    RepoHelper.repo().insert_all(
      Binding,
      [%{installation_uuid: installation.uuid, user_uuid: user.uuid}],
      on_conflict: :nothing,
      conflict_target: [:installation_uuid, :user_uuid]
    )
  end

  # The first time push is turned on, the types the account gets by email.
  defp start_with_email_types(user) do
    user = Auth.get_user(user.uuid) || user

    if not Map.has_key?(ChannelConfig.for_channel(user, @channel), "types") do
      email_types = ChannelConfig.for_channel(user, "email")["types"] || %{}

      ChannelConfig.update(user, @channel, fn config ->
        config |> Map.put("enabled", true) |> Map.put("types", email_types)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "The account's devices, newest first: `%{uuid, label, last_success_at, inserted_at, endpoint_hash}`."
  @spec devices(String.t()) :: [map()]
  def devices(user_uuid) when is_binary(user_uuid) do
    from(i in Installation,
      join: b in Binding,
      on: b.installation_uuid == i.uuid,
      where: b.user_uuid == ^user_uuid,
      order_by: [desc: i.inserted_at],
      select: %{
        uuid: i.uuid,
        label: i.label,
        last_success_at: i.last_success_at,
        inserted_at: i.inserted_at,
        endpoint_hash: i.endpoint_hash
      }
    )
    |> RepoHelper.repo().all()
  end

  @doc "Whether the account has a device to push to (the channel's `configured?`)."
  @spec any_device?(String.t()) :: boolean()
  def any_device?(user_uuid) when is_binary(user_uuid) do
    from(b in Binding, where: b.user_uuid == ^user_uuid, select: 1, limit: 1)
    |> RepoHelper.repo().one()
    |> Kernel.==(1)
  rescue
    _ -> false
  end

  def any_device?(_), do: false

  @doc """
  The device `endpoint` belongs to, as the browser reports it ("this
  device" on the settings page): its installation uuid, or nil.
  """
  @spec installation_for(String.t()) :: Installation.t() | nil
  def installation_for(endpoint) when is_binary(endpoint) do
    RepoHelper.repo().get_by(Installation, endpoint_hash: hash(endpoint))
  end

  def installation_for(_), do: nil

  @doc """
  Removes the account's binding on a device; the device goes too when no
  account is left on it. Any account may remove its own, even in a
  borrowed session (like revoking a key).
  """
  @spec remove_device(String.t(), String.t()) :: :ok
  def remove_device(user_uuid, installation_uuid)
      when is_binary(user_uuid) and is_binary(installation_uuid) do
    with {:ok, id} <- Ecto.UUID.cast(installation_uuid) do
      from(b in Binding, where: b.user_uuid == ^user_uuid and b.installation_uuid == ^id)
      |> RepoHelper.repo().delete_all()

      drop_if_unbound(id)
    end

    :ok
  end

  @doc """
  Logging out or leaving the switcher in a browser: drops the account's
  bindings on that browser's installations (`browser_id` from its cookie).
  """
  @spec forget_browser(String.t() | nil, String.t() | nil) :: :ok
  def forget_browser(user_uuid, browser_id) when is_binary(user_uuid) and is_binary(browser_id) do
    case clean_browser_id(browser_id) do
      nil ->
        :ok

      id ->
        ids =
          from(i in Installation, where: i.browser_id == ^id, select: i.uuid)
          |> RepoHelper.repo().all()

        from(b in Binding, where: b.user_uuid == ^user_uuid and b.installation_uuid in ^ids)
        |> RepoHelper.repo().delete_all()

        Enum.each(ids, &drop_if_unbound/1)
        :ok
    end
  rescue
    _ -> :ok
  end

  def forget_browser(_user_uuid, _browser_id), do: :ok

  defp drop_if_unbound(installation_uuid) do
    repo = RepoHelper.repo()

    unless repo.exists?(from(b in Binding, where: b.installation_uuid == ^installation_uuid)) do
      from(i in Installation, where: i.uuid == ^installation_uuid) |> repo.delete_all()
    end

    :ok
  end

  @doc """
  A browser's subscription changed (`pushsubscriptionchange`): the old one is
  replaced by the new, keeping its accounts. The old subscription's `auth`
  secret proves the request comes from that browser — the service worker
  sends it, and nobody else holds it.
  """
  @spec resubscribe(String.t(), String.t(), map()) :: :ok | {:error, atom()}
  def resubscribe(old_endpoint, old_auth, new_subscription)
      when is_binary(old_endpoint) and is_binary(old_auth) do
    with %Installation{} = old <- installation_for(old_endpoint),
         true <- Plug.Crypto.secure_compare(old.auth, old_auth) || {:error, :not_found},
         {:ok, endpoint, p256dh, auth} <- parse_subscription(new_subscription),
         true <- WebPush.endpoint_ok?(endpoint) || {:error, :endpoint_refused} do
      old
      |> Ecto.Changeset.change(%{
        endpoint: endpoint,
        endpoint_hash: hash(endpoint),
        p256dh: p256dh,
        auth: auth,
        vapid_key_id: WebPush.vapid_key_id() || old.vapid_key_id
      })
      |> RepoHelper.repo().update()
      |> case do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :conflict}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def resubscribe(_old, _auth, _new), do: {:error, :bad_subscription}

  @doc false
  def hash(endpoint), do: :crypto.hash(:sha256, endpoint)

  defp clean_browser_id(id) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{16,64}\z/, id), do: id, else: nil
  end

  defp clean_browser_id(_), do: nil

  # ── Queueing and grouping ─────────────────────────────────────────────

  @doc """
  Queues a notice for its reader's next push and makes sure one push is due
  within the grouping window. Called by the channel.
  """
  @spec queue(map()) :: :ok | {:error, term()}
  def queue(%{recipient_uuid: user_uuid} = envelope) when is_binary(user_uuid) do
    %Pending{
      user_uuid: user_uuid,
      notification_uuid: valid_uuid(envelope[:notification_uuid]),
      type_key: envelope[:type_key],
      title: envelope[:title],
      line: envelope[:text],
      link: envelope[:url]
    }
    |> RepoHelper.repo().insert()
    |> case do
      {:ok, _} ->
        GroupWorker.schedule(user_uuid, group_seconds())

      {:error, _} = error ->
        error
    end
  end

  defp valid_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end

  @doc """
  Takes every notice waiting for `user_uuid` (deleting them) and builds the
  one push for them, in the reader's language: `{:ok, payload_map}` or
  `:none`.
  """
  @spec take_pending(String.t()) :: {:ok, map()} | :none
  def take_pending(user_uuid) when is_binary(user_uuid) do
    {_, rows} =
      from(p in Pending, where: p.user_uuid == ^user_uuid, select: p)
      |> RepoHelper.repo().delete_all()

    case {rows, Auth.get_user(user_uuid)} do
      {[], _} -> :none
      {_, nil} -> :none
      {rows, user} -> {:ok, payload(user, Enum.sort_by(rows, & &1.inserted_at, NaiveDateTime))}
    end
  end

  @doc false
  def payload(user, rows) do
    count = length(rows)
    latest = List.last(rows)
    site = site_name()

    RecipientLocale.in_locale(RecipientLocale.base(user), fn ->
      {title, body} =
        if show_line?() do
          title = present(latest.title) || site

          body =
            if count == 1,
              do: present(latest.line) || gettext("New notification"),
              else:
                ngettext(
                  "%{count} notification pending — latest: %{line}",
                  "%{count} notifications pending — latest: %{line}",
                  count,
                  line: present(latest.line) || ""
                )

          {title, body}
        else
          body =
            if count == 1,
              do: gettext("New notification"),
              else:
                ngettext(
                  "%{count} notification pending",
                  "%{count} notifications pending",
                  count
                )

          {site, body}
        end

      %{
        "title" => String.slice(title, 0, 120),
        "body" => String.slice(body, 0, 400),
        "url" => open_url(user.uuid, latest.link, count > 1),
        "tag" => "pk-" <> short_id(user.uuid),
        "count" => count,
        "icon" => icon_url()
      }
    end)
  end

  @doc "The push service `Topic` of a user's pushes: their id without dashes, 32 characters."
  def topic(user_uuid), do: short_id(user_uuid)

  defp short_id(uuid), do: uuid |> to_string() |> String.replace("-", "")

  defp site_name do
    case Settings.get_project_title() do
      name when is_binary(name) and name != "" -> name
      _ -> "PhoenixKit"
    end
  rescue
    _ -> "PhoenixKit"
  end

  defp icon_url do
    Branding.logo_url()
  rescue
    _ -> nil
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # ── The click ─────────────────────────────────────────────────────────

  @doc """
  The address a push opens: core's open route with an opaque handle (the
  account, the link, whether it is a summary, an expiry), encrypted and
  authenticated with `PhoenixKit.Integrations.Encryption`.
  """
  @spec open_url(String.t(), String.t() | nil, boolean()) :: String.t()
  def open_url(user_uuid, link, summary?) do
    handle =
      %{
        "u" => user_uuid,
        "l" => same_site_link(link),
        "s" => summary?,
        "x" => System.system_time(:second) + @handle_age
      }
      |> Jason.encode!()
      |> Encryption.encrypt_value()
      |> Base.url_encode64(padding: false)

    Routes.url("/notifications/open/" <> handle)
  end

  @doc """
  Reads a handle: `{:ok, %{user_uuid, link, summary?}}` or `:error` for
  anything forged, altered or older than 7 days.
  """
  @spec read_handle(String.t()) :: {:ok, map()} | :error
  def read_handle(handle) when is_binary(handle) and byte_size(handle) <= 4_096 do
    with {:ok, encrypted} <- Base.url_decode64(handle, padding: false),
         true <- Encryption.encrypted?(encrypted),
         {:ok, json} <- Encryption.decrypt_value(encrypted),
         {:ok, %{"u" => user, "x" => expiry} = data} <- Jason.decode(json),
         true <- is_integer(expiry) and expiry > System.system_time(:second),
         {:ok, user} <- Ecto.UUID.cast(user) do
      {:ok, %{user_uuid: user, link: same_site_link(data["l"]), summary?: data["s"] == true}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def read_handle(_), do: :error

  # Only a path on this site, never another origin: an absolute link is cut
  # to its path when it is this site's, refused otherwise.
  @doc false
  def same_site_link(link) when is_binary(link) do
    base = URI.parse(Routes.base_url())

    case URI.parse(link) do
      %URI{scheme: nil, host: nil, path: "/" <> _ = path} = uri ->
        if String.starts_with?(path, "//"), do: nil, else: path_of(uri)

      %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] ->
        if host == base.host, do: path_of(uri), else: nil

      _ ->
        nil
    end
  end

  def same_site_link(_), do: nil

  defp path_of(%URI{path: path, query: nil}), do: path
  defp path_of(%URI{path: path, query: query}), do: path <> "?" <> query
end
