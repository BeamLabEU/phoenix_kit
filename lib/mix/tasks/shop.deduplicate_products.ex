defmodule Mix.Tasks.Shop.DeduplicateProducts do
  # Ignore Mix.Task behaviour callback info (unavailable in PLT)
  @dialyzer :no_undefined_callbacks

  @moduledoc """
  Finds and merges duplicate products by slug.

  After V47 migration converted slug to JSONB, products can have duplicates
  where multiple records share the same slug value in a specific language.

  This task:
  1. Finds products with duplicate en-US slugs (or default language)
  2. Keeps the product with the lowest ID (oldest)
  3. Merges localized fields from duplicates into the kept product
  4. Updates related cart_items and order_items references
  5. Deletes duplicate products

  ## Usage

      mix shop.deduplicate_products
      mix shop.deduplicate_products --dry-run
      mix shop.deduplicate_products --language es-ES

  ## Options

    * `--dry-run` - Show what would be done without making changes
    * `--language` - Language to check for duplicates (default: en-US)
    * `--verbose` - Show detailed progress

  """

  use Mix.Task

  # Dialyzer can't trace Mix.shell() dynamic module returns
  @dialyzer {:nowarn_function, run: 1}
  @dialyzer {:nowarn_function, find_duplicates: 2}
  @dialyzer {:nowarn_function, process_duplicate_group: 6}
  @dialyzer {:nowarn_function, update_cart_items: 3}
  @dialyzer {:nowarn_function, update_order_items: 3}

  import Ecto.Query

  alias PhoenixKit.Modules.Shop.Product

  @shortdoc "Merge duplicate products by slug"

  @switches [
    dry_run: :boolean,
    language: :string,
    verbose: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)

    dry_run = Keyword.get(opts, :dry_run, false)
    language = Keyword.get(opts, :language, "en-US")
    verbose = Keyword.get(opts, :verbose, false)

    Mix.Task.run("app.start")

    repo = PhoenixKit.RepoHelper.repo()

    if dry_run do
      Mix.shell().info("🔍 DRY RUN MODE - No changes will be made\n")
    end

    Mix.shell().info("Finding duplicate products by slug (language: #{language})...")

    duplicates = find_duplicates(repo, language)

    if Enum.empty?(duplicates) do
      Mix.shell().info("✅ No duplicate products found!")
    else
      Mix.shell().info("Found #{length(duplicates)} duplicate slug groups\n")

      Enum.each(duplicates, fn {slug, ids} ->
        process_duplicate_group(repo, slug, ids, language, dry_run, verbose)
      end)

      if dry_run do
        Mix.shell().info("\n🔍 DRY RUN complete. Run without --dry-run to apply changes.")
      else
        Mix.shell().info("\n✅ Deduplication complete!")
      end
    end
  end

  defp find_duplicates(repo, language) do
    # Find slugs that appear in multiple products
    query = """
    SELECT slug->>$1 as slug_value, array_agg(uuid ORDER BY uuid) as ids
    FROM phoenix_kit_shop_products
    WHERE slug->>$1 IS NOT NULL
    GROUP BY slug->>$1
    HAVING COUNT(*) > 1
    """

    case repo.query(query, [language]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [slug, ids] -> {slug, ids} end)

      {:error, error} ->
        Mix.shell().error("Failed to find duplicates: #{inspect(error)}")
        []
    end
  end

  defp process_duplicate_group(repo, slug, uuids, _language, dry_run, verbose) do
    [keep_uuid | remove_uuids] = uuids

    Mix.shell().info("Processing slug: \"#{slug}\"")
    Mix.shell().info("  Keep: #{keep_uuid}")
    Mix.shell().info("  Remove: #{inspect(remove_uuids)}")

    if verbose do
      # Show product details
      products = repo.all(from(p in Product, where: p.uuid in ^uuids))

      Enum.each(products, fn product ->
        Mix.shell().info("    #{product.uuid}: #{inspect(product.title)}")
      end)
    end

    unless dry_run do
      repo.transaction(fn ->
        # 1. Load all products
        keep_product = repo.get!(Product, keep_uuid)
        remove_products = repo.all(from(p in Product, where: p.uuid in ^remove_uuids))

        # 2. Merge localized fields
        merged_attrs = merge_all_localized_fields(keep_product, remove_products)

        # 3. Update the product we're keeping
        keep_product
        |> Ecto.Changeset.change(merged_attrs)
        |> repo.update!()

        # 4. Update cart_items references
        update_cart_items(repo, keep_uuid, remove_uuids)

        # 5. Update order_items references (if they have product_uuid)
        update_order_items(repo, keep_uuid, remove_uuids)

        # 6. Delete duplicate products
        repo.delete_all(from(p in Product, where: p.uuid in ^remove_uuids))

        Mix.shell().info("  ✅ Merged and removed #{length(remove_uuids)} duplicate(s)")
      end)
    end
  end

  defp merge_all_localized_fields(keep_product, remove_products) do
    localized_fields = [:title, :slug, :description, :body_html, :seo_title, :seo_description]

    Enum.reduce(localized_fields, %{}, fn field, acc ->
      # Start with the keep product's values
      base_map = Map.get(keep_product, field) || %{}

      # Merge in values from each remove product (keep_product values take precedence)
      merged =
        Enum.reduce(remove_products, base_map, fn product, map_acc ->
          product_map = Map.get(product, field) || %{}
          # Map.merge puts second map's values on top, so we put base values last
          Map.merge(product_map, map_acc)
        end)

      if merged != base_map do
        Map.put(acc, field, merged)
      else
        acc
      end
    end)
  end

  defp update_cart_items(repo, keep_uuid, remove_uuids) do
    query = """
    UPDATE phoenix_kit_shop_cart_items
    SET product_uuid = $1
    WHERE product_uuid = ANY($2::uuid[])
    """

    case repo.query(query, [keep_uuid, remove_uuids]) do
      {:ok, %{num_rows: num}} when num > 0 ->
        Mix.shell().info("  Updated #{num} cart item(s)")

      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, error} ->
        Mix.shell().info("  Note: Could not update cart_items: #{inspect(error)}")
    end
  end

  defp update_order_items(repo, keep_uuid, remove_uuids) do
    query = """
    UPDATE phoenix_kit_order_items
    SET product_uuid = $1
    WHERE product_uuid = ANY($2::uuid[])
    """

    case repo.query(query, [keep_uuid, remove_uuids]) do
      {:ok, %{num_rows: num}} when num > 0 ->
        Mix.shell().info("  Updated #{num} order item(s)")

      {:ok, _} ->
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        :ok

      {:error, _error} ->
        # Order items table might not exist or have different structure
        :ok
    end
  end
end
