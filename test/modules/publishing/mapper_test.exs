defmodule PhoenixKit.Modules.Publishing.DBStorage.MapperTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.DBStorage.Mapper
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  # ============================================================================
  # Test Data Builders
  # ============================================================================

  defp build_group(attrs \\ %{}) do
    %PublishingGroup{
      uuid: UUIDv7.generate(),
      name: "Blog",
      slug: "blog",
      mode: "slug",
      position: 0,
      data: %{}
    }
    |> Map.merge(attrs)
  end

  defp build_post(group, attrs \\ %{}) do
    %PublishingPost{
      uuid: UUIDv7.generate(),
      group_uuid: group.uuid,
      group: group,
      slug: "hello-world",
      status: "published",
      mode: "slug",
      primary_language: "en",
      published_at: ~U[2025-06-15 14:30:00Z],
      post_date: nil,
      post_time: nil,
      data: %{}
    }
    |> Map.merge(attrs)
  end

  defp build_version(post, attrs \\ %{}) do
    %PublishingVersion{
      uuid: UUIDv7.generate(),
      post_uuid: post.uuid,
      version_number: 1,
      status: "published",
      data: %{},
      inserted_at: ~U[2025-06-15 14:30:00Z]
    }
    |> Map.merge(attrs)
  end

  defp build_content(version, attrs \\ %{}) do
    %PublishingContent{
      uuid: UUIDv7.generate(),
      version_uuid: version.uuid,
      language: "en",
      title: "Hello World",
      content: "# Hello World\n\nThis is the content.",
      status: "published",
      url_slug: nil,
      data: %{}
    }
    |> Map.merge(attrs)
  end

  # ============================================================================
  # to_post_map/5
  # ============================================================================

  describe "to_post_map/5" do
    test "converts DB records to post map format" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.uuid == post.uuid
      assert result.group == "blog"
      assert result.slug == "hello-world"
      assert result.mode == :slug
      assert result.language == "en"
      assert result.version == 1
      assert result.content == content.content
      assert result.primary_language == "en"
    end

    test "builds available_languages from all contents" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en_content = build_content(version, %{language: "en", status: "published"})
      es_content = build_content(version, %{language: "es", status: "draft"})

      result =
        Mapper.to_post_map(post, version, en_content, [en_content, es_content], [version])

      assert result.available_languages == ["en", "es"]
      assert result.language_statuses == %{"en" => "published", "es" => "draft"}
    end

    test "builds version_statuses from all versions" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, status: "archived"})
      v2 = build_version(post, %{version_number: 2, status: "published"})
      content = build_content(v2)

      result = Mapper.to_post_map(post, v2, content, [content], [v1, v2])

      assert result.available_versions == [1, 2]
      assert result.version_statuses == %{1 => "archived", 2 => "published"}
    end

    test "includes date/time for timestamp-mode post" do
      group = build_group()

      post =
        build_post(group, %{
          mode: "timestamp",
          post_date: ~D[2025-06-15],
          post_time: ~T[14:30:00]
        })

      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.mode == :timestamp
      assert result.date == ~D[2025-06-15]
      assert result.time == ~T[14:30:00]
    end

    test "url_slug falls back to post slug when nil" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: nil})

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.url_slug == "hello-world"
    end

    test "url_slug uses content url_slug when set" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: "custom-url"})

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.url_slug == "custom-url"
    end

    test "metadata includes expected fields" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          data: %{
            "description" => "A test post",
            "featured_image_uuid" => "img-123",
            "previous_url_slugs" => ["old-url"]
          }
        })

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.metadata.title == "Hello World"
      assert result.metadata.description == "A test post"
      assert result.metadata.status == "published"
      assert result.metadata.slug == "hello-world"
      assert result.metadata.version == 1
      assert result.metadata.featured_image_uuid == "img-123"
      assert result.metadata.previous_url_slugs == ["old-url"]
      assert result.metadata.published_at == "2025-06-15T14:30:00Z"
      assert result.metadata.primary_language == "en"
    end

    test "builds language_slugs map" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en = build_content(version, %{language: "en", url_slug: "hello"})
      es = build_content(version, %{language: "es", url_slug: "hola"})

      result = Mapper.to_post_map(post, version, en, [en, es], [version])

      assert result.language_slugs == %{"en" => "hello", "es" => "hola"}
    end

    test "builds version_dates from all versions" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, inserted_at: ~U[2025-06-10 10:00:00Z]})
      v2 = build_version(post, %{version_number: 2, inserted_at: ~U[2025-06-15 14:30:00Z]})
      content = build_content(v2)

      result = Mapper.to_post_map(post, v2, content, [content], [v1, v2])

      assert result.version_dates == %{
               1 => "2025-06-10T10:00:00Z",
               2 => "2025-06-15T14:30:00Z"
             }
    end

    test "builds language_previous_slugs from all contents" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      en =
        build_content(version, %{
          language: "en",
          data: %{"previous_url_slugs" => ["old-hello"]}
        })

      es = build_content(version, %{language: "es", data: %{}})

      result = Mapper.to_post_map(post, version, en, [en, es], [version])

      assert result.language_previous_slugs["en"] == ["old-hello"]
      assert result.language_previous_slugs["es"] == []
    end

    test "merges published_language_statuses via opts" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en = build_content(version, %{language: "en", status: "draft"})
      es = build_content(version, %{language: "es", status: "draft"})

      result =
        Mapper.to_post_map(post, version, en, [en, es], [version],
          published_language_statuses: %{"en" => "published"}
        )

      assert result.language_statuses["en"] == "published"
      assert result.language_statuses["es"] == "draft"
    end

    test "group slug is nil when group is not preloaded" do
      group = build_group()

      post =
        build_post(group, %{
          group: %Ecto.Association.NotLoaded{
            __field__: :group,
            __cardinality__: :one,
            __owner__: PublishingPost
          }
        })

      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.group == nil
    end

    test "url_slug falls back to post slug when empty string" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: ""})

      result = Mapper.to_post_map(post, version, content, [content], [version])

      assert result.url_slug == "hello-world"
    end
  end

  # ============================================================================
  # to_listing_map/4
  # ============================================================================

  describe "to_listing_map/4" do
    test "converts post to listing format" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.uuid == post.uuid
      assert result.group == "blog"
      assert result.slug == "hello-world"
      assert result.mode == :slug
    end

    test "uses primary language content for listing" do
      group = build_group()
      post = build_post(group, %{primary_language: "en"})
      version = build_version(post)
      en = build_content(version, %{language: "en", title: "English Title"})
      es = build_content(version, %{language: "es", title: "Titulo"})

      result = Mapper.to_listing_map(post, version, [en, es], [version])

      assert result.metadata.title == "English Title"
      assert result.language == "en"
    end

    test "extracts excerpt from content" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "First paragraph here.\n\n## Section\n\nMore content."
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "First paragraph here."
    end

    test "uses custom excerpt from data when available" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "Full content here",
          data: %{"excerpt" => "Custom excerpt text"}
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "Custom excerpt text"
    end

    test "handles nil content gracefully" do
      group = build_group()
      post = build_post(group, %{primary_language: "en"})
      version = build_version(post)

      result = Mapper.to_listing_map(post, version, [], [version])

      assert result.metadata.title == nil
      assert result.content == nil
    end

    test "falls back to first content when primary language not found" do
      group = build_group()
      post = build_post(group, %{primary_language: "en"})
      version = build_version(post)
      es = build_content(version, %{language: "es", title: "Titulo Espanol"})

      result = Mapper.to_listing_map(post, version, [es], [version])

      assert result.metadata.title == "Titulo Espanol"
    end

    test "uses description as excerpt fallback when no custom excerpt" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "Full content here",
          data: %{"description" => "A meta description"}
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "A meta description"
    end

    test "builds language_titles and language_excerpts" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      en =
        build_content(version, %{
          language: "en",
          title: "Hello",
          data: %{"excerpt" => "EN excerpt"}
        })

      es =
        build_content(version, %{
          language: "es",
          title: "Hola",
          data: %{"excerpt" => "ES excerpt"}
        })

      result = Mapper.to_listing_map(post, version, [en, es], [version])

      assert result.language_titles == %{"en" => "Hello", "es" => "Hola"}
      assert result.language_excerpts == %{"en" => "EN excerpt", "es" => "ES excerpt"}
    end

    test "builds version_dates from all versions" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, inserted_at: ~U[2025-06-10 10:00:00Z]})
      v2 = build_version(post, %{version_number: 2, inserted_at: ~U[2025-06-15 14:30:00Z]})
      content = build_content(v2)

      result = Mapper.to_listing_map(post, v2, [content], [v1, v2])

      assert result.version_dates == %{
               1 => "2025-06-10T10:00:00Z",
               2 => "2025-06-15T14:30:00Z"
             }
    end

    test "url_slug falls back to post slug when content url_slug is nil" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version, %{url_slug: nil})

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.url_slug == "hello-world"
    end

    test "merges published_language_statuses via opts" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      en = build_content(version, %{language: "en", status: "draft"})

      result =
        Mapper.to_listing_map(post, version, [en], [version],
          published_language_statuses: %{"en" => "published"}
        )

      assert result.language_statuses["en"] == "published"
    end

    test "version defaults to 1 when version is nil" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)
      content = build_content(version)

      result = Mapper.to_listing_map(post, nil, [content], [version])

      assert result.version == 1
    end

    test "builds available_versions and version_statuses" do
      group = build_group()
      post = build_post(group)
      v1 = build_version(post, %{version_number: 1, status: "archived"})
      v2 = build_version(post, %{version_number: 2, status: "published"})
      content = build_content(v2)

      result = Mapper.to_listing_map(post, v2, [content], [v1, v2])

      assert result.available_versions == [1, 2]
      assert result.version_statuses == %{1 => "archived", 2 => "published"}
    end

    test "extracts first non-heading paragraph when no excerpt or description" do
      group = build_group()
      post = build_post(group)
      version = build_version(post)

      content =
        build_content(version, %{
          content: "## Heading\n\nActual paragraph here.\n\nMore content.",
          data: %{}
        })

      result = Mapper.to_listing_map(post, version, [content], [version])

      assert result.content == "Actual paragraph here."
    end
  end
end
