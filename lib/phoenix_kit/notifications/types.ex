defmodule PhoenixKit.Notifications.Types do
  @moduledoc """
  Registry of notification types (and optional sub-types) for the per-user
  preferences UI.

  A **type** is a named group of related activity actions a user can toggle as
  one unit (`"account"`, `"posts"`, `"comments"`, …). Core types ship with
  PhoenixKit; external modules contribute more via the optional
  `notification_types/0` callback on `PhoenixKit.Module`.

  A type may declare **sub-types** for finer control — e.g. `"comments"` with
  `"replies"` and `"reactions"`. Sub-type preference keys are the base key and
  the sub key joined by a dot (`"comments.replies"`), mirroring the permission
  system's dotted sub-keys.

  ## Master-switch semantics (NOT the permission cascade)

  The base type is a **master switch evaluated at resolution time only**:

    * base OFF ⇒ every sub-type under it is muted, regardless of the sub's own value;
    * base ON  ⇒ each sub-type follows its own toggle (defaulting to the sub's `default`).

  This is deliberately the OPPOSITE of `PhoenixKit.Users.Permissions`, where a
  sub *implies* its base and grants cascade/normalize the stored set. Here nothing
  cascades and nothing is normalized in storage — a user's per-sub choices are
  preserved when the master is toggled off, so flipping it back on restores them.
  See `PhoenixKit.Notifications.Prefs` for the resolution.

  ## Shape

      %{
        key: "comments",
        label: "Comments",
        description: "Replies and reactions to your comments",
        actions: [],                       # base-owned actions (often [] when fully split)
        default: true,
        sub_types: [
          %{key: "comments.replies",   label: "Replies",   actions: ["comment.replied"], default: true},
          %{key: "comments.reactions", label: "Reactions", actions: ["comment.liked", "comment.disliked"], default: true}
        ]
      }

  Module authors declare sub keys **bare** (`"replies"`); `normalize/1` composes
  them to `"<type>.<sub>"`. Declared keys must not contain `.` and nesting is one
  level only — offending entries are dropped with a warning. Unknown top-level
  map fields are preserved (a seam for future per-channel / digest metadata).
  Labels and descriptions are shown through `translate/2`, at render, in the
  reader's locale: core's own through `PhoenixKitWeb.Gettext` (registered
  here with `gettext_noop/1`), a module's through the backend it names as
  `gettext_backend:` on its type — its sub-types inherit it. A module that
  names none is shown as declared.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.ModuleRegistry

  @type sub_type :: %{
          key: String.t(),
          label: String.t(),
          description: String.t(),
          actions: [String.t()],
          default: boolean()
        }

  @type t :: %{
          key: String.t(),
          label: String.t(),
          description: String.t(),
          actions: [String.t()],
          default: boolean(),
          sub_types: [sub_type()]
        }

  @doc "Full list of types — core plus module-contributed, normalized, stable order."
  @spec list() :: [t()]
  def list do
    core = normalize_all(core_types())
    core_keys = MapSet.new(core, & &1.key)

    extras =
      external_types()
      |> Enum.reject(&MapSet.member?(core_keys, &1.key))
      |> Enum.sort_by(& &1.label)

    core ++ extras
  end

  @doc "Look up a base type by its key. Returns `nil` when not registered (base keys only)."
  @spec find(String.t()) :: t() | nil
  def find(key) when is_binary(key) do
    Enum.find(list(), &(&1.key == key))
  end

  @doc """
  Resolves an action to the **most-specific** preference key that owns it — a
  sub-type's dotted key when a sub-type claims it, otherwise the base type key,
  otherwise `nil`.

  Backed by a deterministic action→key index (`action_index/0`): sub-types are
  indexed before their base (so a sub wins over its base), and the FIRST claim of
  an action wins globally (a later duplicate claim is ignored with a warning).
  `nil` for unclaimed actions preserves the caller's fail-open behaviour.
  """
  @spec key_for_action(String.t()) :: String.t() | nil
  def key_for_action(action) when is_binary(action), do: Map.get(action_index(), action)
  def key_for_action(_), do: nil

  @doc """
  Resolves an action to the key of its owning **base** type (back-compat).

  Used by `Prefs.user_wants_type?/2`. Returns the base key even when a sub-type
  owns the action.
  """
  @spec type_for_action(String.t()) :: String.t() | nil
  def type_for_action(action) when is_binary(action) do
    case key_for_action(action) do
      nil -> nil
      key -> parent_type_key(key) || key
    end
  end

  def type_for_action(_), do: nil

  @doc """
  Every valid preference key — each base key followed by its sub keys, de-duped,
  stable order. Used to sanitize saves and to build the pause-all set.
  """
  @spec all_pref_keys() :: [String.t()]
  def all_pref_keys do
    list()
    |> Enum.flat_map(fn t -> [t.key | Enum.map(t.sub_types, & &1.key)] end)
    |> Enum.uniq()
  end

  @doc "The base type keys only (no sub keys) — the master switches."
  @spec base_keys() :: [String.t()]
  def base_keys, do: Enum.map(list(), & &1.key)

  @doc """
  Base type key for a dotted sub key (`"comments.replies"` → `"comments"`).

  Returns `nil` for a base key or an unkeyed value. Safe because declared keys
  are `.`-free and nesting is one level (enforced in `normalize/1`).
  """
  @spec parent_type_key(String.t()) :: String.t() | nil
  def parent_type_key(key) when is_binary(key) do
    case String.split(key, ".", parts: 2) do
      [_base] -> nil
      [base, _sub] -> base
    end
  end

  def parent_type_key(_), do: nil

  @doc """
  Default-enabled flag for a base OR dotted key.

  TOTAL by contract: an unknown key returns `true` (the fail-open backstop —
  a `false`/`nil` here would let `master AND sub` go silently falsy).
  """
  @spec default_for(String.t()) :: boolean()
  def default_for(key) when is_binary(key) do
    case find_key_meta(key) do
      %{default: default} -> !!default
      _ -> true
    end
  end

  def default_for(_), do: true

  @doc """
  A type's or sub-type's `:label` or `:description` in the current Gettext
  locale — through the backend the type names (`gettext_backend:`), else
  core's. Text the backend has no translation for comes back as declared.
  """
  @spec translate(map(), :label | :description) :: String.t()
  def translate(type, field) when field in [:label, :description] do
    case Map.get(type, field) do
      text when is_binary(text) and text != "" ->
        Gettext.gettext(Map.get(type, :gettext_backend) || PhoenixKitWeb.Gettext, text)

      _ ->
        ""
    end
  rescue
    _ -> Map.get(type, field) || ""
  end

  # ── Core types ───────────────────────────────────────────────────────

  defp core_types do
    [
      %{
        key: "security",
        label: gettext_noop("Security"),
        description:
          gettext_noop(
            "New sign-ins to your account from an unrecognized device, and sessions opened on your account by someone else"
          ),
        actions: [
          "user.new_login_detected",
          "session.account_added",
          "session.impersonated"
        ],
        default: true
      },
      %{
        key: "account",
        label: gettext_noop("Account"),
        description:
          gettext_noop("Password, email, role, timezone and profile changes made to your account"),
        actions: [
          "user.password_changed",
          "user.password_reset",
          "user.email_changed",
          "user.email_confirmed",
          "user.email_unconfirmed",
          "user.status_changed",
          "user.roles_updated",
          "user.profile_updated",
          "user.timezone_mismatch",
          "organization.manager_added",
          "organization.manager_removed",
          "user.avatar_changed",
          "user.note_created",
          "user.note_deleted"
        ],
        default: true
      },
      %{
        key: "posts",
        label: gettext_noop("Posts"),
        description: gettext_noop("Likes, comments, mentions, and shares on your posts"),
        # Fully split — every post.* action is owned by a sub-type below; the
        # base acts purely as the master switch.
        actions: [],
        default: true,
        sub_types: [
          %{
            key: "likes",
            label: gettext_noop("Likes"),
            description: gettext_noop("Likes on your posts"),
            actions: ["post.liked", "post.disliked"],
            default: true
          },
          %{
            key: "comments",
            label: gettext_noop("Comments"),
            description: gettext_noop("Comments on your posts"),
            actions: ["post.commented"],
            default: true
          },
          %{
            key: "mentions",
            label: gettext_noop("Mentions"),
            description: gettext_noop("Mentions of you in posts"),
            actions: ["post.mentioned"],
            default: true
          },
          %{
            key: "shares",
            label: gettext_noop("Shares"),
            description: gettext_noop("Shares of your posts"),
            actions: ["post.shared"],
            default: true
          }
        ]
      },
      %{
        key: "comments",
        label: gettext_noop("Comments"),
        description: gettext_noop("Replies and reactions to your comments"),
        actions: [],
        default: true,
        sub_types: [
          %{
            key: "replies",
            label: gettext_noop("Replies"),
            description: gettext_noop("Replies to your comments"),
            actions: ["comment.replied"],
            default: true
          },
          %{
            key: "reactions",
            label: gettext_noop("Reactions"),
            description: gettext_noop("Likes and reactions to your comments"),
            actions: ["comment.liked", "comment.disliked"],
            default: true
          }
        ]
      }
    ]
  end

  # ── External module contributions ───────────────────────────────────

  defp external_types do
    ModuleRegistry.all_modules()
    |> Enum.flat_map(fn mod ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :notification_types, 0) do
        safe_collect(mod)
      else
        []
      end
    end)
    |> normalize_all()
  end

  defp safe_collect(mod) do
    mod.notification_types()
  rescue
    e ->
      Logger.warning(
        "[Notifications.Types] #{inspect(mod)}.notification_types/0 failed: #{Exception.message(e)}"
      )

      []
  end

  # ── Normalization ────────────────────────────────────────────────────

  defp normalize_all(types) do
    types
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  # Overlay validated fields onto the input map (not a fresh map) so unknown
  # top-level fields (future :channels / :digest / :aggregatable) survive — a seam.
  defp normalize(%{key: k, label: l} = type) when is_binary(k) and is_binary(l) do
    if String.contains?(k, ".") do
      Logger.warning("[Notifications.Types] dropping type with '.' in key: #{inspect(k)}")
      nil
    else
      Map.merge(type, %{
        key: k,
        label: l,
        description: Map.get(type, :description, ""),
        actions: type |> Map.get(:actions, []) |> Enum.filter(&is_binary/1),
        default: Map.get(type, :default, true) == true,
        sub_types:
          type
          |> Map.get(:sub_types, [])
          |> inherit_backend(Map.get(type, :gettext_backend))
          |> normalize_subs(k)
      })
    end
  end

  defp normalize(other) do
    Logger.warning("[Notifications.Types] dropping malformed type: #{inspect(other)}")
    nil
  end

  defp inherit_backend(subs, backend)
       when is_list(subs) and is_atom(backend) and not is_nil(backend),
       do:
         Enum.map(subs, &if(is_map(&1), do: Map.put_new(&1, :gettext_backend, backend), else: &1))

  defp inherit_backend(subs, _backend), do: subs

  defp normalize_subs(subs, base_key) when is_list(subs) do
    subs
    |> Enum.map(&normalize_sub(&1, base_key))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.key)
  end

  defp normalize_subs(_subs, _base_key), do: []

  defp normalize_sub(%{key: k, label: l} = sub, base_key) when is_binary(k) and is_binary(l) do
    if String.contains?(k, ".") do
      Logger.warning(
        "[Notifications.Types] dropping sub-type with '.' in key #{inspect(k)} under #{inspect(base_key)}"
      )

      nil
    else
      Map.merge(sub, %{
        key: "#{base_key}.#{k}",
        label: l,
        description: Map.get(sub, :description, ""),
        actions: sub |> Map.get(:actions, []) |> Enum.filter(&is_binary/1),
        default: Map.get(sub, :default, true) == true
      })
    end
  end

  defp normalize_sub(other, base_key) do
    Logger.warning(
      "[Notifications.Types] dropping malformed sub-type under #{inspect(base_key)}: #{inspect(other)}"
    )

    nil
  end

  # ── Resolution internals ─────────────────────────────────────────────

  # action → most-specific key. Sub-types indexed before their base so a sub
  # wins; first claim of an action wins globally (later duplicate → warn + keep).
  defp action_index do
    Enum.reduce(list(), %{}, fn type, acc ->
      acc = Enum.reduce(type.sub_types, acc, &index_action_owner(&2, &1.actions, &1.key))
      index_action_owner(acc, type.actions, type.key)
    end)
  end

  defp index_action_owner(acc, actions, key) do
    Enum.reduce(actions, acc, fn action, acc ->
      case Map.get(acc, action) do
        nil ->
          Map.put(acc, action, key)

        ^key ->
          acc

        existing ->
          Logger.warning(
            "[Notifications.Types] action #{inspect(action)} claimed by both " <>
              "#{inspect(existing)} and #{inspect(key)}; keeping #{inspect(existing)}"
          )

          acc
      end
    end)
  end

  # The type OR sub-type metadata map for a key (base or dotted); nil if unknown.
  defp find_key_meta(key) do
    Enum.find_value(list(), fn type ->
      if type.key == key, do: type, else: Enum.find(type.sub_types, &(&1.key == key))
    end)
  end
end
