defmodule PhoenixKit.Modules.Posts do
  @moduledoc """
  Context for managing posts, likes, tags, and groups.

  Provides complete API for the social posts system including CRUD operations,
  counter cache management, tag assignment, and group organization.
  Comments are now handled by the standalone `PhoenixKit.Modules.Comments` module.

  ## Features

  - **Post Management**: Create, update, delete, publish, schedule posts
  - **Like System**: Like/unlike posts, check like status
  - **Comment System**: Nested threaded comments with unlimited depth
  - **Tag System**: Hashtag categorization with auto-slugification
  - **Group System**: User collections for organizing posts
  - **Media Attachments**: Multiple images per post with ordering
  - **Publishing**: Draft/public/unlisted/scheduled status management
  - **Analytics**: View tracking (future feature)

  ## Examples

      # Create a post
      {:ok, post} = Posts.create_post(user_id, %{
        title: "My First Post",
        content: "Hello world!",
        type: "post",
        status: "draft"
      })

      # Publish a post
      {:ok, post} = Posts.publish_post(post)

      # Like a post
      {:ok, like} = Posts.like_post(post.id, user_id)

      # Add a comment
      {:ok, comment} = Posts.create_comment(post.id, user_id, %{
        content: "Great post!"
      })

      # Create a group
      {:ok, group} = Posts.create_group(user_id, %{
        name: "Travel Photos",
        description: "My adventures"
      })
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Modules.Posts.{
    Post,
    PostDislike,
    PostGroup,
    PostGroupAssignment,
    PostLike,
    PostMedia,
    PostMention,
    PostTag,
    PostTagAssignment,
    ScheduledPostHandler
  }

  alias PhoenixKit.ScheduledJobs
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth

  # ============================================================================
  # Module Status
  # ============================================================================

  @doc """
  Checks if the Posts module is enabled.

  ## Examples

      iex> enabled?()
      true
  """
  def enabled? do
    Settings.get_boolean_setting("posts_enabled", true)
  end

  @doc """
  Enables the Posts module.

  ## Examples

      iex> enable_system()
      {:ok, %Setting{}}
  """
  def enable_system do
    Settings.update_boolean_setting_with_module("posts_enabled", true, "posts")
  end

  @doc """
  Disables the Posts module.

  ## Examples

      iex> disable_system()
      {:ok, %Setting{}}
  """
  def disable_system do
    Settings.update_boolean_setting_with_module("posts_enabled", false, "posts")
  end

  @doc """
  Gets the current Posts module configuration and stats.

  ## Examples

      iex> get_config()
      %{enabled: true, total_posts: 42, published_posts: 30, ...}
  """
  def get_config do
    %{
      enabled: enabled?(),
      total_posts: count_posts(),
      published_posts: count_posts_by_status("public"),
      draft_posts: count_posts_by_status("draft"),
      likes_enabled: Settings.get_boolean_setting("posts_likes_enabled", true)
    }
  end

  defp count_posts do
    repo().aggregate(Post, :count, :id)
  rescue
    _ -> 0
  end

  defp count_posts_by_status(status) do
    from(p in Post, where: p.status == ^status)
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  # ============================================================================
  # CRUD Operations
  # ============================================================================

  @doc """
  Creates a new post.

  ## Parameters

  - `user_id` - Owner of the post
  - `attrs` - Post attributes (title, content, type, status, etc.)

  ## Examples

      iex> create_post(1, %{title: "Test", content: "Content", type: "post"})
      {:ok, %Post{}}

      iex> create_post(1, %{title: "", content: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_post(user_id, attrs) when is_integer(user_id) do
    # Use string key to match form params (which have string keys)
    attrs =
      attrs
      |> Map.put("user_id", user_id)
      |> Map.put("user_uuid", resolve_user_uuid(user_id))

    %Post{}
    |> Post.changeset(attrs)
    |> repo().insert()
  end

  def create_post(user_id, attrs) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> create_post(int_id, attrs)
      _ -> create_post_with_uuid(user_id, attrs)
    end
  end

  defp create_post_with_uuid(user_uuid, attrs) do
    case Auth.get_user(user_uuid) do
      %{id: user_id, uuid: uuid} ->
        attrs =
          attrs
          |> Map.put("user_id", user_id)
          |> Map.put("user_uuid", uuid)

        %Post{}
        |> Post.changeset(attrs)
        |> repo().insert()

      nil ->
        {:error, :user_not_found}
    end
  end

  @doc """
  Updates an existing post.

  ## Parameters

  - `post` - Post struct to update
  - `attrs` - Attributes to update

  ## Examples

      iex> update_post(post, %{title: "Updated Title"})
      {:ok, %Post{}}

      iex> update_post(post, %{title: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_post(%Post{} = post, attrs) do
    post
    |> Post.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a post and all related data (cascades to media, likes, comments, etc.).

  ## Parameters

  - `post` - Post struct to delete

  ## Examples

      iex> delete_post(post)
      {:ok, %Post{}}

      iex> delete_post(post)
      {:error, %Ecto.Changeset{}}
  """
  def delete_post(%Post{} = post) do
    repo().delete(post)
  end

  @doc """
  Gets a single post by ID with optional preloads.

  Raises `Ecto.NoResultsError` if post not found.

  ## Parameters

  - `id` - Post ID (UUIDv7)
  - `opts` - Options
    - `:preload` - List of associations to preload

  ## Examples

      iex> get_post!("018e3c4a-...")
      %Post{}

      iex> get_post!("018e3c4a-...", preload: [:user, :media, :tags])
      %Post{user: %User{}, media: [...], tags: [...]}

      iex> get_post!("nonexistent")
      ** (Ecto.NoResultsError)
  """
  def get_post!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    Post
    |> repo().get!(id)
    |> repo().preload(preloads)
  end

  @doc """
  Gets a single post by ID with optional preloads.

  Returns `nil` if post not found.

  ## Parameters

  - `id` - Post ID (UUIDv7)
  - `opts` - Options
    - `:preload` - List of associations to preload

  ## Examples

      iex> get_post("018e3c4a-...")
      %Post{}

      iex> get_post("018e3c4a-...", preload: [:user, :media, :tags])
      %Post{user: %User{}, media: [...], tags: [...]}

      iex> get_post("nonexistent")
      nil
  """
  def get_post(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    case repo().get(Post, id) do
      nil -> nil
      post -> repo().preload(post, preloads)
    end
  end

  @doc """
  Gets a single post by slug.

  ## Parameters

  - `slug` - Post slug (e.g., "my-first-post")
  - `opts` - Options
    - `:preload` - List of associations to preload

  ## Examples

      iex> get_post_by_slug("my-first-post")
      %Post{}

      iex> get_post_by_slug("nonexistent")
      nil
  """
  def get_post_by_slug(slug, opts \\ []) when is_binary(slug) do
    preloads = Keyword.get(opts, :preload, [])

    Post
    |> where([p], p.slug == ^slug)
    |> repo().one()
    |> case do
      nil -> nil
      post -> repo().preload(post, preloads)
    end
  end

  @doc """
  Lists posts with optional filtering and pagination.

  ## Parameters

  - `opts` - Options
    - `:user_id` - Filter by user
    - `:status` - Filter by status (draft/public/unlisted/scheduled)
    - `:type` - Filter by type (post/snippet/repost)
    - `:search` - Search in title and content
    - `:page` - Page number (default: 1)
    - `:per_page` - Items per page (default: 20)
    - `:preload` - Associations to preload

  ## Examples

      iex> list_posts()
      [%Post{}, ...]

      iex> list_posts(status: "public", page: 1, per_page: 10)
      [%Post{}, ...]

      iex> list_posts(user_id: 42, type: "post")
      [%Post{}, ...]
  """
  def list_posts(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)
    type = Keyword.get(opts, :type)
    search = Keyword.get(opts, :search)
    preloads = Keyword.get(opts, :preload, [])

    Post
    |> maybe_filter_by_user(user_id)
    |> maybe_filter_by_status(status)
    |> maybe_filter_by_type(type)
    |> maybe_search(search)
    |> order_by([p], desc: p.inserted_at)
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Lists user's posts.

  ## Parameters

  - `user_id` - User ID
  - `opts` - See `list_posts/1` for options

  ## Examples

      iex> list_user_posts(42)
      [%Post{}, ...]
  """
  def list_user_posts(user_id, opts \\ [])

  def list_user_posts(user_id, opts) when is_integer(user_id) do
    opts = Keyword.put(opts, :user_id, user_id)
    list_posts(opts)
  end

  def list_user_posts(user_id, opts) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> list_user_posts(int_id, opts)
      _ -> list_posts(Keyword.put(opts, :user_id, user_id))
    end
  end

  @doc """
  Lists public posts only.

  ## Parameters

  - `opts` - See `list_posts/1` for options

  ## Examples

      iex> list_public_posts()
      [%Post{}, ...]
  """
  def list_public_posts(opts \\ []) do
    opts = Keyword.put(opts, :status, "public")
    list_posts(opts)
  end

  # ============================================================================
  # Publishing Operations
  # ============================================================================

  @doc """
  Publishes a post (makes it public).

  Sets status to "public" and published_at to current time.

  ## Examples

      iex> publish_post(post)
      {:ok, %Post{status: "public"}}
  """
  def publish_post(%Post{} = post) do
    update_post(post, %{
      status: "public",
      published_at: DateTime.utc_now()
    })
  end

  @doc """
  Schedules a post for future publishing.

  Updates the post status to "scheduled" and creates an entry in the
  scheduled jobs table for execution by the cron worker.

  ## Parameters

  - `post` - Post to schedule
  - `scheduled_at` - DateTime to publish at (must be in future)
  - `attrs` - Additional attributes to update (title, content, etc.)
  - `opts` - Options
    - `:created_by_id` - UUID of user scheduling the post

  ## Examples

      iex> schedule_post(post, ~U[2025-12-31 09:00:00Z])
      {:ok, %Post{status: "scheduled"}}

      iex> schedule_post(post, ~U[2025-12-31 09:00:00Z], %{title: "New Title"})
      {:ok, %Post{status: "scheduled", title: "New Title"}}
  """
  def schedule_post(%Post{} = post, %DateTime{} = scheduled_at, attrs \\ %{}, opts \\ []) do
    repo().transaction(fn ->
      # Merge additional attrs with status and scheduled_at
      update_attrs =
        attrs
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.merge(%{"status" => "scheduled", "scheduled_at" => scheduled_at})

      # Update the post with all attrs
      case update_post(post, update_attrs) do
        {:ok, updated_post} ->
          Logger.debug("Posts.schedule_post: Post status updated to 'scheduled'")

          # Cancel any existing pending scheduled jobs for this post
          {cancelled_count, _} = ScheduledJobs.cancel_jobs_for_resource("post", post.id)

          if cancelled_count > 0 do
            Logger.debug(
              "Posts.schedule_post: Cancelled #{cancelled_count} existing scheduled job(s)"
            )
          end

          # Create new scheduled job entry with useful context
          job_args = %{
            "post_title" => updated_post.title,
            "post_type" => updated_post.type,
            "post_status" => updated_post.status,
            "scheduled_for" => DateTime.to_iso8601(scheduled_at)
          }

          case ScheduledJobs.schedule_job(
                 ScheduledPostHandler,
                 post.id,
                 scheduled_at,
                 job_args,
                 opts
               ) do
            {:ok, job} ->
              Logger.info(
                "Posts.schedule_post: Created scheduled job #{job.id} for post #{post.id}"
              )

              updated_post

            {:error, reason} ->
              Logger.error(
                "Posts.schedule_post: Failed to create scheduled job: #{inspect(reason)}"
              )

              repo().rollback(reason)
          end

        {:error, changeset} ->
          Logger.error("Posts.schedule_post: Failed to update post: #{inspect(changeset.errors)}")
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Unschedules a post, reverting it to draft status.

  Cancels any pending scheduled jobs for this post.

  ## Parameters

  - `post` - Post to unschedule

  ## Examples

      iex> unschedule_post(post)
      {:ok, %Post{status: "draft"}}
  """
  def unschedule_post(%Post{} = post) do
    repo().transaction(fn ->
      # Cancel any pending scheduled jobs
      ScheduledJobs.cancel_jobs_for_resource("post", post.id)

      # Revert to draft status
      case update_post(post, %{status: "draft", scheduled_at: nil}) do
        {:ok, updated_post} -> updated_post
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Reverts a post to draft status.

  ## Examples

      iex> draft_post(post)
      {:ok, %Post{status: "draft"}}
  """
  def draft_post(%Post{} = post) do
    update_post(post, %{status: "draft"})
  end

  @doc """
  Processes scheduled posts that are ready to be published.

  Finds all posts with status "scheduled" where scheduled_at <= now,
  and publishes them. Returns list of published posts.

  Should be called periodically (e.g., via Oban job every minute).

  ## Examples

      iex> process_scheduled_posts()
      {:ok, 2}
  """
  def process_scheduled_posts do
    now = DateTime.utc_now()

    posts_to_publish =
      from(p in Post,
        where: p.status == "scheduled",
        where: p.scheduled_at <= ^now
      )
      |> repo().all(log: false)

    results = Enum.map(posts_to_publish, &publish_post/1)
    published_count = Enum.count(results, &match?({:ok, _}, &1))

    {:ok, published_count}
  end

  # ============================================================================
  # Counter Cache Operations
  # ============================================================================

  @doc """
  Increments the like counter for a post.

  ## Examples

      iex> increment_like_count(post)
      {1, nil}
  """
  def increment_like_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id)
    |> repo().update_all(inc: [like_count: 1])
  end

  @doc """
  Decrements the like counter for a post.

  ## Examples

      iex> decrement_like_count(post)
      {1, nil}
  """
  def decrement_like_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id and p.like_count > 0)
    |> repo().update_all(inc: [like_count: -1])
  end

  @doc """
  Increments the dislike counter for a post.

  ## Examples

      iex> increment_dislike_count(post)
      {1, nil}
  """
  def increment_dislike_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id)
    |> repo().update_all(inc: [dislike_count: 1])
  end

  @doc """
  Decrements the dislike counter for a post.

  ## Examples

      iex> decrement_dislike_count(post)
      {1, nil}
  """
  def decrement_dislike_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id and p.dislike_count > 0)
    |> repo().update_all(inc: [dislike_count: -1])
  end

  @doc """
  Increments the comment counter for a post.

  ## Examples

      iex> increment_comment_count(post)
      {1, nil}
  """
  def increment_comment_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id)
    |> repo().update_all(inc: [comment_count: 1])
  end

  @doc """
  Decrements the comment counter for a post.

  ## Examples

      iex> decrement_comment_count(post)
      {1, nil}
  """
  def decrement_comment_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id and p.comment_count > 0)
    |> repo().update_all(inc: [comment_count: -1])
  end

  @doc """
  Increments the view counter for a post.

  ## Examples

      iex> increment_view_count(post)
      {1, nil}
  """
  def increment_view_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id)
    |> repo().update_all(inc: [view_count: 1])
  end

  # ============================================================================
  # Like Operations
  # ============================================================================

  @doc """
  User likes a post.

  Creates a like record and increments the post's like counter.
  Returns error if user already liked the post.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID

  ## Examples

      iex> like_post("018e3c4a-...", 42)
      {:ok, %PostLike{}}

      iex> like_post("018e3c4a-...", 42)  # Already liked
      {:error, %Ecto.Changeset{}}
  """
  def like_post(post_id, user_id) when is_integer(user_id) do
    repo().transaction(fn ->
      case %PostLike{}
           |> PostLike.changeset(%{
             post_id: post_id,
             user_id: user_id,
             user_uuid: resolve_user_uuid(user_id)
           })
           |> repo().insert() do
        {:ok, like} ->
          increment_like_count(%Post{id: post_id})
          like

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  def like_post(post_id, user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> like_post(post_id, int_id)
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  User unlikes a post.

  Deletes the like record and decrements the post's like counter.
  Returns error if like doesn't exist.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID

  ## Examples

      iex> unlike_post("018e3c4a-...", 42)
      {:ok, %PostLike{}}

      iex> unlike_post("018e3c4a-...", 42)  # Not liked
      {:error, :not_found}
  """
  def unlike_post(post_id, user_id) when is_integer(user_id) do
    repo().transaction(fn ->
      case repo().get_by(PostLike, post_id: post_id, user_id: user_id) do
        nil ->
          repo().rollback(:not_found)

        like ->
          {:ok, _} = repo().delete(like)
          decrement_like_count(%Post{id: post_id})
          like
      end
    end)
  end

  def unlike_post(post_id, user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> unlike_post(post_id, int_id)
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  Checks if a user has liked a post.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID

  ## Examples

      iex> post_liked_by?("018e3c4a-...", 42)
      true

      iex> post_liked_by?("018e3c4a-...", 99)
      false
  """
  def post_liked_by?(post_id, user_id) when is_integer(user_id) do
    repo().exists?(from l in PostLike, where: l.post_id == ^post_id and l.user_id == ^user_id)
  end

  def post_liked_by?(post_id, user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> post_liked_by?(post_id, int_id)
      _ -> false
    end
  end

  @doc """
  Lists all likes for a post.

  ## Parameters

  - `post_id` - Post ID
  - `opts` - Options
    - `:preload` - Associations to preload

  ## Examples

      iex> list_post_likes("018e3c4a-...")
      [%PostLike{}, ...]

      iex> list_post_likes("018e3c4a-...", preload: [:user])
      [%PostLike{user: %User{}}, ...]
  """
  def list_post_likes(post_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(l in PostLike, where: l.post_id == ^post_id, order_by: [desc: l.inserted_at])
    |> repo().all()
    |> repo().preload(preloads)
  end

  # ============================================================================
  # Post Dislike Operations
  # ============================================================================

  @doc """
  User dislikes a post.

  Creates a dislike record and increments the post's dislike counter.
  Returns error if user has already disliked the post.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID

  ## Examples

      iex> dislike_post("018e3c4a-...", 42)
      {:ok, %PostDislike{}}

      iex> dislike_post("018e3c4a-...", 42)  # Already disliked
      {:error, %Ecto.Changeset{}}
  """
  def dislike_post(post_id, user_id) when is_integer(user_id) do
    repo().transaction(fn ->
      case %PostDislike{}
           |> PostDislike.changeset(%{
             post_id: post_id,
             user_id: user_id,
             user_uuid: resolve_user_uuid(user_id)
           })
           |> repo().insert() do
        {:ok, dislike} ->
          increment_dislike_count(%Post{id: post_id})
          dislike

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  def dislike_post(post_id, user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> dislike_post(post_id, int_id)
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  User removes dislike from a post.

  Deletes the dislike record and decrements the post's dislike counter.
  Returns error if dislike doesn't exist.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID

  ## Examples

      iex> undislike_post("018e3c4a-...", 42)
      {:ok, %PostDislike{}}

      iex> undislike_post("018e3c4a-...", 42)  # Not disliked
      {:error, :not_found}
  """
  def undislike_post(post_id, user_id) when is_integer(user_id) do
    repo().transaction(fn ->
      case repo().get_by(PostDislike, post_id: post_id, user_id: user_id) do
        nil ->
          repo().rollback(:not_found)

        dislike ->
          {:ok, _} = repo().delete(dislike)
          decrement_dislike_count(%Post{id: post_id})
          dislike
      end
    end)
  end

  def undislike_post(post_id, user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> undislike_post(post_id, int_id)
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  Checks if a user has disliked a post.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID

  ## Examples

      iex> post_disliked_by?("018e3c4a-...", 42)
      true

      iex> post_disliked_by?("018e3c4a-...", 99)
      false
  """
  def post_disliked_by?(post_id, user_id) when is_integer(user_id) do
    repo().exists?(from d in PostDislike, where: d.post_id == ^post_id and d.user_id == ^user_id)
  end

  def post_disliked_by?(post_id, user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> post_disliked_by?(post_id, int_id)
      _ -> false
    end
  end

  @doc """
  Lists all dislikes for a post.

  ## Parameters

  - `post_id` - Post ID
  - `opts` - Options
    - `:preload` - Associations to preload

  ## Examples

      iex> list_post_dislikes("018e3c4a-...")
      [%PostDislike{}, ...]

      iex> list_post_dislikes("018e3c4a-...", preload: [:user])
      [%PostDislike{user: %User{}}, ...]
  """
  def list_post_dislikes(post_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(d in PostDislike, where: d.post_id == ^post_id, order_by: [desc: d.inserted_at])
    |> repo().all()
    |> repo().preload(preloads)
  end

  # ============================================================================
  # Comment Resource Handler Callbacks
  # ============================================================================

  @doc """
  Callback invoked by the Comments module when a comment is created on a post.
  Increments the post's denormalized comment_count.
  """
  def on_comment_created("post", resource_id, _comment) do
    increment_comment_count(%Post{id: resource_id})
    :ok
  end

  def on_comment_created(_resource_type, _resource_id, _comment), do: :ok

  @doc """
  Callback invoked by the Comments module when a comment is deleted from a post.
  Decrements the post's denormalized comment_count.
  """
  def on_comment_deleted("post", resource_id, _comment) do
    decrement_comment_count(%Post{id: resource_id})
    :ok
  end

  def on_comment_deleted(_resource_type, _resource_id, _comment), do: :ok

  @doc """
  Resolves post titles and admin paths for a list of resource IDs.

  Called by the Comments module to display resource context in the admin UI.
  Returns a map of `resource_id => %{title: ..., path: ...}`.
  """
  def resolve_comment_resources(resource_ids) when is_list(resource_ids) do
    from(p in Post, where: p.id in ^resource_ids, select: {p.id, p.title})
    |> repo().all()
    |> Map.new(fn {id, title} -> {id, %{title: title, path: "/admin/posts/#{id}"}} end)
  rescue
    _ -> %{}
  end

  # ============================================================================
  # Tag Operations
  # ============================================================================

  @doc """
  Finds or creates a tag by name.

  Automatically generates slug from name. Returns existing tag if slug already exists.

  ## Parameters

  - `name` - Tag name (e.g., "Web Development")

  ## Examples

      iex> find_or_create_tag("Web Development")
      {:ok, %PostTag{name: "Web Development", slug: "web-development"}}

      iex> find_or_create_tag("web development")  # Same slug
      {:ok, %PostTag{name: "Web Development"}}  # Returns existing
  """
  def find_or_create_tag(name) when is_binary(name) do
    changeset = PostTag.changeset(%PostTag{}, %{name: name})
    slug = Ecto.Changeset.get_field(changeset, :slug)

    case repo().get_by(PostTag, slug: slug) do
      nil -> repo().insert(changeset)
      tag -> {:ok, tag}
    end
  end

  @doc """
  Parses hashtags from text.

  Extracts all hashtags (#word) from text and returns list of tag names.

  ## Parameters

  - `text` - Text to parse

  ## Examples

      iex> parse_hashtags("Check out #elixir and #phoenix!")
      ["elixir", "phoenix"]

      iex> parse_hashtags("No tags here")
      []
  """
  def parse_hashtags(text) when is_binary(text) do
    ~r/#(\w+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc """
  Adds tags to a post.

  Creates tags if they don't exist, then assigns them to the post.
  Updates usage counters for tags.

  ## Parameters

  - `post` - Post to tag
  - `tag_names` - List of tag names

  ## Examples

      iex> add_tags_to_post(post, ["elixir", "phoenix"])
      {:ok, [%PostTag{}, %PostTag{}]}
  """
  def add_tags_to_post(%Post{id: post_id}, tag_names) when is_list(tag_names) do
    repo().transaction(fn ->
      tags =
        Enum.map(tag_names, fn name ->
          case find_or_create_tag(name) do
            {:ok, tag} -> tag
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      Enum.each(tags, fn tag ->
        %PostTagAssignment{}
        |> PostTagAssignment.changeset(%{post_id: post_id, tag_id: tag.id})
        |> repo().insert(on_conflict: :nothing)

        # Increment tag usage
        from(t in PostTag, where: t.id == ^tag.id)
        |> repo().update_all(inc: [usage_count: 1])
      end)

      tags
    end)
  end

  @doc """
  Removes a tag from a post.

  ## Parameters

  - `post_id` - Post ID
  - `tag_id` - Tag ID

  ## Examples

      iex> remove_tag_from_post("018e3c4a-...", "018e3c4a-...")
      {:ok, %PostTagAssignment{}}
  """
  def remove_tag_from_post(post_id, tag_id) do
    case repo().get_by(PostTagAssignment, post_id: post_id, tag_id: tag_id) do
      nil ->
        {:error, :not_found}

      assignment ->
        repo().transaction(fn ->
          repo().delete(assignment)

          # Decrement tag usage
          from(t in PostTag, where: t.id == ^tag_id and t.usage_count > 0)
          |> repo().update_all(inc: [usage_count: -1])

          assignment
        end)
    end
  end

  @doc """
  Lists popular tags by usage count.

  ## Parameters

  - `limit` - Number of tags to return (default: 20)

  ## Examples

      iex> list_popular_tags(10)
      [%PostTag{usage_count: 150}, %PostTag{usage_count: 120}, ...]
  """
  def list_popular_tags(limit \\ 20) do
    from(t in PostTag, order_by: [desc: t.usage_count], limit: ^limit)
    |> repo().all()
  end

  # ============================================================================
  # Group Operations
  # ============================================================================

  @doc """
  Creates a user group.

  ## Parameters

  - `user_id` - Owner of the group
  - `attrs` - Group attributes (name, description, etc.)

  ## Examples

      iex> create_group(42, %{name: "Travel Photos"})
      {:ok, %PostGroup{}}
  """
  def create_group(user_id, attrs) when is_integer(user_id) do
    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:user_uuid, resolve_user_uuid(user_id))

    %PostGroup{}
    |> PostGroup.changeset(attrs)
    |> repo().insert()
  end

  def create_group(user_id, attrs) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> create_group(int_id, attrs)
      _ -> create_group_with_uuid(user_id, attrs)
    end
  end

  defp create_group_with_uuid(user_uuid, attrs) do
    case Auth.get_user(user_uuid) do
      %{id: user_id, uuid: uuid} ->
        attrs =
          attrs
          |> Map.put(:user_id, user_id)
          |> Map.put(:user_uuid, uuid)

        %PostGroup{}
        |> PostGroup.changeset(attrs)
        |> repo().insert()

      nil ->
        {:error, :user_not_found}
    end
  end

  @doc """
  Updates a group.

  ## Parameters

  - `group` - Group to update
  - `attrs` - Attributes to update

  ## Examples

      iex> update_group(group, %{name: "New Name"})
      {:ok, %PostGroup{}}
  """
  def update_group(%PostGroup{} = group, attrs) do
    group
    |> PostGroup.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a group.

  ## Parameters

  - `group` - Group to delete

  ## Examples

      iex> delete_group(group)
      {:ok, %PostGroup{}}
  """
  def delete_group(%PostGroup{} = group) do
    repo().delete(group)
  end

  @doc """
  Gets a single group by ID with optional preloads.

  Returns `nil` if group not found.

  ## Parameters

  - `id` - Group ID (UUIDv7)
  - `opts` - Options
    - `:preload` - List of associations to preload (e.g., [:user, :posts])

  ## Examples

      iex> get_group("018e3c4a-...")
      %PostGroup{}

      iex> get_group("018e3c4a-...", preload: [:user])
      %PostGroup{user: %User{}}

      iex> get_group("nonexistent")
      nil
  """
  def get_group(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    case repo().get(PostGroup, id) do
      nil -> nil
      group -> repo().preload(group, preloads)
    end
  end

  @doc """
  Gets a single group by ID with optional preloads.

  Raises `Ecto.NoResultsError` if group not found.

  ## Parameters

  - `id` - Group ID (UUIDv7)
  - `opts` - Options
    - `:preload` - List of associations to preload (e.g., [:user, :posts])

  ## Examples

      iex> get_group!("018e3c4a-...")
      %PostGroup{}

      iex> get_group!("018e3c4a-...", preload: [:user])
      %PostGroup{user: %User{}}

      iex> get_group!("nonexistent")
      ** (Ecto.NoResultsError)
  """
  def get_group!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    PostGroup
    |> repo().get!(id)
    |> repo().preload(preloads)
  end

  @doc """
  Adds a post to a group.

  Increments the group's post counter.

  ## Parameters

  - `post_id` - Post ID
  - `group_id` - Group ID
  - `opts` - Options
    - `:position` - Display position (default: 0)

  ## Examples

      iex> add_post_to_group("018e3c4a-...", "018e3c4a-...")
      {:ok, %PostGroupAssignment{}}
  """
  def add_post_to_group(post_id, group_id, opts \\ []) do
    position = Keyword.get(opts, :position, 0)

    repo().transaction(fn ->
      case %PostGroupAssignment{}
           |> PostGroupAssignment.changeset(%{
             post_id: post_id,
             group_id: group_id,
             position: position
           })
           |> repo().insert() do
        {:ok, assignment} ->
          from(g in PostGroup, where: g.id == ^group_id)
          |> repo().update_all(inc: [post_count: 1])

          assignment

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Removes a post from a group.

  Decrements the group's post counter.

  ## Parameters

  - `post_id` - Post ID
  - `group_id` - Group ID

  ## Examples

      iex> remove_post_from_group("018e3c4a-...", "018e3c4a-...")
      {:ok, %PostGroupAssignment{}}
  """
  def remove_post_from_group(post_id, group_id) do
    case repo().get_by(PostGroupAssignment, post_id: post_id, group_id: group_id) do
      nil ->
        {:error, :not_found}

      assignment ->
        repo().transaction(fn ->
          repo().delete(assignment)

          from(g in PostGroup, where: g.id == ^group_id and g.post_count > 0)
          |> repo().update_all(inc: [post_count: -1])

          assignment
        end)
    end
  end

  @doc """
  Lists user's groups.

  ## Parameters

  - `user_id` - User ID
  - `opts` - Options
    - `:preload` - Associations to preload

  ## Examples

      iex> list_user_groups(42)
      [%PostGroup{}, ...]
  """
  def list_user_groups(user_id, opts \\ [])

  def list_user_groups(user_id, opts) when is_integer(user_id) do
    preloads = Keyword.get(opts, :preload, [])

    from(g in PostGroup, where: g.user_id == ^user_id, order_by: [asc: g.position])
    |> repo().all()
    |> repo().preload(preloads)
  end

  def list_user_groups(user_id, opts) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> list_user_groups(int_id, opts)
      _ -> list_user_groups_by_uuid(user_id, opts)
    end
  end

  defp list_user_groups_by_uuid(user_uuid, opts) do
    preloads = Keyword.get(opts, :preload, [])

    from(g in PostGroup, where: g.user_uuid == ^user_uuid, order_by: [asc: g.position])
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Lists posts in a group.

  ## Parameters

  - `group_id` - Group ID
  - `opts` - Options
    - `:preload` - Associations to preload

  ## Examples

      iex> list_posts_by_group("018e3c4a-...")
      [%Post{}, ...]
  """
  def list_posts_by_group(group_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(p in Post,
      join: ga in PostGroupAssignment,
      on: ga.post_id == p.id,
      where: ga.group_id == ^group_id,
      order_by: [asc: ga.position]
    )
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Reorders user's groups.

  Updates position field for multiple groups.

  ## Parameters

  - `user_id` - User ID
  - `group_id_positions` - Map of group_id => position

  ## Examples

      iex> reorder_groups(42, %{"group1" => 0, "group2" => 1})
      :ok
  """
  def reorder_groups(user_id, group_id_positions) when is_map(group_id_positions) do
    repo().transaction(fn ->
      Enum.each(group_id_positions, fn {group_id, position} ->
        from(g in PostGroup, where: g.id == ^group_id and g.user_id == ^user_id)
        |> repo().update_all(set: [position: position])
      end)
    end)

    :ok
  end

  # ============================================================================
  # Mention Operations
  # ============================================================================

  @doc """
  Adds a mention to a post.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User to mention
  - `mention_type` - "contributor" or "mention" (default: "mention")

  ## Examples

      iex> add_mention_to_post("018e3c4a-...", 42, "contributor")
      {:ok, %PostMention{}}
  """
  def add_mention_to_post(post_id, user_id, mention_type \\ "mention")

  def add_mention_to_post(post_id, user_id, mention_type) when is_integer(user_id) do
    %PostMention{}
    |> PostMention.changeset(%{
      post_id: post_id,
      user_id: user_id,
      user_uuid: resolve_user_uuid(user_id),
      mention_type: mention_type
    })
    |> repo().insert()
  end

  def add_mention_to_post(post_id, user_id, mention_type) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> add_mention_to_post(post_id, int_id, mention_type)
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  Removes a mention from a post.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID

  ## Examples

      iex> remove_mention_from_post("018e3c4a-...", 42)
      {:ok, %PostMention{}}
  """
  def remove_mention_from_post(post_id, user_id) do
    case repo().get_by(PostMention, post_id: post_id, user_id: user_id) do
      nil -> {:error, :not_found}
      mention -> repo().delete(mention)
    end
  end

  @doc """
  Lists mentioned users in a post.

  ## Parameters

  - `post_id` - Post ID
  - `opts` - Options
    - `:preload` - Associations to preload

  ## Examples

      iex> list_post_mentions("018e3c4a-...")
      [%PostMention{}, ...]
  """
  def list_post_mentions(post_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(m in PostMention, where: m.post_id == ^post_id)
    |> repo().all()
    |> repo().preload(preloads)
  end

  # ============================================================================
  # Media Operations
  # ============================================================================

  @doc """
  Attaches media to a post.

  ## Parameters

  - `post_id` - Post ID
  - `file_id` - File ID (from PhoenixKit.Modules.Storage)
  - `opts` - Options
    - `:position` - Display position (default: 1)
    - `:caption` - Image caption

  ## Examples

      iex> attach_media("018e3c4a-...", "018e3c4a-...", position: 1)
      {:ok, %PostMedia{}}
  """
  def attach_media(post_id, file_id, opts \\ []) do
    position = Keyword.get(opts, :position, 1)
    caption = Keyword.get(opts, :caption)

    %PostMedia{}
    |> PostMedia.changeset(%{
      post_id: post_id,
      file_id: file_id,
      position: position,
      caption: caption
    })
    |> repo().insert()
  end

  @doc """
  Detaches media from a post.

  ## Parameters

  - `post_id` - Post ID
  - `file_id` - File ID

  ## Examples

      iex> detach_media("018e3c4a-...", "018e3c4a-...")
      {:ok, %PostMedia{}}
  """
  def detach_media(post_id, file_id) do
    case repo().get_by(PostMedia, post_id: post_id, file_id: file_id) do
      nil -> {:error, :not_found}
      media -> repo().delete(media)
    end
  end

  @doc """
  Detaches media from a post by PostMedia ID.

  ## Parameters

  - `media_id` - PostMedia record ID

  ## Examples

      iex> detach_media_by_id("018e3c4a-...")
      {:ok, %PostMedia{}}
  """
  def detach_media_by_id(media_id) do
    case repo().get(PostMedia, media_id) do
      nil -> {:error, :not_found}
      media -> repo().delete(media)
    end
  end

  @doc """
  Lists media for a post (ordered by position).

  ## Parameters

  - `post_id` - Post ID
  - `opts` - Options
    - `:preload` - Associations to preload

  ## Examples

      iex> list_post_media("018e3c4a-...")
      [%PostMedia{}, ...]
  """
  def list_post_media(post_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:file])

    from(m in PostMedia, where: m.post_id == ^post_id, order_by: [asc: m.position])
    |> repo().all()
    |> repo().preload(preloads)
  end

  @doc """
  Reorders media in a post.

  ## Parameters

  - `post_id` - Post ID
  - `file_id_positions` - Map of file_id => position

  ## Examples

      iex> reorder_media("018e3c4a-...", %{"file1" => 1, "file2" => 2})
      :ok
  """
  def reorder_media(post_id, file_id_positions) when is_map(file_id_positions) do
    repo().transaction(fn ->
      # Two-pass approach to avoid unique constraint violations on (post_id, position)
      # Pass 1: Set all positions to negative values (temporary)
      Enum.each(file_id_positions, fn {file_id, position} ->
        from(m in PostMedia, where: m.post_id == ^post_id and m.file_id == ^file_id)
        |> repo().update_all(set: [position: -position])
      end)

      # Pass 2: Set the correct positive positions
      Enum.each(file_id_positions, fn {file_id, position} ->
        from(m in PostMedia, where: m.post_id == ^post_id and m.file_id == ^file_id)
        |> repo().update_all(set: [position: position])
      end)
    end)

    :ok
  end

  @doc """
  Sets the featured image for a post (PostMedia with position 1).

  Replaces any existing featured image (position 1) with the new one.

  ## Parameters

  - `post_id` - Post ID
  - `file_id` - File ID (from PhoenixKit.Modules.Storage)

  ## Examples

      iex> set_featured_image("018e3c4a-...", "018e3c4a-...")
      {:ok, %PostMedia{position: 1}}
  """
  def set_featured_image(post_id, file_id) do
    repo().transaction(fn ->
      # Remove existing featured image if present
      from(m in PostMedia, where: m.post_id == ^post_id and m.position == 1)
      |> repo().delete_all()

      # Insert new featured image at position 1
      case %PostMedia{}
           |> PostMedia.changeset(%{
             post_id: post_id,
             file_id: file_id,
             position: 1
           })
           |> repo().insert() do
        {:ok, media} -> media
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Gets the featured image for a post (PostMedia with position 1).

  ## Parameters

  - `post_id` - Post ID

  ## Examples

      iex> get_featured_image("018e3c4a-...")
      %PostMedia{position: 1}

      iex> get_featured_image("018e3c4a-...")
      nil
  """
  def get_featured_image(post_id) do
    from(m in PostMedia,
      where: m.post_id == ^post_id and m.position == 1,
      preload: [:file]
    )
    |> repo().one()
  end

  @doc """
  Removes the featured image from a post.

  ## Parameters

  - `post_id` - Post ID

  ## Examples

      iex> remove_featured_image("018e3c4a-...")
      {:ok, 1}

      iex> remove_featured_image("018e3c4a-...")
      {:ok, 0}
  """
  def remove_featured_image(post_id) do
    {count, _} =
      from(m in PostMedia, where: m.post_id == ^post_id and m.position == 1)
      |> repo().delete_all()

    {:ok, count}
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp maybe_filter_by_user(query, nil), do: query

  defp maybe_filter_by_user(query, user_id) when is_integer(user_id) do
    where(query, [p], p.user_id == ^user_id)
  end

  defp maybe_filter_by_user(query, user_id) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {int_id, ""} -> where(query, [p], p.user_id == ^int_id)
      _ -> where(query, [p], p.user_uuid == ^user_id)
    end
  end

  defp maybe_filter_by_status(query, nil), do: query

  defp maybe_filter_by_status(query, status) do
    where(query, [p], p.status == ^status)
  end

  defp maybe_filter_by_type(query, nil), do: query

  defp maybe_filter_by_type(query, type) do
    where(query, [p], p.type == ^type)
  end

  defp maybe_search(query, nil), do: query

  defp maybe_search(query, search_term) do
    search_pattern = "%#{search_term}%"

    where(
      query,
      [p],
      ilike(p.title, ^search_pattern) or ilike(p.content, ^search_pattern)
    )
  end

  defp resolve_user_uuid(user_id) when is_integer(user_id) do
    case repo().one(
           from(u in PhoenixKit.Users.Auth.User, where: u.id == ^user_id, select: u.uuid)
         ) do
      nil -> nil
      uuid -> uuid
    end
  end

  # Get repository based on configuration (for tests and apps with custom repos)
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
