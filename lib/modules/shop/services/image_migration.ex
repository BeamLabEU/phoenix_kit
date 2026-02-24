defmodule PhoenixKit.Modules.Shop.Services.ImageMigration do
  @moduledoc """
  Orchestrates batch migration of product images from external URLs to Storage module.

  Provides functions to query migration status, queue migration jobs,
  and migrate individual products.

  ## Usage

      # Get migration statistics
      stats = ImageMigration.migration_stats()
      # => %{total: 100, migrated: 25, pending: 75, failed: 0}

      # Queue all pending products for migration
      {:ok, count} = ImageMigration.queue_all_migrations(user_id)
      # => {:ok, 75}

      # Migrate a single product synchronously
      {:ok, product} = ImageMigration.migrate_product(product_id, user_id)

  """

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Product
  alias PhoenixKit.Modules.Shop.Services.ImageDownloader
  alias PhoenixKit.Modules.Shop.Workers.ImageMigrationWorker

  @doc """
  Returns products that need image migration.

  A product needs migration if it has legacy image URLs but no Storage UUIDs.

  ## Options

    * `:limit` - Maximum number of products to return (default: all)
    * `:offset` - Number of products to skip (default: 0)

  ## Examples

      iex> products_needing_migration()
      [%Product{}, %Product{}, ...]

      iex> products_needing_migration(limit: 10)
      [%Product{}, ...]

  """
  @spec products_needing_migration(keyword()) :: [Product.t()]
  def products_needing_migration(opts \\ []) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from(p in Product,
        # Has legacy images (JSONB array) or featured_image URL
        # No Storage-based images yet
        where:
          (fragment("jsonb_array_length(?) > 0", p.images) or
             (not is_nil(p.featured_image) and p.featured_image != "")) and
            is_nil(p.featured_image_uuid) and
            fragment("COALESCE(array_length(?, 1), 0) = 0", p.image_ids),
        order_by: [asc: p.inserted_at]
      )

    query = if offset > 0, do: offset(query, ^offset), else: query
    query = if limit, do: limit(query, ^limit), else: query

    repo().all(query)
  end

  @doc """
  Returns the count of products needing migration.

  ## Examples

      iex> products_needing_migration_count()
      75

  """
  @spec products_needing_migration_count() :: non_neg_integer()
  def products_needing_migration_count do
    query =
      from(p in Product,
        where:
          (fragment("jsonb_array_length(?) > 0", p.images) or
             (not is_nil(p.featured_image) and p.featured_image != "")) and
            is_nil(p.featured_image_uuid) and
            fragment("COALESCE(array_length(?, 1), 0) = 0", p.image_ids),
        select: count(p.id)
      )

    repo().one(query) || 0
  end

  @doc """
  Returns the count of products that have been migrated.

  ## Examples

      iex> products_migrated_count()
      25

  """
  @spec products_migrated_count() :: non_neg_integer()
  def products_migrated_count do
    query =
      from(p in Product,
        where:
          not is_nil(p.featured_image_uuid) or
            fragment("array_length(?, 1) > 0", p.image_ids),
        select: count(p.id)
      )

    repo().one(query) || 0
  end

  @doc """
  Returns migration statistics.

  ## Returns

  A map with the following keys:
    * `:total` - Total products with any images (legacy or storage)
    * `:migrated` - Products that have storage-based images
    * `:pending` - Products with legacy images but no storage images
    * `:failed` - Count of failed migration jobs (from Oban)
    * `:in_progress` - Count of currently running migration jobs

  ## Examples

      iex> migration_stats()
      %{total: 100, migrated: 25, pending: 75, failed: 0, in_progress: 5}

  """
  @spec migration_stats() :: map()
  def migration_stats do
    pending = products_needing_migration_count()
    migrated = products_migrated_count()
    total = pending + migrated

    # Get job stats from Oban
    {in_progress, failed} = get_oban_job_stats()

    %{
      total: total,
      migrated: migrated,
      pending: pending,
      failed: failed,
      in_progress: in_progress
    }
  end

  defp get_oban_job_stats do
    # Count executing and available jobs
    in_progress_query =
      from(j in Oban.Job,
        where:
          j.worker == "PhoenixKit.Modules.Shop.Workers.ImageMigrationWorker" and
            j.state in ["executing", "available", "scheduled"],
        select: count(j.id)
      )

    # Count failed jobs (not retrying)
    failed_query =
      from(j in Oban.Job,
        where:
          j.worker == "PhoenixKit.Modules.Shop.Workers.ImageMigrationWorker" and
            j.state == "discarded",
        select: count(j.id)
      )

    in_progress = repo().one(in_progress_query) || 0
    failed = repo().one(failed_query) || 0

    {in_progress, failed}
  end

  @doc """
  Queues migration jobs for all products needing migration.

  Creates an Oban job for each product that has legacy images but no storage images.

  ## Options

    * `:limit` - Maximum number of products to queue (default: all)
    * `:priority` - Oban job priority (default: 3)

  ## Returns

    * `{:ok, count}` - Number of jobs queued
    * `{:error, reason}` - If queuing failed

  ## Examples

      iex> queue_all_migrations(user_id)
      {:ok, 75}

      iex> queue_all_migrations(user_id, limit: 10)
      {:ok, 10}

  """
  @spec queue_all_migrations(String.t() | integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def queue_all_migrations(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)
    priority = Keyword.get(opts, :priority, 3)

    products = products_needing_migration(limit: limit)
    count = length(products)

    Logger.info("Queuing image migration for #{count} products")

    jobs =
      Enum.map(products, fn product ->
        ImageMigrationWorker.new(
          %{product_id: product.id, user_id: user_id},
          priority: priority
        )
      end)

    inserted = Oban.insert_all(jobs)
    broadcast_migration_started(count)
    {:ok, length(inserted)}
  end

  @doc """
  Cancels all pending migration jobs.

  ## Returns

    * `{:ok, count}` - Number of jobs cancelled

  """
  @spec cancel_pending_migrations() :: {:ok, non_neg_integer()}
  def cancel_pending_migrations do
    query =
      from(j in Oban.Job,
        where:
          j.worker == "PhoenixKit.Modules.Shop.Workers.ImageMigrationWorker" and
            j.state in ["available", "scheduled"]
      )

    {count, _} = repo().delete_all(query)

    Logger.info("Cancelled #{count} pending migration jobs")
    broadcast_migration_cancelled(count)

    {:ok, count}
  end

  @doc """
  Migrates a single product synchronously.

  Downloads all legacy images and updates the product with storage UUIDs.

  ## Returns

    * `{:ok, product}` - Updated product with storage image IDs
    * `{:error, :already_migrated}` - Product already has storage images
    * `{:error, :no_images}` - Product has no legacy images to migrate
    * `{:error, reason}` - Migration failed

  ## Examples

      iex> migrate_product(product_id, user_id)
      {:ok, %Product{featured_image_id: "uuid-1", image_ids: ["uuid-1", "uuid-2"]}}

  """
  @spec migrate_product(String.t(), String.t() | integer()) ::
          {:ok, Product.t()} | {:error, term()}
  def migrate_product(product_id, user_id) do
    case Shop.get_product(product_id) do
      nil ->
        {:error, :product_not_found}

      product ->
        do_migrate_product(product, user_id)
    end
  end

  defp do_migrate_product(product, user_id) do
    # Check if already migrated
    if has_storage_images?(product) do
      {:error, :already_migrated}
    else
      # Validate product has required fields
      with :ok <- validate_product_for_migration(product) do
        # Collect image URLs
        image_urls = collect_image_urls(product)

        if Enum.empty?(image_urls) do
          {:error, :no_images}
        else
          migrate_images_for_product(product, image_urls, user_id)
        end
      end
    end
  end

  defp validate_product_for_migration(product) do
    cond do
      is_nil(product.title) or product.title == %{} ->
        Logger.warning("Product #{product.id} missing title, skipping migration")
        {:error, :missing_title}

      is_nil(product.slug) or product.slug == %{} ->
        Logger.warning("Product #{product.id} missing slug, skipping migration")
        {:error, :missing_slug}

      true ->
        :ok
    end
  end

  defp has_storage_images?(product) do
    not is_nil(product.featured_image_uuid) or
      (is_list(product.image_ids) and product.image_ids != [])
  end

  defp collect_image_urls(product) do
    urls = []

    # Add featured_image URL if present
    urls =
      if is_binary(product.featured_image) and String.starts_with?(product.featured_image, "http") do
        [product.featured_image | urls]
      else
        urls
      end

    # Add all images from the legacy images array
    legacy_image_urls =
      (product.images || [])
      |> Enum.flat_map(fn
        %{"src" => src} when is_binary(src) -> [src]
        src when is_binary(src) -> [src]
        _ -> []
      end)
      |> Enum.filter(&String.starts_with?(&1, "http"))

    (urls ++ legacy_image_urls) |> Enum.uniq()
  end

  defp migrate_images_for_product(product, image_urls, user_id) do
    # Validate URLs first to skip unavailable images
    {valid_urls, invalid_urls} = ImageDownloader.validate_urls(image_urls)

    if invalid_urls != [] do
      Logger.warning(
        "Product #{product.id}: #{length(invalid_urls)} invalid URLs skipped: #{inspect(invalid_urls)}"
      )
    end

    if valid_urls == [] do
      Logger.warning("Product #{product.id}: All image URLs invalid")
      {:error, :all_urls_invalid}
    else
      Logger.info("Migrating #{length(valid_urls)} valid images for product #{product.id}")

      # Download all images
      results =
        ImageDownloader.download_batch(valid_urls, user_id, concurrency: 3, timeout: 60_000)

      # Build URL -> file_id mapping
      url_to_file_id =
        Enum.reduce(results, %{}, fn
          {url, {:ok, file_id}}, acc ->
            Map.put(acc, url, file_id)

          {url, {:error, reason}}, acc ->
            Logger.warning("Failed to download #{url}: #{inspect(reason)}")
            acc
        end)

      if map_size(url_to_file_id) == 0 do
        {:error, :all_downloads_failed}
      else
        update_product_images(product, url_to_file_id)
      end
    end
  end

  defp update_product_images(product, url_to_file_id) do
    # Map featured_image to featured_image_id
    featured_image_id = Map.get(url_to_file_id, product.featured_image)

    # Map legacy images to image_ids, preserving order from original images array
    image_ids =
      (product.images || [])
      |> Enum.flat_map(fn
        %{"src" => src} -> [src]
        src when is_binary(src) -> [src]
        _ -> []
      end)
      |> Enum.map(&Map.get(url_to_file_id, &1))
      |> Enum.reject(&is_nil/1)

    # Use first image_id as featured if not set
    featured_image_id = featured_image_id || List.first(image_ids)

    # Ensure featured image is first in image_ids (no duplicates)
    image_ids =
      if featured_image_id && featured_image_id in image_ids do
        [featured_image_id | Enum.reject(image_ids, &(&1 == featured_image_id))]
      else
        image_ids
      end

    # Update image mappings in metadata
    metadata = update_image_mappings(product.metadata, url_to_file_id)

    attrs = %{
      featured_image_uuid: featured_image_id,
      image_ids: image_ids,
      metadata: metadata,
      # Clear legacy fields after successful migration
      images: [],
      featured_image: nil
    }

    Shop.update_product(product, attrs)
  end

  defp update_image_mappings(nil, _url_to_file_id), do: nil

  defp update_image_mappings(metadata, url_to_file_id) when is_map(metadata) do
    case Map.get(metadata, "_image_mappings") do
      nil ->
        metadata

      mappings when is_map(mappings) ->
        updated_mappings =
          Enum.reduce(mappings, %{}, fn {option_key, value_map}, acc ->
            updated_value_map =
              Enum.reduce(value_map, %{}, fn {value, image_ref}, inner_acc ->
                new_ref = convert_url_to_file_id(image_ref, url_to_file_id)
                Map.put(inner_acc, value, new_ref)
              end)

            Map.put(acc, option_key, updated_value_map)
          end)

        Map.put(metadata, "_image_mappings", updated_mappings)
    end
  end

  defp update_image_mappings(metadata, _url_to_file_id), do: metadata

  defp convert_url_to_file_id(image_ref, url_to_file_id)
       when is_binary(image_ref) do
    if String.starts_with?(image_ref, "http") do
      Map.get(url_to_file_id, image_ref, image_ref)
    else
      image_ref
    end
  end

  defp convert_url_to_file_id(image_ref, _url_to_file_id), do: image_ref

  # PubSub broadcasts

  defp broadcast_migration_started(count) do
    PhoenixKit.PubSubHelper.broadcast(
      "shop:image_migration:batch",
      {:migration_started, %{total: count}}
    )
  end

  defp broadcast_migration_cancelled(count) do
    PhoenixKit.PubSubHelper.broadcast(
      "shop:image_migration:batch",
      {:migration_cancelled, %{cancelled: count}}
    )
  end

  defp repo do
    PhoenixKit.Config.get_repo()
  end
end
