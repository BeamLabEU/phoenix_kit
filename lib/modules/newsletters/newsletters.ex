defmodule PhoenixKit.Modules.Newsletters do
  @moduledoc """
  Newsletters module — email broadcasts and subscription management.

  Provides newsletter list management, broadcast creation with Markdown editor,
  per-recipient delivery tracking via Oban workers, and unsubscribe flow.
  """

  use PhoenixKit.Module

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "newsletters"

  @impl PhoenixKit.Module
  def module_name, do: "Newsletters"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("newsletters_enabled", false)
  end

  @impl PhoenixKit.Module
  def enable_system do
    # Require emails module to be enabled
    if Emails.enabled?() do
      Settings.update_boolean_setting_with_module("newsletters_enabled", true, "newsletters")
    else
      {:error, :emails_required}
    end
  end

  @impl PhoenixKit.Module
  def disable_system do
    Settings.update_boolean_setting_with_module("newsletters_enabled", false, "newsletters")
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "newsletters",
      label: "Newsletters",
      icon: "hero-megaphone",
      description: "Email broadcasts and subscription management"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_newsletters,
        label: "Newsletters",
        icon: "hero-megaphone",
        path: "newsletters/broadcasts",
        priority: 520,
        level: :admin,
        permission: "newsletters",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        subtab_indent: "pl-4"
      ),
      Tab.new!(
        id: :admin_newsletters_broadcasts,
        label: "Broadcasts",
        icon: "hero-paper-airplane",
        path: "newsletters/broadcasts",
        priority: 521,
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        match: :prefix
      ),
      Tab.new!(
        id: :admin_newsletters_lists,
        label: "Lists",
        icon: "hero-list-bullet",
        path: "newsletters/lists",
        priority: 522,
        level: :admin,
        permission: "newsletters",
        parent: :admin_newsletters,
        match: :prefix
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitWeb.Routes.NewslettersRoutes

  # ============================================================================
  # Lists
  # ============================================================================

  alias PhoenixKit.Modules.Newsletters.{Broadcast, Broadcaster, Delivery, List, ListMember}

  import Ecto.Query

  def list_lists(filters \\ %{}) do
    List
    |> maybe_filter_status(filters)
    |> order_by([l], asc: l.name)
    |> repo().all()
  end

  def get_list!(uuid), do: repo().get!(List, uuid)

  def get_list(uuid), do: repo().get(List, uuid)

  def create_list(attrs) do
    %List{}
    |> List.changeset(attrs)
    |> repo().insert()
  end

  def update_list(%List{} = list, attrs) do
    list
    |> List.changeset(attrs)
    |> repo().update()
  end

  def delete_list(%List{} = list), do: repo().delete(list)

  # ============================================================================
  # List Members
  # ============================================================================

  def list_members(list_uuid, filters \\ %{}) do
    ListMember
    |> where([m], m.list_uuid == ^list_uuid)
    |> maybe_filter_member_status(filters)
    |> preload(:user)
    |> order_by([m], desc: m.subscribed_at)
    |> apply_pagination(filters)
    |> repo().all()
  end

  def count_active_members(list_uuid) do
    ListMember
    |> where([m], m.list_uuid == ^list_uuid and m.status == "active")
    |> repo().aggregate(:count)
  end

  def subscribe_user(list_uuid, user_uuid) do
    %ListMember{}
    |> ListMember.changeset(%{list_uuid: list_uuid, user_uuid: user_uuid, status: "active"})
    |> repo().insert(
      on_conflict: {:replace, [:status, :subscribed_at]},
      conflict_target: [:user_uuid, :list_uuid]
    )
    |> case do
      {:ok, member} ->
        update_subscriber_count(list_uuid)
        {:ok, member}

      error ->
        error
    end
  end

  def unsubscribe_user(list_uuid, user_uuid) do
    ListMember
    |> where([m], m.list_uuid == ^list_uuid and m.user_uuid == ^user_uuid)
    |> repo().one()
    |> case do
      nil ->
        {:error, :not_found}

      member ->
        member
        |> ListMember.changeset(%{
          status: "unsubscribed",
          unsubscribed_at: PhoenixKit.Utils.Date.utc_now()
        })
        |> repo().update()
        |> case do
          {:ok, member} ->
            update_subscriber_count(list_uuid)
            {:ok, member}

          error ->
            error
        end
    end
  end

  def list_user_subscriptions(user_uuid) do
    ListMember
    |> where([m], m.user_uuid == ^user_uuid and m.status == "active")
    |> preload(:list)
    |> repo().all()
  end

  def unsubscribe_from_all(user_uuid) do
    ListMember
    |> where([m], m.user_uuid == ^user_uuid and m.status == "active")
    |> repo().update_all(set: [status: "unsubscribed", unsubscribed_at: DateTime.utc_now()])
  end

  # ============================================================================
  # Broadcasts
  # ============================================================================

  def list_broadcasts(filters \\ %{}) do
    Broadcast
    |> maybe_filter_broadcast_status(filters)
    |> preload([:list])
    |> order_by([b], desc: b.inserted_at)
    |> apply_pagination(filters)
    |> repo().all()
  end

  def get_broadcast!(uuid) do
    Broadcast
    |> preload([:list, :template])
    |> repo().get!(uuid)
  end

  def create_broadcast(attrs) do
    %Broadcast{}
    |> Broadcast.changeset(attrs)
    |> repo().insert()
  end

  def update_broadcast(%Broadcast{} = broadcast, attrs) do
    broadcast
    |> Broadcast.changeset(attrs)
    |> repo().update()
  end

  def delete_broadcast(%Broadcast{status: "draft"} = broadcast), do: repo().delete(broadcast)
  def delete_broadcast(_), do: {:error, :cannot_delete_non_draft}

  def render_broadcast_html(%Broadcast{} = broadcast) do
    case Earmark.as_html(broadcast.markdown_body || "") do
      {:ok, html, _} -> {:ok, html}
      {:error, _, errors} -> {:error, errors}
    end
  end

  # ============================================================================
  # Deliveries
  # ============================================================================

  def list_deliveries(broadcast_uuid, filters \\ %{}) do
    Delivery
    |> where([d], d.broadcast_uuid == ^broadcast_uuid)
    |> maybe_filter_delivery_status(filters)
    |> preload(:user)
    |> order_by([d], desc: d.inserted_at)
    |> apply_pagination(filters)
    |> repo().all()
  end

  def get_delivery_stats(broadcast_uuid) do
    Delivery
    |> where([d], d.broadcast_uuid == ^broadcast_uuid)
    |> group_by([d], d.status)
    |> select([d], {d.status, count(d.uuid)})
    |> repo().all()
    |> Map.new()
  end

  def update_delivery_status(%Delivery{} = delivery, status, attrs \\ %{}) do
    delivery
    |> Delivery.changeset(Map.merge(attrs, %{status: status}))
    |> repo().update()
  end

  def find_delivery_by_message_id(message_id) do
    Delivery
    |> where([d], d.message_id == ^message_id)
    |> preload(:broadcast)
    |> repo().one()
  end

  # ============================================================================
  # Scheduled Processing
  # ============================================================================

  def process_scheduled_broadcasts do
    now = PhoenixKit.Utils.Date.utc_now()

    broadcasts =
      Broadcast
      |> where([b], b.status == "scheduled" and b.scheduled_at <= ^now)
      |> order_by([b], asc: b.scheduled_at)
      |> repo().all()

    count =
      Enum.reduce(broadcasts, 0, fn broadcast, acc ->
        case Broadcaster.send(broadcast) do
          {:ok, _} ->
            acc + 1

          {:error, reason} ->
            Logger.warning(
              "Failed to send scheduled broadcast #{broadcast.uuid}: #{inspect(reason)}"
            )

            acc
        end
      end)

    {:ok, count}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp update_subscriber_count(list_uuid) do
    count = count_active_members(list_uuid)

    List
    |> where([l], l.uuid == ^list_uuid)
    |> repo().update_all(set: [subscriber_count: count])
  end

  defp maybe_filter_status(query, %{status: status}) when is_binary(status) and status != "" do
    where(query, [l], l.status == ^status)
  end

  defp maybe_filter_status(query, _), do: query

  defp maybe_filter_member_status(query, %{status: status})
       when is_binary(status) and status != "" do
    where(query, [m], m.status == ^status)
  end

  defp maybe_filter_member_status(query, _), do: query

  defp maybe_filter_broadcast_status(query, %{status: status})
       when is_binary(status) and status != "" do
    where(query, [b], b.status == ^status)
  end

  defp maybe_filter_broadcast_status(query, _), do: query

  defp maybe_filter_delivery_status(query, %{status: status})
       when is_binary(status) and status != "" do
    where(query, [d], d.status == ^status)
  end

  defp maybe_filter_delivery_status(query, _), do: query

  defp apply_pagination(query, filters) do
    limit = Map.get(filters, :limit, 50)
    offset = Map.get(filters, :offset, 0)
    query |> limit(^limit) |> offset(^offset)
  end
end
