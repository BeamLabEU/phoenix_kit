defmodule PhoenixKit.Notifications.Messages do
  @moduledoc """
  The wording of notification messages an operator changed in Settings →
  Notifications → Messages (item 20 of the boss's fourth Projects list,
  decided with Max on 2026-11-20).

  ## What can be changed

  Per notification type and channel, in one language at a time:

    * **email**: the `subject` (one line) and the body, as `markdown`;
    * **telegram**: the `text` (plain).

  The layout and branding (Settings → branding), the email's button and the
  Telegram button stay the renderer's: an edit can never remove the way to
  the record or to the reader's settings.

  The type is a notification type's key (`"projects"`, a sub-type's
  `"projects.ready"`), or `"*"` for every notification.

  ## How a message is chosen

  Part by part, the first that has the part:

    1. the type's own wording, in the reader's language;
    2. the same, in its base language (an `en` edit covers `en-GB`);
    3. the `"*"` wording, in the reader's language, then its base language;
    4. what there was before: a host's file, then the translated default.

  A language nobody edited keeps its translated default: an English edit
  never un-translates a Russian reader (Max, 2026-11-20).

  ## Variables

  `{{name}}` only — two braces, the value escaped where the channel needs it
  (the email's HTML), substituted after the Markdown is rendered, in one
  pass, so a comment holding `{{subject}}` or Markdown is shown as written.
  Three braces (raw HTML) are refused: operators write no HTML. A variable
  the channel does not have is refused on save (`variables/1`).

  ## Storage

  One settings entry per `(type, channel, language)`, key
  `"notification_message:<type>:<channel>:<language>"`, value
  `%{"subject", "markdown" | "text", "version", "default_hash",
  "updated_by"}`. A save goes through the settings history (who, before,
  after); a reset is logged in the activity feed. `version` refuses a save
  made from an older copy ("someone else saved this meanwhile").
  `default_hash` is the default the wording was written against, so the
  editor can say when the default changed since.

  ## Who

  The `settings.messages` permission (`may_edit?/1`); the Owner always.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.RecipientLocale

  @prefix "notification_message:"
  @all "*"

  @parts %{"email" => ~w(subject markdown), "telegram" => ~w(text)}

  @limits %{"subject" => 200, "markdown" => 10_000, "text" => 3_500}

  @variables %{
    "email" =>
      ~w(subject text quote url action_label reason settings_url settings_label logo_url accent_color),
    "telegram" => ~w(title text quote url reason settings_url)
  }

  @doc "The channels whose wording can be changed."
  @spec channels() :: [String.t()]
  def channels, do: Map.keys(@parts) |> Enum.sort()

  @doc "The parts of a channel's message an operator writes."
  @spec parts(String.t()) :: [String.t()]
  def parts(channel), do: Map.get(@parts, channel, [])

  @doc "The variables a channel's message offers, in the order the editor lists them."
  @spec variables(String.t()) :: [String.t()]
  def variables(channel), do: Map.get(@variables, channel, [])

  @doc "The key standing for every notification type."
  def all_types, do: @all

  @doc """
  The Telegram message as it is sent without an edit, as a template: what the
  editor starts from.
  """
  @spec telegram_default() :: String.t()
  def telegram_default, do: "{{title}}\n\n{{text}}\n\n{{quote}}\n\n{{reason}}\n{{settings_url}}"

  @doc """
  The default parts of a channel's message in `locale`, as the editor shows
  them and as `default_hash/2` hashes them.
  """
  @spec default_parts(String.t(), String.t() | nil) :: map()
  def default_parts("email", locale) do
    defaults = RecipientLocale.in_locale(locale, fn -> CoreTemplates.notification_defaults() end)
    %{"subject" => defaults.subject, "markdown" => defaults.markdown}
  end

  def default_parts("telegram", _locale), do: %{"text" => telegram_default()}
  def default_parts(_channel, _locale), do: %{}

  @doc "A hash of the default a wording is written against."
  @spec default_hash(String.t(), String.t() | nil) :: String.t()
  def default_hash(channel, locale) do
    channel
    |> default_parts(locale)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ── Reading ───────────────────────────────────────────────────────────

  @doc """
  The saved parts that apply to a message of `type_key` on `channel` for a
  reader in `locale`, part by part (see "How a message is chosen"). `%{}`
  when nothing was changed. Never raises: a read that fails is no edit.
  """
  @spec for_message(String.t() | nil, String.t(), String.t() | nil) :: map()
  def for_message(type_key, channel, locale) do
    candidates =
      for type <- type_chain(type_key), loc <- locale_chain(locale), uniq: true, do: {type, loc}

    Enum.reduce(parts(channel), %{}, fn part, acc ->
      case Enum.find_value(candidates, fn {type, loc} -> part_of(type, channel, loc, part) end) do
        nil -> acc
        value -> Map.put(acc, part, value)
      end
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp part_of(type, channel, locale, part) do
    case Settings.get_json_setting_cached(key(type, channel, locale), nil) do
      %{} = entry ->
        case entry[part] do
          value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # A sub-type's own wording, its base type's, then everyone's.
  defp type_chain(type_key) when is_binary(type_key) and type_key != "" do
    [type_key, Types.parent_type_key(type_key), @all] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp type_chain(_type_key), do: [@all]

  defp locale_chain(locale) when is_binary(locale) and locale != "" do
    base = locale |> String.split(["-", "_"], parts: 2) |> hd()
    Enum.uniq([locale, base])
  end

  defp locale_chain(_locale), do: []

  @doc "The one saved entry for exactly this type, channel and language, or nil."
  @spec entry(String.t(), String.t(), String.t()) :: map() | nil
  def entry(type_key, channel, locale) do
    case Settings.get_json_setting(key(type_key, channel, locale)) do
      %{} = entry -> entry
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Which languages of a type and channel have saved wording: the editor's
  "edited: en; default: ru, et".
  """
  @spec edited_locales(String.t(), String.t()) :: [String.t()]
  def edited_locales(type_key, channel) do
    prefix = "#{@prefix}#{type_key}:#{channel}:"

    prefix
    |> Settings.get_json_settings_by_prefix()
    |> Enum.map(fn {key, _value} -> String.replace_prefix(key, prefix, "") end)
    |> Enum.sort()
  rescue
    _ -> []
  end

  # ── Writing ───────────────────────────────────────────────────────────

  @doc """
  Saves the wording of a type's message on a channel in one language.

  `parts` holds the channel's parts (`parts/1`); a blank one falls back
  again. Options: `:actor_uuid` (recorded in the settings history),
  `:version` (the copy the editor started from; a newer saved one refuses
  the save with `{:error, :stale}`).

  Errors: `:not_allowed`, `:unknown_type`, `:unknown_channel`,
  `:bad_locale`, `:stale`, `{:too_long, part}`, `{:unknown_variables,
  [name]}`, `:raw_html`, `:empty`.
  """
  @spec save(Scope.t() | nil, String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def save(scope, type_key, channel, locale, parts, opts \\ []) when is_map(parts) do
    with :ok <- allowed(scope),
         :ok <- known_type(type_key),
         :ok <- known_channel(channel),
         :ok <- good_locale(locale),
         {:ok, clean} <- clean_parts(channel, parts),
         :ok <- fresh(type_key, channel, locale, opts[:version]) do
      previous = entry(type_key, channel, locale)
      actor = Keyword.get(opts, :actor_uuid) || scope_user_uuid(scope)

      value =
        Map.merge(clean, %{
          "version" => ((previous && previous["version"]) || 0) + 1,
          "default_hash" => default_hash(channel, locale),
          "updated_by" => actor
        })

      case Settings.update_json_setting_with_module(
             key(type_key, channel, locale),
             value,
             "notifications",
             actor_uuid: actor,
             source: "settings"
           ) do
        {:ok, _setting} ->
          log("notifications.message_saved", actor, type_key, channel, locale)
          {:ok, value}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Removes the saved wording: the message falls back again. Same rights as `save/6`."
  @spec reset(Scope.t() | nil, String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def reset(scope, type_key, channel, locale) do
    with :ok <- allowed(scope),
         :ok <- known_type(type_key),
         :ok <- known_channel(channel),
         :ok <- good_locale(locale) do
      case Settings.delete_setting(key(type_key, channel, locale)) do
        {:ok, _} ->
          log("notifications.message_reset", scope_user_uuid(scope), type_key, channel, locale)
          :ok

        {:error, :not_found} ->
          :ok

        other ->
          other
      end
    end
  end

  @doc "Whether the scope may change notification wording: `settings.messages`, or the Owner."
  @spec may_edit?(Scope.t() | nil) :: boolean()
  def may_edit?(%Scope{} = scope),
    do: Scope.owner?(scope) or Scope.can?(scope, "settings.messages")

  def may_edit?(_scope), do: false

  defp allowed(scope), do: if(may_edit?(scope), do: :ok, else: {:error, :not_allowed})

  defp known_type(@all), do: :ok

  defp known_type(type_key) when is_binary(type_key) do
    if type_key in Types.all_pref_keys(), do: :ok, else: {:error, :unknown_type}
  end

  defp known_type(_), do: {:error, :unknown_type}

  defp known_channel(channel),
    do: if(Map.has_key?(@parts, channel), do: :ok, else: {:error, :unknown_channel})

  defp good_locale(locale) when is_binary(locale) do
    if Regex.match?(~r/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})?\z/, locale),
      do: :ok,
      else: {:error, :bad_locale}
  end

  defp good_locale(_), do: {:error, :bad_locale}

  defp fresh(_type_key, _channel, _locale, nil), do: :ok

  defp fresh(type_key, channel, locale, version) do
    current = (entry(type_key, channel, locale) || %{})["version"] || 0
    if to_int(version) == current, do: :ok, else: {:error, :stale}
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> -1
    end
  end

  defp to_int(_), do: -1

  defp clean_parts(channel, parts) do
    cleaned =
      for part <- parts(channel), into: %{} do
        value = parts[part] || parts[String.to_existing_atom(part)]
        {part, clean_value(part, value)}
      end

    cond do
      Enum.all?(cleaned, fn {_k, v} -> v == "" end) ->
        {:error, :empty}

      (too_long = Enum.find(cleaned, &too_long?/1)) != nil ->
        {:error, {:too_long, elem(too_long, 0)}}

      Enum.any?(cleaned, fn {_k, v} -> String.contains?(v, "{{{") end) ->
        {:error, :raw_html}

      (unknown = unknown_variables(channel, cleaned)) != [] ->
        {:error, {:unknown_variables, unknown}}

      true ->
        {:ok, cleaned}
    end
  end

  defp clean_value("subject", value) when is_binary(value),
    do: value |> String.replace(~r/\s*[\r\n]+\s*/u, " ") |> String.trim()

  defp clean_value(_part, value) when is_binary(value),
    do: value |> String.replace("\r\n", "\n") |> String.trim()

  defp clean_value(_part, _value), do: ""

  defp too_long?({part, value}), do: String.length(value) > Map.fetch!(@limits, part)

  @doc "The `{{names}}` a text uses that the channel does not offer."
  @spec unknown_variables(String.t(), map() | String.t()) :: [String.t()]
  def unknown_variables(channel, text) when is_binary(text),
    do: unknown_variables(channel, %{"x" => text})

  def unknown_variables(channel, parts) when is_map(parts) do
    known = variables(channel)

    parts
    |> Map.values()
    |> Enum.flat_map(&Regex.scan(~r/\{\{\s*([^{}\s]+)\s*\}\}/, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in known))
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp key(type_key, channel, locale), do: "#{@prefix}#{type_key}:#{channel}:#{locale}"

  defp scope_user_uuid(%Scope{} = scope), do: Scope.user_uuid(scope)
  defp scope_user_uuid(_), do: nil

  defp log(action, actor, type_key, channel, locale) do
    PhoenixKit.Activity.log(%{
      action: action,
      module: "notifications",
      mode: "manual",
      actor_uuid: actor,
      resource_type: "notification_message",
      metadata: %{"type" => type_key, "channel" => channel, "locale" => locale}
    })
  rescue
    _ -> :ok
  end
end
