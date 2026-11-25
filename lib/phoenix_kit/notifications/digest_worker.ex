defmodule PhoenixKit.Notifications.DigestWorker do
  @moduledoc """
  Aggregation engine: sends batched notification **summaries** for types a user
  put on a digest cadence (hourly / 12h / daily / weekly) instead of getting
  pinged for each event.

  One cron entry per cadence enqueues this worker with `%{"cadence" => "hourly"}`
  etc. The window is simply the cadence period (the hourly cron counts the last
  hour, daily the last day, …) — so there's **no per-user last-sent state** to
  track. For each user who routes a type to a channel on this cadence, it counts
  that type's events in the window from the activity log and, if any, delivers a
  single summary ("You have 1,432 new likes in the last hour.") via the channel.

  Only activity-driven types aggregate — standalone notifications are always
  immediate. Immediate cadences never reach here (they enqueue `DeliveryWorker`
  at creation time).
  """

  use Oban.Worker, queue: :notifications, max_attempts: 3
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  require Logger

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Notifications
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Channels
  alias PhoenixKit.Notifications.Prefs
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @windows %{"hourly" => 3600, "12h" => 43_200, "daily" => 86_400, "weekly" => 604_800}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"cadence" => cadence}}) when is_map_key(@windows, cadence) do
    # Honor the global kill switch — same gate immediate notifications pass.
    if Notifications.enabled?() do
      since = DateTime.add(UtilsDate.utc_now(), -@windows[cadence], :second)

      cadence
      |> users_with_cadence()
      |> Enum.each(&digest_user(&1, cadence, since))
    end

    :ok
  end

  def perform(_job), do: :ok

  # --- Per-user sweep -------------------------------------------------------

  defp digest_user(user, cadence, since) do
    Enum.each(ChannelConfig.all_for(user), fn {channel_key, config} ->
      digest_config(channel_key, config, user, cadence, since)
    end)
  rescue
    e -> Logger.warning("[DigestWorker] user #{user.uuid} failed: #{Exception.message(e)}")
  catch
    # An exit (dead pool, timeout) must not abort the sweep: an Oban retry
    # would re-send every digest already delivered to earlier users.
    :exit, reason -> Logger.warning("[DigestWorker] user #{user.uuid} failed: #{inspect(reason)}")
  end

  # In-app is a delivery mode too: post one aggregated inbox row.
  defp digest_config("inapp", config, user, cadence, since),
    do: digest_inapp(user, config, cadence, since)

  defp digest_config(channel_key, config, user, cadence, since) do
    channel = Channels.get(channel_key)

    if deliverable_channel?(channel, config, user.uuid) do
      for type_key <- cadenced_types(config, cadence) do
        digest_type(user, channel, config, type_key, cadence, since)
      end
    end
  end

  defp deliverable_channel?(nil, _config, _uuid), do: false

  defp deliverable_channel?(channel, config, uuid),
    do: ChannelConfig.enabled?(config) and channel.configured?(uuid, config)

  # In-app digest: for each type the user wants in-app (routing lives in
  # `notification_preferences`) that's on this cadence, post ONE summary inbox
  # row rather than the per-event rows the creation path suppressed.
  defp digest_inapp(user, config, cadence, since) do
    for type_key <- inapp_cadenced_types(user, config, cadence) do
      count = count_events(user.uuid, type_key, since)

      if count > 0 do
        # The inbox row freezes its text at write time, so it needs the
        # recipient's locale exactly as the channel envelope does.
        locale = RecipientLocale.for_rendering(user)

        Notifications.create_inapp(user.uuid, %{
          text: digest_body(locale, type_key, count, cadence),
          icon: "hero-bell",
          link: inbox_path(locale)
        })
      end
    end
  end

  # Types routed to this channel on exactly this cadence.
  defp cadenced_types(config, cadence) do
    config
    |> Map.get("types", %{})
    |> Enum.filter(fn {type_key, on} ->
      on == true and ChannelConfig.cadence(config, type_key) == cadence
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # In-app types on this cadence — routing is checked against the user's in-app
  # prefs (not a `types` map, which the inapp config doesn't carry).
  defp inapp_cadenced_types(user, config, cadence) do
    config
    |> Map.get("cadences", %{})
    |> Enum.filter(fn {type_key, c} ->
      c == cadence and Prefs.user_wants_type?(user, type_key)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp digest_type(user, channel, config, type_key, cadence, since) do
    count = count_events(user.uuid, type_key, since)

    if count > 0 do
      envelope = digest_envelope(user, type_key, count, cadence)

      case RecipientLocale.in_locale(envelope.content_locale, fn ->
             channel.deliver(envelope, config)
           end) do
        :ok -> :ok
        # A failed digest just waits for the next window — no retry state to keep.
        other -> Logger.info("[DigestWorker] #{channel.key()} digest deferred: #{inspect(other)}")
      end
    end
  end

  # --- Data -----------------------------------------------------------------

  # Users who have any channel config key set — filtered in Elixir to those
  # actually using this cadence. (Configs live in the user JSONB; there's no
  # separate table to index.)
  defp users_with_cadence(cadence) do
    # "inapp" is a synthetic mode, not a registered channel, but its cadence
    # lives under the same `notification_channel:` prefix.
    keys = Enum.map(["inapp" | Channels.keys()], &ChannelConfig.config_key/1)

    condition =
      Enum.reduce(keys, dynamic(false), fn key, acc ->
        dynamic([u], ^acc or fragment("? \\? ?", u.custom_fields, ^key))
      end)

    from(u in User, where: ^condition)
    |> repo().all()
    |> Enum.filter(fn user ->
      user
      |> ChannelConfig.all_for()
      |> Enum.any?(fn
        {"inapp", config} -> inapp_cadenced_types(user, config, cadence) != []
        {_ck, config} -> cadenced_types(config, cadence) != []
      end)
    end)
  end

  defp count_events(user_uuid, type_key, since) do
    case actions_for_type(type_key) do
      [] ->
        0

      actions ->
        # Exclude self-actions (actor == target) to match the immediate path,
        # which never notifies a user about their own action.
        from(e in Entry,
          where:
            e.target_uuid == ^user_uuid and e.action in ^actions and e.inserted_at >= ^since and
              (is_nil(e.actor_uuid) or e.actor_uuid != e.target_uuid)
        )
        |> repo().aggregate(:count)
    end
  end

  # The action strings a type (or sub-type) key claims — from the Types registry.
  defp actions_for_type(type_key) do
    Types.list()
    |> Enum.flat_map(fn type ->
      [{type.key, type.actions} | Enum.map(type.sub_types, &{&1.key, &1.actions})]
    end)
    |> Enum.find_value([], fn {key, actions} -> if key == type_key, do: actions end)
  end

  # Public for testing the envelope and its locale contract.
  @doc false
  def digest_envelope(user, type_key, count, cadence) do
    locale = RecipientLocale.for_rendering(user)

    %{
      recipient_uuid: user.uuid,
      type_key: type_key,
      notification_uuid: nil,
      locale: RecipientLocale.base(user),
      content_locale: locale,
      icon: "hero-bell",
      title: nil,
      text: digest_body(locale, type_key, count, cadence),
      url: Routes.base_url() <> inbox_path(locale)
    }
  end

  # The inbox in the recipient's language: `Routes.path/1` takes the locale
  # from the process, which in this worker is the default one — the text was
  # Estonian and the button opened the English inbox (zai, 2026-11-25).
  # The recipient's full dialect when the site serves it (`en-GB` beside
  # `en-US`): the implicit lookup inside `in_locale/2` reduced it to the base
  # language, which opened the default dialect's inbox.
  defp inbox_path(locale) do
    if is_binary(locale) and dialect_served?(locale),
      do: Routes.path("/admin/notifications", locale: locale),
      else: RecipientLocale.in_locale(locale, fn -> Routes.path("/admin/notifications") end)
  end

  defp dialect_served?(locale) do
    Languages.language_enabled?(locale)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # An Oban worker process starts on the default locale, so the digest strings
  # would render in it no matter who the recipient is — the catalogues carry
  # translations for them (ru, et) that nobody would ever see. Both digest
  # surfaces (the channel envelope and the in-app inbox row) freeze their text
  # at write time, so both build it here, inside the recipient's locale.
  # (`%{label}` goes through `Types.translate/2`, so it is in the recipient's
  # locale too.)
  defp digest_body(locale, type_key, count, cadence) do
    RecipientLocale.in_locale(locale, fn ->
      digest_text(count, type_label(type_key), cadence)
    end)
  end

  defp digest_text(count, label, cadence) do
    gettext("You have %{count} new %{label} %{period}.",
      count: count,
      label: label,
      period: period_phrase(cadence)
    )
  end

  defp period_phrase("hourly"),
    do: gettext("in the last hour")

  defp period_phrase("12h"),
    do: gettext("in the last 12 hours")

  defp period_phrase("daily"),
    do: gettext("in the last day")

  defp period_phrase("weekly"),
    do: gettext("in the last week")

  defp period_phrase(_), do: ""

  defp type_label(type_key) do
    Types.list()
    |> Enum.flat_map(fn type ->
      [
        {type.key, Types.translate(type, :label)}
        | Enum.map(type.sub_types, &{&1.key, Types.translate(&1, :label)})
      ]
    end)
    |> Enum.find_value(type_key, fn {key, label} ->
      if key == type_key, do: String.downcase(label)
    end)
  end

  defp repo, do: RepoHelper.repo()
end
