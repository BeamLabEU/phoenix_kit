defmodule PhoenixKit.Modules.Publishing.Web.Editor.FormsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Editor.Forms

  # ============================================================================
  # Helper to build a minimal socket with assigns for testing
  # ============================================================================

  defp build_socket(overrides) do
    defaults = %{
      form: %{"title" => "", "slug" => "", "url_slug" => "", "status" => "draft"},
      post: %{slug: "", uuid: nil, metadata: %{status: "draft"}},
      group_slug: "blog",
      group_mode: "slug",
      is_primary_language: true,
      slug_manually_set: false,
      last_auto_slug: "",
      url_slug_manually_set: false,
      last_auto_url_slug: ""
    }

    merged = Map.merge(defaults, overrides)
    # Override form fully if provided
    merged =
      if overrides[:form],
        do: %{merged | form: Map.merge(defaults.form, overrides.form)},
        else: merged

    # Build a proper Phoenix.LiveView.Socket with assigns
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(merged)
  end

  # ============================================================================
  # maybe_update_slug_from_title/3
  # ============================================================================

  describe "maybe_update_slug_from_title/3" do
    test "generates slug from title for primary language" do
      socket = build_socket(%{group_mode: "slug", is_primary_language: true})
      {_socket, form, events} = Forms.maybe_update_slug_from_title(socket, "Hello World")

      assert form["slug"] == "hello-world"
      assert [{"update-slug", %{slug: "hello-world"}}] = events
    end

    test "returns no update for empty title" do
      socket = build_socket(%{group_mode: "slug"})
      {_socket, form, events} = Forms.maybe_update_slug_from_title(socket, "")

      assert form["slug"] == ""
      assert events == []
    end

    test "returns no update for nil title" do
      socket = build_socket(%{group_mode: "slug"})
      {_socket, _form, events} = Forms.maybe_update_slug_from_title(socket, nil)

      assert events == []
    end

    test "returns no update for timestamp mode" do
      socket = build_socket(%{group_mode: "timestamp"})
      {_socket, _form, events} = Forms.maybe_update_slug_from_title(socket, "Hello World")

      assert events == []
    end

    test "respects slug_manually_set flag" do
      socket = build_socket(%{slug_manually_set: true, form: %{"slug" => "custom-slug"}})
      {_socket, form, events} = Forms.maybe_update_slug_from_title(socket, "Different Title")

      assert form["slug"] == "custom-slug"
      assert events == []
    end

    test "overrides slug when force option is set" do
      socket = build_socket(%{slug_manually_set: true, form: %{"slug" => "custom-slug"}})

      {_socket, form, events} =
        Forms.maybe_update_slug_from_title(socket, "New Title", force: true)

      assert form["slug"] == "new-title"
      assert [{"update-slug", _}] = events
    end

    test "generates url_slug for translation language" do
      socket = build_socket(%{is_primary_language: false, form: %{"url_slug" => ""}})
      {_socket, form, events} = Forms.maybe_update_slug_from_title(socket, "Translated Title")

      assert form["url_slug"] == "translated-title"
      assert [{"update-url-slug", %{url_slug: "translated-title"}}] = events
    end

    test "respects url_slug_manually_set for translations" do
      socket =
        build_socket(%{
          is_primary_language: false,
          url_slug_manually_set: true,
          form: %{"url_slug" => "custom-url"}
        })

      {_socket, form, events} = Forms.maybe_update_slug_from_title(socket, "Other Title")

      assert form["url_slug"] == "custom-url"
      assert events == []
    end

    test "no update when slug already matches" do
      socket = build_socket(%{form: %{"slug" => "hello-world"}})
      {_socket, _form, events} = Forms.maybe_update_slug_from_title(socket, "Hello World")

      assert events == []
    end
  end

  # ============================================================================
  # assign_form_with_tracking/3
  # ============================================================================

  describe "assign_form_with_tracking/3" do
    test "assigns slug tracking state" do
      socket = build_socket(%{})
      form = %{"title" => "Test", "slug" => "test", "status" => "draft"}

      result = Forms.assign_form_with_tracking(socket, form)

      assert result.assigns.form == form
      assert result.assigns.slug_manually_set == false
      assert result.assigns.last_auto_slug == "test"
    end

    test "does not assign title_manually_set (removed)" do
      socket = build_socket(%{})
      form = %{"title" => "Test", "slug" => "test", "status" => "draft"}

      result = Forms.assign_form_with_tracking(socket, form)

      refute Map.has_key?(result.assigns, :title_manually_set)
      refute Map.has_key?(result.assigns, :last_auto_title)
    end
  end

  # ============================================================================
  # Form Building
  # ============================================================================

  describe "post_form/1" do
    test "builds form with title from metadata" do
      post = %{
        metadata: %{
          title: "My Post",
          status: "draft",
          published_at: nil,
          featured_image_uuid: nil,
          url_slug: nil
        },
        slug: "my-post",
        mode: :slug,
        content: "# My Post\nContent here",
        url_slug: nil
      }

      form = Forms.post_form(post)

      assert form["title"] == "My Post"
      assert form["slug"] == "my-post"
      assert form["status"] == "draft"
    end

    test "returns empty title for Untitled posts" do
      post = %{
        metadata: %{
          title: "Untitled",
          status: "draft",
          published_at: nil,
          featured_image_uuid: nil,
          url_slug: nil
        },
        slug: nil,
        mode: "timestamp",
        content: "",
        url_slug: nil
      }

      form = Forms.post_form(post)
      assert form["title"] == ""
    end
  end

  # ============================================================================
  # dirty?/3
  # ============================================================================

  describe "dirty?/3" do
    test "detects title change as dirty" do
      post = %{
        metadata: %{
          title: "Original",
          status: "draft",
          published_at: nil,
          featured_image_uuid: nil,
          url_slug: nil
        },
        slug: "original",
        mode: "slug",
        content: "content",
        url_slug: nil
      }

      form = Forms.post_form(post)
      modified_form = Map.put(form, "title", "Changed Title")

      assert Forms.dirty?(post, modified_form, "content")
    end

    test "detects content change as dirty" do
      post = %{
        metadata: %{
          title: "Title",
          status: "draft",
          published_at: nil,
          featured_image_uuid: nil,
          url_slug: nil
        },
        slug: "title",
        mode: "slug",
        content: "original content",
        url_slug: nil
      }

      form = Forms.post_form(post)
      assert Forms.dirty?(post, form, "new content")
    end
  end

  # ============================================================================
  # push_slug_events/2
  # ============================================================================

  describe "push_slug_events/2" do
    test "pushes no events for empty list" do
      socket = build_socket(%{})
      result = Forms.push_slug_events(socket, [])
      # No crash = success; events are pushed via Phoenix.LiveView.push_event
      assert result
    end
  end
end
