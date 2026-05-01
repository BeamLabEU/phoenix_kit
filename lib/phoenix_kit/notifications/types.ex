defmodule PhoenixKit.Notifications.Types do
  @moduledoc """
  Registry of notification types for the per-user preferences UI.

  A type is a named group of related activity actions that a user can toggle
  as one unit. Core types (`"account"`, `"posts"`, `"comments"`) ship with
  PhoenixKit; external modules contribute additional types via the optional
  `notification_types/0` callback on `PhoenixKit.Module` (same pattern the
  integrations system uses for `integration_providers/0`).

  Shape of a type:

      %{
        key: "posts",
        label: "Posts",
        description: "Likes, comments, mentions on your posts",
        actions: ["post.liked", "post.commented", "post.mentioned"],
        default: true
      }

  The `maybe_create_from_activity/1` pipeline resolves the activity's action
  back to a type via `type_for_action/1` and asks `Prefs.user_wants?/2`
  whether the recipient has that type enabled.

  Actions not matched by any registered type are treated as fail-open — the
  notification still fires. New action types can ship without a UI update
  while remaining visible to users.
  """

  require Logger

  alias PhoenixKit.ModuleRegistry

  @type t :: %{
          key: String.t(),
          label: String.t(),
          description: String.t(),
          actions: [String.t()],
          default: boolean()
        }

  @doc "Full list of types — core plus module-contributed, stable order."
  @spec list() :: [t()]
  def list do
    core = core_types()
    core_keys = MapSet.new(core, & &1.key)

    extras =
      external_types()
      |> Enum.reject(&MapSet.member?(core_keys, &1.key))
      |> Enum.sort_by(& &1.label)

    core ++ extras
  end

  @doc "Look up a type by its key. Returns `nil` when not registered."
  @spec find(String.t()) :: t() | nil
  def find(key) when is_binary(key) do
    Enum.find(list(), &(&1.key == key))
  end

  @doc """
  Resolves an action string to the key of its owning type.

  Returns `nil` when no type claims the action — the caller treats that as
  fail-open and still delivers the notification.
  """
  @spec type_for_action(String.t()) :: String.t() | nil
  def type_for_action(action) when is_binary(action) do
    Enum.find_value(list(), fn t -> if action in t.actions, do: t.key end)
  end

  @doc "Returns the default-enabled flag for a type key. Missing types default to `true`."
  @spec default_for(String.t()) :: boolean()
  def default_for(key) when is_binary(key) do
    case find(key) do
      nil -> true
      %{default: default} -> !!default
    end
  end

  # ── Core types ───────────────────────────────────────────────────────

  defp core_types do
    [
      %{
        key: "account",
        label: "Account",
        description: "Password, email, role and profile changes made to your account",
        actions: [
          "user.password_changed",
          "user.password_reset",
          "user.email_changed",
          "user.email_confirmed",
          "user.email_unconfirmed",
          "user.status_changed",
          "user.roles_updated",
          "user.profile_updated",
          "user.avatar_changed",
          "user.note_created",
          "user.note_deleted"
        ],
        default: true
      },
      %{
        key: "posts",
        label: "Posts",
        description: "Likes, comments, and mentions on your posts",
        actions: [
          "post.liked",
          "post.disliked",
          "post.commented",
          "post.mentioned",
          "post.shared"
        ],
        default: true
      },
      %{
        key: "comments",
        label: "Comments",
        description: "Replies and reactions to your comments",
        actions: [
          "comment.liked",
          "comment.disliked",
          "comment.replied"
        ],
        default: true
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
    |> Enum.map(&normalize/1)
    |> Enum.reject(&is_nil/1)
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

  defp normalize(%{key: k, label: l, actions: a} = type)
       when is_binary(k) and is_binary(l) and is_list(a) do
    %{
      key: k,
      label: l,
      description: Map.get(type, :description, ""),
      actions: Enum.filter(a, &is_binary/1),
      default: Map.get(type, :default, true) == true
    }
  end

  defp normalize(other) do
    Logger.warning("[Notifications.Types] dropping malformed type: #{inspect(other)}")
    nil
  end
end
