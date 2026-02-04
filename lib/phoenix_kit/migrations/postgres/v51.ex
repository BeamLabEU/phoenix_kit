defmodule PhoenixKit.Migrations.Postgres.V51 do
  @moduledoc """
  V51: Fix cart items unique constraint to include selected_specs

  The original constraint only checked (cart_id, product_id), preventing
  users from adding the same product with different options to their cart.

  New constraint uses MD5 hash of selected_specs JSONB for efficient
  unique checking across all option combinations.

  ## Changes

  - Drops existing idx_shop_cart_items_unique index
  - Creates new unique index including MD5 hash of selected_specs
  - Enables same product with different specs in cart (e.g., different sizes)
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Drop old index that doesn't include selected_specs
    execute """
    DROP INDEX IF EXISTS #{prefix_str}idx_shop_cart_items_unique
    """

    # Create new index that includes selected_specs via MD5 hash
    # MD5 provides consistent hashing of JSONB for unique comparison
    execute """
    CREATE UNIQUE INDEX idx_shop_cart_items_unique
    ON #{prefix_str}phoenix_kit_shop_cart_items(
      cart_id,
      product_id,
      MD5(COALESCE(selected_specs::text, '{}'))
    )
    WHERE variant_id IS NULL
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '51'"
  end

  def down(%{prefix: prefix} = _opts) do
    prefix_str = if prefix && prefix != "public", do: "#{prefix}.", else: ""

    # Restore original index (will fail if duplicate cart_id+product_id exist)
    execute """
    DROP INDEX IF EXISTS #{prefix_str}idx_shop_cart_items_unique
    """

    execute """
    CREATE UNIQUE INDEX idx_shop_cart_items_unique
    ON #{prefix_str}phoenix_kit_shop_cart_items(cart_id, product_id)
    WHERE variant_id IS NULL
    """

    # Record migration version
    execute "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '50'"
  end
end
