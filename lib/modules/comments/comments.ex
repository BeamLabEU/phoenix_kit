defmodule PhoenixKit.Modules.Comments do
  @moduledoc """
  Standalone, resource-agnostic comments module.

  Provides polymorphic commenting for any resource type (posts, entities, tickets, etc.)
  with unlimited threading, likes/dislikes, and moderation support.

  ## Architecture

  Comments are linked to resources via `resource_type` (string) + `resource_id` (UUID).
  No foreign key constraints on the resource side — any module can use comments.

  ## Resource Handler Callbacks

  Modules that consume comments can register handlers to receive notifications
  when comments are created or deleted. Configure in your app:

      config :phoenix_kit, :comment_resource_handlers, %{
        "post" => PhoenixKit.Modules.Posts
      }

  Handler modules should implement `on_comment_created/3` and `on_comment_deleted/3`.

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if Comments module is enabled
  - `enable_system/0` - Enable the Comments module
  - `disable_system/0` - Disable the Comments module
  - `get_config/0` - Get module configuration with statistics

  ### Comment CRUD
  - `create_comment/4` - Create a comment on a resource
  - `update_comment/2` - Update a comment
  - `delete_comment/1` - Delete a comment
  - `get_comment/2`, `get_comment!/2` - Get by ID
  - `list_comments/3` - Flat list for a resource
  - `get_comment_tree/2` - Nested tree for a resource
  - `count_comments/3` - Count comments for a resource

  ### Moderation
  - `approve_comment/1` - Set status to published
  - `hide_comment/1` - Set status to hidden
  - `bulk_update_status/2` - Bulk status changes
  - `list_all_comments/1` - Cross-resource listing with filters
  - `comment_stats/0` - Aggregate statistics

  ### Like/Dislike
  - `like_comment/2`, `unlike_comment/2`, `comment_liked_by?/2`
  - `dislike_comment/2`, `undislike_comment/2`, `comment_disliked_by?/2`
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Modules.Comments.Comment
  alias PhoenixKit.Modules.Comments.CommentDislike
  alias PhoenixKit.Modules.Comments.CommentLike
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  # ============================================================================
  # Module Status
  # ============================================================================

  @doc "Checks if the Comments module is enabled."
  def enabled? do
    Settings.get_boolean_setting("comments_enabled", false)
  end

  @doc "Enables the Comments module."
  def enable_system do
    Settings.update_boolean_setting_with_module("comments_enabled", true, "comments")
  end

  @doc "Disables the Comments module."
  def disable_system do
    Settings.update_boolean_setting_with_module("comments_enabled", false, "comments")
  end

  @doc "Gets the Comments module configuration with statistics."
  def get_config do
    %{
      enabled: enabled?(),
      total_comments: count_all_comments(),
      published_comments: count_all_comments(status: "published"),
      pending_comments: count_all_comments(status: "pending"),
      moderation_enabled: Settings.get_boolean_setting("comments_moderation", false),
      max_depth: get_max_depth(),
      max_length: get_max_length()
    }
  end

  @doc "Returns the configured maximum comment depth."
  def get_max_depth do
    Settings.get_setting("comments_max_depth", "10") |> String.to_integer()
  end

  @doc "Returns the configured maximum comment length."
  def get_max_length do
    Settings.get_setting("comments_max_length", "10000") |> String.to_integer()
  end

  # ============================================================================
  # Comment CRUD
  # ============================================================================

  @doc """
  Creates a comment on a resource.

  Automatically calculates depth from parent. Invokes resource handler callback
  if configured.

  ## Parameters

  - `resource_type` - Type of resource (e.g., "post")
  - `resource_id` - UUID of the resource
  - `user_id` - User ID of commenter
  - `attrs` - Comment attributes (content, parent_id, etc.)
  """
  def create_comment(resource_type, resource_id, user_id, attrs) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      do_create_comment(resource_type, resource_id, user_id, resolve_user_id(user_id), attrs)
    else
      case Integer.parse(user_id) do
        {int_id, ""} ->
          create_comment(resource_type, resource_id, int_id, attrs)

        _ ->
          {:error, :invalid_user_id}
      end
    end
  end

  def create_comment(resource_type, resource_id, user_id, attrs) when is_integer(user_id) do
    do_create_comment(resource_type, resource_id, resolve_user_uuid(user_id), user_id, attrs)
  end

  defp do_create_comment(resource_type, resource_id, user_uuid, user_int_id, attrs) do
    repo().transaction(fn ->
      attrs =
        attrs
        |> Map.put(:resource_type, resource_type)
        |> Map.put(:resource_uuid, resource_id)
        |> Map.put(:user_id, user_int_id)
        |> Map.put(:user_uuid, user_uuid)
        |> maybe_calculate_depth()

      case %Comment{}
           |> Comment.changeset(attrs)
           |> repo().insert() do
        {:ok, comment} ->
          notify_resource_handler(:on_comment_created, resource_type, resource_id, comment)
          comment

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Updates a comment.

  ## Parameters

  - `comment` - Comment to update
  - `attrs` - Attributes to update (content, status)
  """
  def update_comment(%Comment{} = comment, attrs) do
    comment
    |> Comment.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a comment.

  Cascades to child comments. Invokes resource handler callback if configured.
  """
  def delete_comment(%Comment{} = comment) do
    repo().transaction(fn ->
      case repo().delete(comment) do
        {:ok, deleted} ->
          notify_resource_handler(
            :on_comment_deleted,
            comment.resource_type,
            comment.resource_uuid,
            deleted
          )

          deleted

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Gets a single comment by ID with optional preloads.

  Returns `nil` if not found.
  """
  def get_comment(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    case repo().get(Comment, id) do
      nil -> nil
      comment -> repo().preload(comment, preloads)
    end
  end

  @doc """
  Gets a single comment by ID with optional preloads.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_comment!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    Comment
    |> repo().get!(id)
    |> repo().preload(preloads)
  end

  @doc """
  Gets nested comment tree for a resource.

  Returns all published comments organized in a tree structure.
  """
  def get_comment_tree(resource_type, resource_id) do
    comments =
      from(c in Comment,
        where:
          c.resource_type == ^resource_type and
            c.resource_uuid == ^resource_id and
            c.status == "published",
        order_by: [asc: c.inserted_at],
        preload: [:user]
      )
      |> repo().all()

    build_comment_tree(comments)
  end

  @doc """
  Lists comments for a resource (flat list).

  ## Options

  - `:preload` - Associations to preload
  - `:status` - Filter by status
  """
  def list_comments(resource_type, resource_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    query =
      from(c in Comment,
        where: c.resource_type == ^resource_type and c.resource_uuid == ^resource_id,
        order_by: [asc: c.inserted_at]
      )

    query = if status, do: where(query, [c], c.status == ^status), else: query

    query
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc "Counts comments for a resource."
  def count_comments(resource_type, resource_id, opts \\ []) do
    status = Keyword.get(opts, :status)

    query =
      from(c in Comment,
        where: c.resource_type == ^resource_type and c.resource_uuid == ^resource_id
      )

    query = if status, do: where(query, [c], c.status == ^status), else: query

    repo().aggregate(query, :count)
  rescue
    _ -> 0
  end

  # ============================================================================
  # Moderation
  # ============================================================================

  @doc "Sets a comment's status to published."
  def approve_comment(%Comment{} = comment) do
    update_comment(comment, %{status: "published"})
  end

  @doc "Sets a comment's status to hidden."
  def hide_comment(%Comment{} = comment) do
    update_comment(comment, %{status: "hidden"})
  end

  @doc "Bulk-updates status for multiple comment IDs."
  def bulk_update_status(comment_uuids, status)
      when is_list(comment_uuids) and status in ["published", "hidden", "deleted", "pending"] do
    from(c in Comment, where: c.uuid in ^comment_uuids)
    |> repo().update_all(set: [status: status, updated_at: UtilsDate.utc_now()])
  end

  @doc """
  Lists all comments across all resource types with filters.

  ## Options

  - `:resource_type` - Filter by resource type
  - `:status` - Filter by status
  - `:user_id` - Filter by user
  - `:search` - Search in content
  - `:page` - Page number (default: 1)
  - `:per_page` - Items per page (default: 20)
  """
  def list_all_comments(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    resource_type = Keyword.get(opts, :resource_type)
    status = Keyword.get(opts, :status)
    user_id = Keyword.get(opts, :user_id)
    search = Keyword.get(opts, :search)

    query =
      from(c in Comment,
        order_by: [desc: c.inserted_at],
        preload: [:user]
      )

    query =
      if resource_type, do: where(query, [c], c.resource_type == ^resource_type), else: query

    query = if status, do: where(query, [c], c.status == ^status), else: query
    query = maybe_filter_by_user(query, user_id)

    query =
      if search && search != "" do
        pattern = "%#{search}%"
        where(query, [c], ilike(c.content, ^pattern))
      else
        query
      end

    total = repo().aggregate(query, :count)

    comments =
      query
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> repo().all()

    %{
      comments: comments,
      total: total,
      page: page,
      per_page: per_page,
      total_pages: ceil(total / per_page)
    }
  end

  @doc "Returns aggregate statistics for all comments."
  def comment_stats do
    %{
      total: count_all_comments(),
      published: count_all_comments(status: "published"),
      pending: count_all_comments(status: "pending"),
      hidden: count_all_comments(status: "hidden"),
      deleted: count_all_comments(status: "deleted")
    }
  end

  # ============================================================================
  # Resource Resolution (for admin UI)
  # ============================================================================

  @doc """
  Resolves resource context (title and admin path) for a list of comments.

  Returns a map of `{resource_type, resource_id} => %{title: ..., path: ...}`
  by delegating to registered `comment_resource_handlers` that implement
  `resolve_comment_resources/1`.
  """
  def resolve_resource_context(comments) do
    comments
    |> Enum.group_by(& &1.resource_type, & &1.resource_uuid)
    |> Enum.reduce(%{}, fn {resource_type, ids}, acc ->
      resolved = resolve_for_type(resource_type, Enum.uniq(ids))

      Enum.reduce(resolved, acc, fn {id, info}, inner ->
        Map.put(inner, {resource_type, id}, info)
      end)
    end)
  end

  defp resource_handlers do
    configured = Application.get_env(:phoenix_kit, :comment_resource_handlers, %{})
    Map.merge(default_resource_handlers(), configured)
  end

  defp default_resource_handlers do
    %{"post" => PhoenixKit.Modules.Posts}
  end

  defp resolve_for_type(resource_type, resource_ids) do
    handlers = resource_handlers()

    case Map.get(handlers, resource_type) do
      nil ->
        %{}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :resolve_comment_resources, 1) do
          mod.resolve_comment_resources(resource_ids)
        else
          %{}
        end
    end
  rescue
    e ->
      Logger.warning("Comment resource resolver error: #{inspect(e)}")
      %{}
  end

  # ============================================================================
  # Like Operations
  # ============================================================================

  @doc "User likes a comment. Creates like record and increments counter."
  def like_comment(comment_uuid, user_id) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      do_like_comment(comment_uuid, user_id, resolve_user_id(user_id))
    else
      case Integer.parse(user_id) do
        {int_id, ""} -> like_comment(comment_uuid, int_id)
        _ -> {:error, :invalid_user_id}
      end
    end
  end

  def like_comment(comment_uuid, user_id) when is_integer(user_id) do
    do_like_comment(comment_uuid, resolve_user_uuid(user_id), user_id)
  end

  defp do_like_comment(comment_uuid, user_uuid, user_int_id) do
    repo().transaction(fn ->
      case %CommentLike{}
           |> CommentLike.changeset(%{
             comment_uuid: comment_uuid,
             user_id: user_int_id,
             user_uuid: user_uuid
           })
           |> repo().insert() do
        {:ok, like} ->
          increment_comment_like_count(comment_uuid)
          like

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc "User unlikes a comment. Deletes like record and decrements counter."
  def unlike_comment(comment_uuid, user_id) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      do_unlike_comment(comment_uuid, user_id)
    else
      case Integer.parse(user_id) do
        {int_id, ""} -> unlike_comment(comment_uuid, int_id)
        _ -> {:error, :invalid_user_id}
      end
    end
  end

  def unlike_comment(comment_uuid, user_id) when is_integer(user_id) do
    do_unlike_comment(comment_uuid, resolve_user_uuid(user_id))
  end

  defp do_unlike_comment(comment_uuid, user_uuid) do
    repo().transaction(fn ->
      case repo().get_by(CommentLike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
        nil ->
          repo().rollback(:not_found)

        like ->
          {:ok, _} = repo().delete(like)
          decrement_comment_like_count(comment_uuid)
          like
      end
    end)
  end

  @doc "Checks if a user has liked a comment."
  def comment_liked_by?(comment_uuid, user_id) when is_integer(user_id) do
    comment_liked_by?(comment_uuid, resolve_user_uuid(user_id))
  end

  def comment_liked_by?(comment_uuid, user_id) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      repo().exists?(
        from(l in CommentLike, where: l.comment_uuid == ^comment_uuid and l.user_uuid == ^user_id)
      )
    else
      case Integer.parse(user_id) do
        {int_id, ""} -> comment_liked_by?(comment_uuid, int_id)
        _ -> false
      end
    end
  end

  @doc "Lists all likes for a comment."
  def list_comment_likes(comment_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(l in CommentLike,
      where: l.comment_uuid == ^comment_uuid,
      order_by: [desc: l.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  # ============================================================================
  # Dislike Operations
  # ============================================================================

  @doc "User dislikes a comment. Creates dislike record and increments counter."
  def dislike_comment(comment_uuid, user_id) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      do_dislike_comment(comment_uuid, user_id, resolve_user_id(user_id))
    else
      case Integer.parse(user_id) do
        {int_id, ""} -> dislike_comment(comment_uuid, int_id)
        _ -> {:error, :invalid_user_id}
      end
    end
  end

  def dislike_comment(comment_uuid, user_id) when is_integer(user_id) do
    do_dislike_comment(comment_uuid, resolve_user_uuid(user_id), user_id)
  end

  defp do_dislike_comment(comment_uuid, user_uuid, user_int_id) do
    repo().transaction(fn ->
      case %CommentDislike{}
           |> CommentDislike.changeset(%{
             comment_uuid: comment_uuid,
             user_id: user_int_id,
             user_uuid: user_uuid
           })
           |> repo().insert() do
        {:ok, dislike} ->
          increment_comment_dislike_count(comment_uuid)
          dislike

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc "User removes dislike from a comment. Deletes dislike record and decrements counter."
  def undislike_comment(comment_uuid, user_id) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      do_undislike_comment(comment_uuid, user_id)
    else
      case Integer.parse(user_id) do
        {int_id, ""} -> undislike_comment(comment_uuid, int_id)
        _ -> {:error, :invalid_user_id}
      end
    end
  end

  def undislike_comment(comment_uuid, user_id) when is_integer(user_id) do
    do_undislike_comment(comment_uuid, resolve_user_uuid(user_id))
  end

  defp do_undislike_comment(comment_uuid, user_uuid) do
    repo().transaction(fn ->
      case repo().get_by(CommentDislike, comment_uuid: comment_uuid, user_uuid: user_uuid) do
        nil ->
          repo().rollback(:not_found)

        dislike ->
          {:ok, _} = repo().delete(dislike)
          decrement_comment_dislike_count(comment_uuid)
          dislike
      end
    end)
  end

  @doc "Checks if a user has disliked a comment."
  def comment_disliked_by?(comment_uuid, user_id) when is_integer(user_id) do
    comment_disliked_by?(comment_uuid, resolve_user_uuid(user_id))
  end

  def comment_disliked_by?(comment_uuid, user_id) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      repo().exists?(
        from(d in CommentDislike,
          where: d.comment_uuid == ^comment_uuid and d.user_uuid == ^user_id
        )
      )
    else
      case Integer.parse(user_id) do
        {int_id, ""} -> comment_disliked_by?(comment_uuid, int_id)
        _ -> false
      end
    end
  end

  @doc "Lists all dislikes for a comment."
  def list_comment_dislikes(comment_uuid, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(d in CommentDislike,
      where: d.comment_uuid == ^comment_uuid,
      order_by: [desc: d.inserted_at]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp maybe_calculate_depth(attrs) do
    case Map.get(attrs, :parent_uuid) do
      nil ->
        Map.put(attrs, :depth, 0)

      parent_id ->
        case repo().get(Comment, parent_id) do
          nil -> Map.put(attrs, :depth, 0)
          parent -> Map.put(attrs, :depth, (parent.depth || 0) + 1)
        end
    end
  end

  defp build_comment_tree(comments) do
    comment_map = Map.new(comments, &{&1.uuid, &1})

    comments
    |> Enum.filter(&(&1.parent_uuid == nil))
    |> Enum.map(&add_children(&1, comment_map))
  end

  defp add_children(comment, comment_map) do
    children =
      comment_map
      |> Map.values()
      |> Enum.filter(&(&1.parent_uuid == comment.uuid))
      |> Enum.map(&add_children(&1, comment_map))

    Map.put(comment, :children, children)
  end

  defp increment_comment_like_count(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid)
    |> repo().update_all(inc: [like_count: 1])
  end

  defp decrement_comment_like_count(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid and c.like_count > 0)
    |> repo().update_all(inc: [like_count: -1])
  end

  defp increment_comment_dislike_count(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid)
    |> repo().update_all(inc: [dislike_count: 1])
  end

  defp decrement_comment_dislike_count(comment_uuid) do
    from(c in Comment, where: c.uuid == ^comment_uuid and c.dislike_count > 0)
    |> repo().update_all(inc: [dislike_count: -1])
  end

  defp count_all_comments(opts \\ []) do
    status = Keyword.get(opts, :status)
    query = from(c in Comment)
    query = if status, do: where(query, [c], c.status == ^status), else: query
    repo().aggregate(query, :count)
  rescue
    _ -> 0
  end

  defp maybe_filter_by_user(query, nil), do: query

  defp maybe_filter_by_user(query, user_id) when is_integer(user_id) do
    user_uuid = resolve_user_uuid(user_id)
    where(query, [c], c.user_uuid == ^user_uuid)
  end

  defp maybe_filter_by_user(query, user_id) when is_binary(user_id) do
    if UUIDUtils.valid?(user_id) do
      where(query, [c], c.user_uuid == ^user_id)
    else
      case Integer.parse(user_id) do
        {int_id, ""} -> maybe_filter_by_user(query, int_id)
        _ -> query
      end
    end
  end

  defp resolve_user_uuid(user_id) when is_integer(user_id) do
    from(u in Auth.User, where: u.id == ^user_id, select: u.uuid)
    |> repo().one()
  end

  defp resolve_user_id(user_uuid) when is_binary(user_uuid) do
    from(u in Auth.User, where: u.uuid == ^user_uuid, select: u.id)
    |> repo().one()
  end

  defp notify_resource_handler(callback, resource_type, resource_id, comment) do
    handlers = resource_handlers()

    case Map.get(handlers, resource_type) do
      nil ->
        :ok

      handler_module ->
        if Code.ensure_loaded?(handler_module) and
             function_exported?(handler_module, callback, 3) do
          apply(handler_module, callback, [resource_type, resource_id, comment])
        else
          :ok
        end
    end
  rescue
    error ->
      Logger.warning("Comment resource handler error: #{inspect(error)}")
      :ok
  end

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
