defmodule PhoenixKit.Migrations.Postgres.V48 do
  @moduledoc """
  V48: Post and Comment Dislikes

  Adds dislike functionality to the blogging module for both posts and comments.

  ## Changes

  - Creates `phoenix_kit_post_dislikes` table for post dislikes
  - Creates `phoenix_kit_comment_likes` table for comment likes
  - Creates `phoenix_kit_comment_dislikes` table for comment dislikes
  - Adds `dislike_count` column to `phoenix_kit_posts`
  - Adds `dislike_count` column to `phoenix_kit_post_comments`

  ## Usage

  Frontend developers can choose to display:
  - Likes only
  - Dislikes only
  - Both likes and dislikes
  - Net score (likes - dislikes)
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    # Create post dislikes table
    create_post_dislikes_table(prefix)

    # Create comment likes table
    create_comment_likes_table(prefix)

    # Create comment dislikes table
    create_comment_dislikes_table(prefix)

    # Add dislike_count to posts
    add_dislike_count_to_posts(prefix)

    # Add dislike_count to comments
    add_dislike_count_to_comments(prefix)

    # Record migration version
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '48'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Remove dislike_count from comments
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_post_comments
    DROP COLUMN IF EXISTS dislike_count
    """

    # Remove dislike_count from posts
    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_posts
    DROP COLUMN IF EXISTS dislike_count
    """

    # Drop comment dislikes table
    drop_if_exists table(:phoenix_kit_comment_dislikes, prefix: prefix)

    # Drop comment likes table
    drop_if_exists table(:phoenix_kit_comment_likes, prefix: prefix)

    # Drop post dislikes table
    drop_if_exists table(:phoenix_kit_post_dislikes, prefix: prefix)

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '47'"
  end

  defp create_post_dislikes_table(prefix) do
    create_if_not_exists table(:phoenix_kit_post_dislikes, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :post_id,
          references(:phoenix_kit_posts, on_delete: :delete_all, prefix: prefix, type: :uuid),
          null: false

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_post_dislikes, [:post_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_post_dislikes, [:user_id], prefix: prefix)

    # Unique constraint: one dislike per user per post
    create_if_not_exists unique_index(:phoenix_kit_post_dislikes, [:post_id, :user_id],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_post_dislikes", prefix)} IS
    'User dislikes on posts (unique per user/post pair)'
    """
  end

  defp create_comment_likes_table(prefix) do
    create_if_not_exists table(:phoenix_kit_comment_likes, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :comment_id,
          references(:phoenix_kit_post_comments,
            on_delete: :delete_all,
            prefix: prefix,
            type: :uuid
          ),
          null: false

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_comment_likes, [:comment_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_comment_likes, [:user_id], prefix: prefix)

    # Unique constraint: one like per user per comment
    create_if_not_exists unique_index(:phoenix_kit_comment_likes, [:comment_id, :user_id],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_comment_likes", prefix)} IS
    'User likes on comments (unique per user/comment pair)'
    """
  end

  defp create_comment_dislikes_table(prefix) do
    create_if_not_exists table(:phoenix_kit_comment_dislikes, primary_key: false, prefix: prefix) do
      add :id, :uuid, primary_key: true

      add :comment_id,
          references(:phoenix_kit_post_comments,
            on_delete: :delete_all,
            prefix: prefix,
            type: :uuid
          ),
          null: false

      add :user_id,
          references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
          null: false

      timestamps(type: :naive_datetime)
    end

    create_if_not_exists index(:phoenix_kit_comment_dislikes, [:comment_id], prefix: prefix)
    create_if_not_exists index(:phoenix_kit_comment_dislikes, [:user_id], prefix: prefix)

    # Unique constraint: one dislike per user per comment
    create_if_not_exists unique_index(:phoenix_kit_comment_dislikes, [:comment_id, :user_id],
                           prefix: prefix
                         )

    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_comment_dislikes", prefix)} IS
    'User dislikes on comments (unique per user/comment pair)'
    """
  end

  defp add_dislike_count_to_posts(prefix) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_posts
    ADD COLUMN IF NOT EXISTS dislike_count INTEGER DEFAULT 0 NOT NULL
    """
  end

  defp add_dislike_count_to_comments(prefix) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    execute """
    ALTER TABLE #{prefix_str}phoenix_kit_post_comments
    ADD COLUMN IF NOT EXISTS dislike_count INTEGER DEFAULT 0 NOT NULL
    """
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
