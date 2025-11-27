defmodule PhoenixKit.Posts do
  @moduledoc """
  Context for managing posts, comments, likes, tags, and groups.

  Provides complete API for the social posts system including CRUD operations,
  counter cache management, comment threading, tag assignment, and group organization.

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
  alias PhoenixKit.Repo
  alias PhoenixKit.RepoHelper

  alias PhoenixKit.Posts.{
    Post,
    PostMedia,
    PostLike,
    PostComment,
    PostMention,
    PostTag,
    PostTagAssignment,
    PostGroup,
    PostGroupAssignment,
    PostView
  }

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
    attrs = Map.put(attrs, :user_id, user_id)

    %Post{}
    |> Post.changeset(attrs)
    |> Repo.insert()
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
    |> Repo.update()
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
    Repo.delete(post)
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
    |> Repo.get!(id)
    |> Repo.preload(preloads)
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
    |> Repo.one()
    |> case do
      nil -> nil
      post -> Repo.preload(post, preloads)
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
    |> Repo.all()
    |> Repo.preload(preloads)
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
  def list_user_posts(user_id, opts \\ []) when is_integer(user_id) do
    opts = Keyword.put(opts, :user_id, user_id)
    list_posts(opts)
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

  ## Parameters

  - `post` - Post to schedule
  - `scheduled_at` - DateTime to publish at (must be in future)

  ## Examples

      iex> schedule_post(post, ~U[2025-12-31 09:00:00Z])
      {:ok, %Post{status: "scheduled"}}
  """
  def schedule_post(%Post{} = post, %DateTime{} = scheduled_at) do
    update_post(post, %{
      status: "scheduled",
      scheduled_at: scheduled_at
    })
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
      [%Post{}, %Post{}]
  """
  def process_scheduled_posts do
    now = DateTime.utc_now()

    from(p in Post,
      where: p.status == "scheduled",
      where: p.scheduled_at <= ^now
    )
    |> Repo.all()
    |> Enum.map(&publish_post/1)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, post} -> post end)
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
    |> Repo.update_all(inc: [like_count: 1])
  end

  @doc """
  Decrements the like counter for a post.

  ## Examples

      iex> decrement_like_count(post)
      {1, nil}
  """
  def decrement_like_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id and p.like_count > 0)
    |> Repo.update_all(inc: [like_count: -1])
  end

  @doc """
  Increments the comment counter for a post.

  ## Examples

      iex> increment_comment_count(post)
      {1, nil}
  """
  def increment_comment_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id)
    |> Repo.update_all(inc: [comment_count: 1])
  end

  @doc """
  Decrements the comment counter for a post.

  ## Examples

      iex> decrement_comment_count(post)
      {1, nil}
  """
  def decrement_comment_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id and p.comment_count > 0)
    |> Repo.update_all(inc: [comment_count: -1])
  end

  @doc """
  Increments the view counter for a post.

  ## Examples

      iex> increment_view_count(post)
      {1, nil}
  """
  def increment_view_count(%Post{id: id}) do
    from(p in Post, where: p.id == ^id)
    |> Repo.update_all(inc: [view_count: 1])
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
  def like_post(post_id, user_id) do
    Repo.transaction(fn ->
      case %PostLike{}
           |> PostLike.changeset(%{post_id: post_id, user_id: user_id})
           |> Repo.insert() do
        {:ok, like} ->
          increment_like_count(%Post{id: post_id})
          like

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
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
  def unlike_post(post_id, user_id) do
    Repo.transaction(fn ->
      case Repo.get_by(PostLike, post_id: post_id, user_id: user_id) do
        nil ->
          Repo.rollback(:not_found)

        like ->
          {:ok, _} = Repo.delete(like)
          decrement_like_count(%Post{id: post_id})
          like
      end
    end)
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
  def post_liked_by?(post_id, user_id) do
    Repo.exists?(from l in PostLike, where: l.post_id == ^post_id and l.user_id == ^user_id)
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
    |> Repo.all()
    |> Repo.preload(preloads)
  end

  # ============================================================================
  # Comment Operations
  # ============================================================================

  @doc """
  Creates a comment on a post.

  Increments the post's comment counter. Automatically calculates depth if replying to another comment.

  ## Parameters

  - `post_id` - Post ID
  - `user_id` - User ID
  - `attrs` - Comment attributes (content, parent_id, etc.)

  ## Examples

      iex> create_comment("018e3c4a-...", 42, %{content: "Great post!"})
      {:ok, %PostComment{}}

      iex> create_comment("018e3c4a-...", 42, %{content: "Reply", parent_id: "..."})
      {:ok, %PostComment{depth: 1}}
  """
  def create_comment(post_id, user_id, attrs) do
    Repo.transaction(fn ->
      attrs =
        attrs
        |> Map.put(:post_id, post_id)
        |> Map.put(:user_id, user_id)
        |> maybe_calculate_depth()

      case %PostComment{}
           |> PostComment.changeset(attrs)
           |> Repo.insert() do
        {:ok, comment} ->
          increment_comment_count(%Post{id: post_id})
          comment

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Updates a comment.

  ## Parameters

  - `comment` - Comment to update
  - `attrs` - Attributes to update

  ## Examples

      iex> update_comment(comment, %{content: "Updated content"})
      {:ok, %PostComment{}}
  """
  def update_comment(%PostComment{} = comment, attrs) do
    comment
    |> PostComment.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a comment.

  Decrements the post's comment counter. Cascades to child comments.

  ## Parameters

  - `comment` - Comment to delete

  ## Examples

      iex> delete_comment(comment)
      {:ok, %PostComment{}}
  """
  def delete_comment(%PostComment{post_id: post_id} = comment) do
    Repo.transaction(fn ->
      case Repo.delete(comment) do
        {:ok, deleted} ->
          decrement_comment_count(%Post{id: post_id})
          deleted

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Gets comment tree for a post (nested structure).

  Returns all comments organized in a tree structure with children nested under parents.

  ## Parameters

  - `post_id` - Post ID

  ## Examples

      iex> get_comment_tree("018e3c4a-...")
      [
        %PostComment{depth: 0, children: [
          %PostComment{depth: 1, children: []}
        ]}
      ]
  """
  def get_comment_tree(post_id) do
    comments =
      from(c in PostComment,
        where: c.post_id == ^post_id,
        order_by: [asc: c.inserted_at],
        preload: [:user]
      )
      |> Repo.all()

    build_comment_tree(comments)
  end

  @doc """
  Lists comments for a post (flat list).

  ## Parameters

  - `post_id` - Post ID
  - `opts` - Options
    - `:preload` - Associations to preload

  ## Examples

      iex> list_post_comments("018e3c4a-...")
      [%PostComment{}, ...]
  """
  def list_post_comments(post_id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    from(c in PostComment, where: c.post_id == ^post_id, order_by: [asc: c.inserted_at])
    |> Repo.all()
    |> Repo.preload(preloads)
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

    case Repo.get_by(PostTag, slug: slug) do
      nil -> Repo.insert(changeset)
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
    Repo.transaction(fn ->
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
        |> Repo.insert(on_conflict: :nothing)

        # Increment tag usage
        from(t in PostTag, where: t.id == ^tag.id)
        |> Repo.update_all(inc: [usage_count: 1])
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
    case Repo.get_by(PostTagAssignment, post_id: post_id, tag_id: tag_id) do
      nil ->
        {:error, :not_found}

      assignment ->
        Repo.transaction(fn ->
          Repo.delete(assignment)

          # Decrement tag usage
          from(t in PostTag, where: t.id == ^tag_id and t.usage_count > 0)
          |> Repo.update_all(inc: [usage_count: -1])

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
    |> Repo.all()
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
    attrs = Map.put(attrs, :user_id, user_id)

    %PostGroup{}
    |> PostGroup.changeset(attrs)
    |> Repo.insert()
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
    |> Repo.update()
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
    Repo.delete(group)
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

    Repo.transaction(fn ->
      case %PostGroupAssignment{}
           |> PostGroupAssignment.changeset(%{
             post_id: post_id,
             group_id: group_id,
             position: position
           })
           |> Repo.insert() do
        {:ok, assignment} ->
          from(g in PostGroup, where: g.id == ^group_id)
          |> Repo.update_all(inc: [post_count: 1])

          assignment

        {:error, changeset} ->
          Repo.rollback(changeset)
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
    case Repo.get_by(PostGroupAssignment, post_id: post_id, group_id: group_id) do
      nil ->
        {:error, :not_found}

      assignment ->
        Repo.transaction(fn ->
          Repo.delete(assignment)

          from(g in PostGroup, where: g.id == ^group_id and g.post_count > 0)
          |> Repo.update_all(inc: [post_count: -1])

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
  def list_user_groups(user_id, opts \\ []) when is_integer(user_id) do
    preloads = Keyword.get(opts, :preload, [])

    from(g in PostGroup, where: g.user_id == ^user_id, order_by: [asc: g.position])
    |> Repo.all()
    |> Repo.preload(preloads)
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
    |> Repo.all()
    |> Repo.preload(preloads)
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
    Repo.transaction(fn ->
      Enum.each(group_id_positions, fn {group_id, position} ->
        from(g in PostGroup, where: g.id == ^group_id and g.user_id == ^user_id)
        |> Repo.update_all(set: [position: position])
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
  def add_mention_to_post(post_id, user_id, mention_type \\ "mention") do
    %PostMention{}
    |> PostMention.changeset(%{
      post_id: post_id,
      user_id: user_id,
      mention_type: mention_type
    })
    |> Repo.insert()
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
    case Repo.get_by(PostMention, post_id: post_id, user_id: user_id) do
      nil -> {:error, :not_found}
      mention -> Repo.delete(mention)
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
    |> Repo.all()
    |> Repo.preload(preloads)
  end

  # ============================================================================
  # Media Operations
  # ============================================================================

  @doc """
  Attaches media to a post.

  ## Parameters

  - `post_id` - Post ID
  - `file_id` - File ID (from PhoenixKit.Storage)
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
    |> Repo.insert()
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
    case Repo.get_by(PostMedia, post_id: post_id, file_id: file_id) do
      nil -> {:error, :not_found}
      media -> Repo.delete(media)
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
    |> Repo.all()
    |> Repo.preload(preloads)
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
    Repo.transaction(fn ->
      Enum.each(file_id_positions, fn {file_id, position} ->
        from(m in PostMedia, where: m.post_id == ^post_id and m.file_id == ^file_id)
        |> Repo.update_all(set: [position: position])
      end)
    end)

    :ok
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp maybe_filter_by_user(query, nil), do: query

  defp maybe_filter_by_user(query, user_id) do
    where(query, [p], p.user_id == ^user_id)
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

  defp maybe_calculate_depth(attrs) do
    case Map.get(attrs, :parent_id) do
      nil ->
        Map.put(attrs, :depth, 0)

      parent_id ->
        case Repo.get(PostComment, parent_id) do
          nil -> Map.put(attrs, :depth, 0)
          parent -> Map.put(attrs, :depth, (parent.depth || 0) + 1)
        end
    end
  end

  defp build_comment_tree(comments) do
    # Build a map of comments by ID for fast lookup
    comment_map = Map.new(comments, &{&1.id, &1})

    # Build tree structure
    comments
    |> Enum.filter(&(&1.parent_id == nil))
    |> Enum.map(&add_children(&1, comment_map))
  end

  defp add_children(comment, comment_map) do
    children =
      comment_map
      |> Map.values()
      |> Enum.filter(&(&1.parent_id == comment.id))
      |> Enum.map(&add_children(&1, comment_map))

    Map.put(comment, :children, children)
  end

  # Get repository based on configuration (for tests and apps with custom repos)
  defp repo do
    RepoHelper.repo()
  end
end
