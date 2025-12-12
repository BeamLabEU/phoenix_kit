defmodule PhoenixKitWeb.Live.Modules.Posts.Edit do
  @moduledoc """
  LiveView for creating and editing posts.

  Provides a comprehensive post editor with:
  - Basic post fields (title, subtitle, content, type, status)
  - Tag and mention management
  - Group assignment
  - Scheduled publishing
  - SEO slug generation

  ## Route

  - New post: `{prefix}/admin/posts/new`
  - Edit post: `{prefix}/admin/posts/:id/edit`

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
  """

  use PhoenixKitWeb, :live_view

  alias Phoenix.Component
  alias PhoenixKit.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    # Get current user
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get project title
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Determine if this is a new post or editing existing
    post_id = Map.get(params, "id")

    socket =
      if post_id do
        # Editing existing post
        case Posts.get_post!(post_id, preload: [:user, :media, :tags, :groups, :mentions]) do
          nil ->
            socket
            |> put_flash(:error, "Post not found")
            |> push_navigate(to: Routes.path("/admin/posts"))

          post ->
            # Check if user owns this post or is admin
            if can_edit_post?(current_user, post) do
              content = post.content || ""

              form_data = %{
                "title" => post.title || "",
                "sub_title" => post.sub_title || "",
                "type" => post.type || "post",
                "status" => post.status || "draft",
                "slug" => post.slug || "",
                "scheduled_at" => format_datetime_local(post.scheduled_at, current_user)
              }

              form = Component.to_form(form_data, as: :post)

              socket
              |> assign(:page_title, "Edit Post")
              |> assign(:project_title, project_title)
              |> assign(:post, post)
              |> assign(:form, form)
              |> assign(:content, content)
              |> assign(:current_user, current_user)
              |> load_form_data()
            else
              socket
              |> put_flash(:error, "You don't have permission to edit this post")
              |> push_navigate(to: Routes.path("/admin/posts"))
            end
        end
      else
        # Creating new post
        form_data = %{
          "title" => "",
          "sub_title" => "",
          "type" => "post",
          "status" => Settings.get_setting("posts_default_status", "draft"),
          "slug" => ""
        }

        form = Component.to_form(form_data, as: :post)

        socket
        |> assign(:page_title, "New Post")
        |> assign(:project_title, project_title)
        |> assign(:post, %{id: nil, user_id: current_user.id})
        |> assign(:form, form)
        |> assign(:content, "")
        |> assign(:current_user, current_user)
        |> load_form_data()
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"post" => post_params}, socket) do
    form = Component.to_form(post_params, as: :post)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"post" => post_params}, socket) do
    # Merge content from assigns (stored separately from form)
    content = socket.assigns.content
    post_params = Map.put(post_params, "content", content)

    # Parse tags from content if auto-tagging is enabled
    tags = Posts.parse_hashtags(content)

    # Generate slug if auto-slug is enabled and slug is empty
    post_params = maybe_generate_slug(post_params)

    # Get post_id - handle both struct and map cases
    post_id = Map.get(socket.assigns.post, :id)

    save_post(socket, post_id, post_params, tags)
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/posts"))}
  end

  @impl true
  def handle_event("add_tag", %{"tag" => tag_name}, socket) do
    if tag_name != "" do
      current_tags = socket.assigns.selected_tags
      max_tags = String.to_integer(Settings.get_setting("posts_max_tags", "20"))

      if length(current_tags) < max_tags and tag_name not in current_tags do
        {:noreply, assign(socket, :selected_tags, [tag_name | current_tags])}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_tag", %{"tag" => tag_name}, socket) do
    current_tags = Enum.reject(socket.assigns.selected_tags, &(&1 == tag_name))
    {:noreply, assign(socket, :selected_tags, current_tags)}
  end

  @impl true
  def handle_event("open_featured_image_selector", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:selecting_featured_image, true)
     |> assign(:media_selector_mode, :multiple)}
  end

  @impl true
  def handle_event("remove_post_image", %{"id" => media_id}, socket) do
    post_id = Map.get(socket.assigns.post, :id)

    if post_id do
      # Existing post - remove from database
      Posts.detach_media_by_id(media_id)
      post_images = Posts.list_post_media(post_id, preload: [:file])
      {:noreply, assign(socket, :post_images, post_images)}
    else
      # New post - remove from temporary list
      post_images =
        Enum.reject(socket.assigns.post_images, fn img ->
          to_string(img.file_id) == media_id || to_string(img[:id]) == media_id
        end)

      pending_ids = Enum.reject(socket.assigns[:pending_image_ids] || [], &(&1 == media_id))

      {:noreply,
       socket |> assign(:post_images, post_images) |> assign(:pending_image_ids, pending_ids)}
    end
  end

  @impl true
  def handle_event("reorder_post_images", %{"ordered_ids" => ordered_ids}, socket) do
    post_id = Map.get(socket.assigns.post, :id)

    if post_id do
      # Existing post - update positions in database
      positions =
        ordered_ids
        |> Enum.with_index(1)
        |> Map.new(fn {file_id, position} -> {file_id, position} end)

      Posts.reorder_media(post_id, positions)

      # Reload images to reflect new order
      post_images = Posts.list_post_media(post_id, preload: [:file])
      {:noreply, assign(socket, :post_images, post_images)}
    else
      # New post - reorder in memory
      reordered =
        ordered_ids
        |> Enum.with_index(1)
        |> Enum.map(fn {file_id, position} ->
          img = Enum.find(socket.assigns.post_images, &(to_string(&1.file_id) == file_id))
          %{img | position: position}
        end)
        |> Enum.reject(&is_nil/1)

      {:noreply, assign(socket, :post_images, reordered)}
    end
  end

  # Handle content changes from MarkdownEditor component
  @impl true
  def handle_info(
        {:editor_content_changed, %{content: content, editor_id: "post-content-editor"}},
        socket
      ) do
    # Store content as a separate assign (like blogging editor does)
    {:noreply, assign(socket, :content, content)}
  end

  # Handle image/video insert from MarkdownEditor toolbar
  def handle_info({:editor_insert_component, %{type: type}}, socket)
      when type in [:image, :video] do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:inserting_media_type, type)
     |> assign(:media_selector_mode, :multiple)}
  end

  # Handle media selection from MediaSelectorModal
  def handle_info({:media_selected, file_ids}, socket) do
    socket =
      cond do
        # Post images selection (supports multiple files)
        length(file_ids) > 0 && socket.assigns.selecting_featured_image ->
          post_id = Map.get(socket.assigns.post, :id)

          if post_id do
            # Existing post - save all selected images to database
            # Get current max position
            current_images = socket.assigns.post_images

            max_position =
              Enum.reduce(current_images, 0, fn img, acc -> max(acc, img.position) end)

            # Add new images with incremental positions
            file_ids
            |> Enum.with_index(max_position + 1)
            |> Enum.each(fn {file_id, position} ->
              Posts.attach_media(post_id, file_id, position: position)
            end)

            # Reload all images
            post_images = Posts.list_post_media(post_id, preload: [:file])

            socket
            |> assign(:post_images, post_images)
            |> assign(:show_media_selector, false)
            |> assign(:selecting_featured_image, false)
          else
            # New post - store file_ids temporarily until post is saved
            # Create temporary structs for display
            current_images = socket.assigns[:post_images] || []

            max_position =
              Enum.reduce(current_images, 0, fn img, acc -> max(acc, img.position) end)

            new_images =
              file_ids
              |> Enum.with_index(max_position + 1)
              |> Enum.map(fn {file_id, position} ->
                %{file_id: file_id, file: nil, position: position, id: nil}
              end)

            socket
            |> assign(:post_images, current_images ++ new_images)
            |> assign(:pending_image_ids, (socket.assigns[:pending_image_ids] || []) ++ file_ids)
            |> assign(:show_media_selector, false)
            |> assign(:selecting_featured_image, false)
          end

        # Content image insertion (supports multiple files)
        length(file_ids) > 0 && socket.assigns.inserting_media_type ->
          media_type = socket.assigns.inserting_media_type

          # Build JS commands for all selected files
          js_code =
            file_ids
            |> Enum.map_join("; ", fn fid ->
              file_url = get_file_url(fid)

              "window.postsEditorInsertMedia && window.postsEditorInsertMedia('#{file_url}', '#{media_type}')"
            end)

          socket
          |> assign(:show_media_selector, false)
          |> assign(:inserting_media_type, nil)
          |> push_event("exec-js", %{js: js_code})

        true ->
          assign(socket, :show_media_selector, false)
      end

    {:noreply, socket}
  end

  # Handle media selector modal closed
  def handle_info({:media_selector_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> assign(:inserting_media_type, nil)
     |> assign(:selecting_featured_image, false)}
  end

  # Catch-all for other editor events
  def handle_info({:editor_insert_component, _}, socket), do: {:noreply, socket}
  def handle_info({:editor_save_requested, _}, socket), do: {:noreply, socket}

  ## --- Private Helper Functions ---

  # Get a URL for a file from storage (for standard markdown image syntax)
  defp get_file_url(file_id) do
    alias PhoenixKit.Modules.Storage.URLSigner

    # Use "original" variant for the full-size image
    URLSigner.signed_url(file_id, "original")
  end

  # Get URL for featured image (used in template)
  def get_featured_image_url(nil), do: nil

  def get_featured_image_url(%{file: %{id: file_id}}) when not is_nil(file_id) do
    get_file_url(file_id)
  end

  def get_featured_image_url(%{file_id: file_id}) when not is_nil(file_id) do
    get_file_url(file_id)
  end

  def get_featured_image_url(_), do: nil

  defp save_post(socket, nil, post_params, tags) do
    # Convert scheduled_at from user's local time to UTC
    post_params = convert_scheduled_at_to_utc(post_params, socket.assigns.current_user)

    # Creating new post
    case Posts.create_post(socket.assigns.current_user.id, post_params) do
      {:ok, post} ->
        # Handle tags
        if tags != [] do
          Posts.add_tags_to_post(post, tags)
        end

        # Handle pending images (set during new post creation)
        pending_ids = socket.assigns[:pending_image_ids] || []

        pending_ids
        |> Enum.with_index(1)
        |> Enum.each(fn {file_id, position} ->
          Posts.attach_media(post.id, file_id, position: position)
        end)

        {:noreply,
         socket
         |> put_flash(:info, "Post created successfully")
         |> push_navigate(to: Routes.path("/admin/posts/#{post.id}"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create post")
         |> assign(:form, Component.to_form(post_params, as: :post))}
    end
  end

  defp save_post(socket, _post_id, post_params, tags) do
    # Convert scheduled_at from user's local time to UTC
    post_params = convert_scheduled_at_to_utc(post_params, socket.assigns.current_user)

    # Updating existing post
    case Posts.update_post(socket.assigns.post, post_params) do
      {:ok, post} ->
        # Handle tags
        if tags != [] do
          Posts.add_tags_to_post(post, tags)
        end

        {:noreply,
         socket
         |> put_flash(:info, "Post updated successfully")
         |> push_navigate(to: Routes.path("/admin/posts/#{post.id}"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update post")
         |> assign(:form, Component.to_form(post_params, as: :post))}
    end
  end

  defp load_form_data(socket) do
    # Load user's groups for selection
    user_groups = Posts.list_user_groups(socket.assigns.current_user.id)

    # Load existing tags if editing
    selected_tags =
      if Map.get(socket.assigns.post, :id) do
        Enum.map(Map.get(socket.assigns.post, :tags, []) || [], & &1.name)
      else
        []
      end

    # Load existing groups if editing
    selected_groups =
      if Map.get(socket.assigns.post, :id) do
        Enum.map(Map.get(socket.assigns.post, :groups, []) || [], & &1.id)
      else
        []
      end

    # Load settings
    max_media = String.to_integer(Settings.get_setting("posts_max_media", "10"))
    max_title_length = String.to_integer(Settings.get_setting("posts_max_title_length", "255"))

    max_subtitle_length =
      String.to_integer(Settings.get_setting("posts_max_subtitle_length", "500"))

    max_content_length =
      String.to_integer(Settings.get_setting("posts_max_content_length", "50000"))

    max_tags = String.to_integer(Settings.get_setting("posts_max_tags", "20"))
    default_status = Settings.get_setting("posts_default_status", "draft")
    allow_scheduling = Settings.get_setting("posts_allow_scheduling", "true") == "true"
    allow_groups = Settings.get_setting("posts_allow_groups", "true") == "true"
    seo_auto_slug = Settings.get_setting("posts_seo_auto_slug", "true") == "true"

    socket
    |> assign(:user_groups, user_groups)
    |> assign(:selected_tags, selected_tags)
    |> assign(:selected_groups, selected_groups)
    |> assign(:max_media, max_media)
    |> assign(:max_title_length, max_title_length)
    |> assign(:max_subtitle_length, max_subtitle_length)
    |> assign(:max_content_length, max_content_length)
    |> assign(:max_tags, max_tags)
    |> assign(:default_status, default_status)
    |> assign(:allow_scheduling, allow_scheduling)
    |> assign(:allow_groups, allow_groups)
    |> assign(:seo_auto_slug, seo_auto_slug)
    |> assign(:show_media_selector, false)
    |> assign(:inserting_media_type, nil)
    |> assign(:selecting_featured_image, false)
    |> assign(:media_selector_mode, :single)
    |> load_post_images()
  end

  defp load_post_images(socket) do
    post_id = Map.get(socket.assigns.post, :id)

    post_images =
      if post_id do
        Posts.list_post_media(post_id, preload: [:file])
      else
        []
      end

    assign(socket, :post_images, post_images)
  end

  defp can_edit_post?(user, post) do
    # User can edit if they own the post or are admin/owner
    Map.get(post, :user_id) == user.id or user_is_admin?(user)
  end

  defp user_is_admin?(user) do
    # Check if user has admin or owner role
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end

  defp maybe_generate_slug(post_params) do
    seo_auto_slug = Settings.get_setting("posts_seo_auto_slug", "true") == "true"
    slug = Map.get(post_params, "slug", "")
    title = Map.get(post_params, "title", "")

    if seo_auto_slug and (slug == "" or is_nil(slug)) and title != "" do
      # Generate slug from title
      generated_slug =
        title
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s-]/, "")
        |> String.replace(~r/\s+/, "-")
        |> String.replace(~r/-+/, "-")
        |> String.trim("-")

      Map.put(post_params, "slug", generated_slug)
    else
      post_params
    end
  end

  # Format datetime for HTML datetime-local input (YYYY-MM-DDTHH:MM)
  # Converts from UTC to user's local timezone for display
  defp format_datetime_local(nil, _user), do: nil

  defp format_datetime_local(%DateTime{} = dt, user) do
    # Shift from UTC to user's timezone for display
    local_dt = shift_to_user_timezone(dt, user)
    Calendar.strftime(local_dt, "%Y-%m-%dT%H:%M")
  end

  defp format_datetime_local(%NaiveDateTime{} = dt, user) do
    utc_dt = DateTime.from_naive!(dt, "Etc/UTC")
    format_datetime_local(utc_dt, user)
  end

  defp format_datetime_local(_, _user), do: nil

  # Convert scheduled_at from user's local time to UTC when saving
  defp convert_scheduled_at_to_utc(post_params, user) do
    case Map.get(post_params, "scheduled_at") do
      nil ->
        post_params

      "" ->
        post_params

      local_time_str when is_binary(local_time_str) ->
        # datetime-local gives us "YYYY-MM-DDTHH:MM", need to add seconds
        case NaiveDateTime.from_iso8601(local_time_str <> ":00") do
          {:ok, naive_dt} ->
            utc_dt = shift_from_user_timezone(naive_dt, user)
            Map.put(post_params, "scheduled_at", utc_dt)

          _ ->
            post_params
        end

      _ ->
        # Already a DateTime, pass through
        post_params
    end
  end

  # Shift datetime from user's local timezone to UTC
  defp shift_from_user_timezone(naive_dt, user) do
    offset_str = (user && user.user_timezone) || "0"

    case Integer.parse(offset_str) do
      {offset_hours, _} ->
        # Convert to UTC by subtracting the offset (local - offset = UTC)
        utc_naive = NaiveDateTime.add(naive_dt, -offset_hours * 3600, :second)
        DateTime.from_naive!(utc_naive, "Etc/UTC")

      _ ->
        DateTime.from_naive!(naive_dt, "Etc/UTC")
    end
  end

  # Shift datetime from UTC to user's local timezone
  defp shift_to_user_timezone(datetime, user) do
    offset_str = (user && user.user_timezone) || "0"

    case Integer.parse(offset_str) do
      {offset_hours, _} ->
        # Convert from UTC to local by adding the offset
        DateTime.add(datetime, offset_hours * 3600, :second)

      _ ->
        datetime
    end
  end
end
