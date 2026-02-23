defmodule PhoenixKit.Modules.Publishing.SchemaTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  # ============================================================================
  # PublishingGroup
  # ============================================================================

  describe "PublishingGroup" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingGroup)
    end

    test "changeset validates required fields" do
      changeset = PublishingGroup.changeset(%PublishingGroup{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :name)
      # mode has default "timestamp", so it won't be blank
    end

    test "changeset validates mode inclusion" do
      changeset =
        PublishingGroup.changeset(%PublishingGroup{}, %{
          name: "Test",
          slug: "test",
          mode: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :mode)
    end

    test "changeset accepts valid modes" do
      for mode <- ["timestamp", "slug"] do
        changeset =
          PublishingGroup.changeset(%PublishingGroup{}, %{
            name: "Test",
            slug: "test",
            mode: mode
          })

        assert changeset.valid?, "Expected mode '#{mode}' to be valid"
      end
    end

    test "changeset auto-generates slug from name when slug provided" do
      changeset =
        PublishingGroup.changeset(%PublishingGroup{}, %{
          name: "My Blog Group",
          slug: "my-blog-group",
          mode: "slug"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :slug) == "my-blog-group"
    end

    test "data JSONB accessors return defaults" do
      group = %PublishingGroup{data: %{}}

      assert PublishingGroup.get_type(group) == "blogging"
      assert PublishingGroup.get_item_singular(group) == "Post"
      assert PublishingGroup.get_item_plural(group) == "Posts"
      assert PublishingGroup.get_description(group) == nil
      assert PublishingGroup.get_icon(group) == nil
      assert PublishingGroup.comments_enabled?(group) == false
      assert PublishingGroup.likes_enabled?(group) == false
      assert PublishingGroup.views_enabled?(group) == false
    end

    test "data JSONB accessors return custom values" do
      group = %PublishingGroup{
        data: %{
          "type" => "faq",
          "item_singular" => "Question",
          "item_plural" => "Questions",
          "description" => "FAQ section",
          "icon" => "hero-question-mark-circle",
          "comments_enabled" => true,
          "likes_enabled" => true,
          "views_enabled" => true
        }
      }

      assert PublishingGroup.get_type(group) == "faq"
      assert PublishingGroup.get_item_singular(group) == "Question"
      assert PublishingGroup.get_item_plural(group) == "Questions"
      assert PublishingGroup.get_description(group) == "FAQ section"
      assert PublishingGroup.get_icon(group) == "hero-question-mark-circle"
      assert PublishingGroup.comments_enabled?(group) == true
      assert PublishingGroup.likes_enabled?(group) == true
      assert PublishingGroup.views_enabled?(group) == true
    end
  end

  # ============================================================================
  # PublishingPost
  # ============================================================================

  describe "PublishingPost" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingPost)
    end

    test "changeset validates required fields" do
      changeset = PublishingPost.changeset(%PublishingPost{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :group_id)
      assert "can't be blank" in errors_on(changeset, :slug)
      # status, mode, primary_language have schema defaults so they won't be blank
    end

    test "changeset validates status inclusion" do
      changeset =
        PublishingPost.changeset(%PublishingPost{}, %{
          group_id: UUIDv7.generate(),
          slug: "test",
          status: "invalid",
          mode: "slug",
          primary_language: "en"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :status)
    end

    test "changeset accepts valid statuses" do
      for status <- ["draft", "published", "archived", "scheduled"] do
        attrs = %{
          group_id: UUIDv7.generate(),
          slug: "test",
          status: status,
          mode: "slug",
          primary_language: "en"
        }

        attrs =
          if status == "scheduled" do
            Map.put(attrs, :scheduled_at, DateTime.add(DateTime.utc_now(), 3600))
          else
            attrs
          end

        changeset = PublishingPost.changeset(%PublishingPost{}, attrs)

        assert changeset.valid?,
               "Expected status '#{status}' to be valid, got: #{inspect(changeset.errors)}"
      end
    end

    test "changeset requires scheduled_at when status is scheduled" do
      changeset =
        PublishingPost.changeset(%PublishingPost{}, %{
          group_id: UUIDv7.generate(),
          slug: "test",
          status: "scheduled",
          mode: "slug",
          primary_language: "en"
        })

      refute changeset.valid?
      assert "must be set when status is scheduled" in errors_on(changeset, :scheduled_at)
    end

    test "status helpers" do
      published = %PublishingPost{status: "published"}
      draft = %PublishingPost{status: "draft"}
      scheduled = %PublishingPost{status: "scheduled"}
      archived = %PublishingPost{status: "archived"}

      assert PublishingPost.published?(published)
      refute PublishingPost.published?(draft)

      assert PublishingPost.draft?(draft)
      refute PublishingPost.draft?(published)

      assert PublishingPost.scheduled?(scheduled)
      refute PublishingPost.scheduled?(archived)
    end

    test "data JSONB accessors return defaults" do
      post = %PublishingPost{data: %{}}

      assert PublishingPost.allow_version_access?(post) == false
      assert PublishingPost.get_featured_image(post) == nil
      assert PublishingPost.get_tags(post) == []
      assert PublishingPost.get_seo(post) == %{}
    end

    test "data JSONB accessors return custom values" do
      post = %PublishingPost{
        data: %{
          "allow_version_access" => true,
          "featured_image" => "img-uuid-123",
          "tags" => ["elixir", "phoenix"],
          "seo" => %{"og_title" => "My Post"}
        }
      }

      assert PublishingPost.allow_version_access?(post) == true
      assert PublishingPost.get_featured_image(post) == "img-uuid-123"
      assert PublishingPost.get_tags(post) == ["elixir", "phoenix"]
      assert PublishingPost.get_seo(post) == %{"og_title" => "My Post"}
    end
  end

  # ============================================================================
  # PublishingVersion
  # ============================================================================

  describe "PublishingVersion" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingVersion)
    end

    test "changeset validates required fields" do
      changeset = PublishingVersion.changeset(%PublishingVersion{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :post_id)
      assert "can't be blank" in errors_on(changeset, :version_number)
      # status has default "draft"
    end

    test "changeset validates status inclusion" do
      changeset =
        PublishingVersion.changeset(%PublishingVersion{}, %{
          post_id: UUIDv7.generate(),
          version_number: 1,
          status: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :status)
    end

    test "changeset validates version_number > 0" do
      changeset =
        PublishingVersion.changeset(%PublishingVersion{}, %{
          post_id: UUIDv7.generate(),
          version_number: 0,
          status: "draft"
        })

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset, :version_number)
    end

    test "data JSONB accessors" do
      version = %PublishingVersion{data: %{"created_from" => 1, "notes" => "Bug fix"}}

      assert PublishingVersion.get_created_from(version) == 1
      assert PublishingVersion.get_notes(version) == "Bug fix"
    end

    test "data JSONB accessors return nil for empty data" do
      version = %PublishingVersion{data: %{}}

      assert PublishingVersion.get_created_from(version) == nil
      assert PublishingVersion.get_notes(version) == nil
    end
  end

  # ============================================================================
  # PublishingContent
  # ============================================================================

  describe "PublishingContent" do
    test "module is defined and loadable" do
      assert Code.ensure_loaded?(PublishingContent)
    end

    test "changeset validates required fields" do
      changeset = PublishingContent.changeset(%PublishingContent{}, %{})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset, :version_id)
      assert "can't be blank" in errors_on(changeset, :language)
      # title defaults to "" via default_if_nil, so it's not required
      # status has default "draft"
    end

    test "changeset validates status inclusion" do
      changeset =
        PublishingContent.changeset(%PublishingContent{}, %{
          version_id: UUIDv7.generate(),
          language: "en",
          title: "Test",
          status: "invalid"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset, :status)
    end

    test "changeset accepts valid content" do
      changeset =
        PublishingContent.changeset(%PublishingContent{}, %{
          version_id: UUIDv7.generate(),
          language: "en",
          title: "Test Post",
          status: "draft",
          content: "Hello world",
          url_slug: "custom-url"
        })

      assert changeset.valid?
    end

    test "data JSONB accessors return defaults" do
      content = %PublishingContent{data: %{}}

      assert PublishingContent.get_description(content) == nil
      assert PublishingContent.get_previous_url_slugs(content) == []
      assert PublishingContent.get_featured_image_id(content) == nil
      assert PublishingContent.get_seo_title(content) == nil
      assert PublishingContent.get_excerpt(content) == nil
      assert PublishingContent.get_updated_by_uuid(content) == nil
    end

    test "data JSONB accessors return custom values" do
      content = %PublishingContent{
        data: %{
          "description" => "A test post",
          "previous_url_slugs" => ["old-slug"],
          "featured_image_id" => "img-456",
          "seo_title" => "SEO Title",
          "excerpt" => "Custom excerpt",
          "updated_by_uuid" => "uuid-789"
        }
      }

      assert PublishingContent.get_description(content) == "A test post"
      assert PublishingContent.get_previous_url_slugs(content) == ["old-slug"]
      assert PublishingContent.get_featured_image_id(content) == "img-456"
      assert PublishingContent.get_seo_title(content) == "SEO Title"
      assert PublishingContent.get_excerpt(content) == "Custom excerpt"
      assert PublishingContent.get_updated_by_uuid(content) == "uuid-789"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
