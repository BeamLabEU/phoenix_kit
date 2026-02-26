defmodule PhoenixKit.Modules.Shop.Workers.ImageMigrationWorker do
  @moduledoc """
  Oban worker for migrating product images from external URLs to Storage module.

  Processes a single product per job, downloading all legacy images and updating
  the product with Storage UUIDs.

  ## Job Arguments

    * `"product_id"` - The product ID to migrate
    * `"user_id"` - The user ID for ownership of stored files

  ## Queue

  Uses the `shop_imports` queue with max 3 attempts.

  ## Usage

      # Queue a single product for migration
      %{product_id: product_id, user_id: user_id}
      |> ImageMigrationWorker.new()
      |> Oban.insert()

  """

  use Oban.Worker, queue: :shop_imports, max_attempts: 3

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Services.ImageDownloader

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"product_id" => product_id, "user_id" => user_id}}) do
    Logger.info("Starting image migration for product #{product_id}")

    case Shop.get_product(product_id) do
      nil ->
        Logger.warning("Product not found: #{product_id}")
        {:error, :product_not_found}

      product ->
        migrate_product_images(product, user_id)
    end
  end

  defp migrate_product_images(product, user_id) do
    # Use transaction with pessimistic lock to prevent race conditions
    repo = PhoenixKit.Config.get_repo()

    repo.transaction(fn ->
      # Re-fetch product with lock
      locked_product =
        Ecto.Query.from(p in PhoenixKit.Modules.Shop.Product,
          where: p.uuid == ^product.uuid,
          lock: "FOR UPDATE"
        )
        |> repo.one()

      cond do
        is_nil(locked_product) ->
          Logger.warning("Product #{product.uuid} not found during migration")
          {:error, :product_not_found}

        already_migrated?(locked_product) ->
          Logger.info("Product #{product.uuid} already has image_ids, skipping migration")
          :ok

        true ->
          do_migrate_images(locked_product, user_id)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp already_migrated?(product) do
    # Check if product has any storage-based images
    has_featured_image_uuid = not is_nil(product.featured_image_uuid)
    has_image_ids = is_list(product.image_ids) and product.image_ids != []

    has_featured_image_uuid or has_image_ids
  end

  defp do_migrate_images(product, user_id) do
    # Validate product has required fields before migration
    with :ok <- validate_product_for_migration(product) do
      do_migrate_validated_images(product, user_id)
    end
  end

  defp validate_product_for_migration(product) do
    cond do
      is_nil(product.title) or product.title == %{} ->
        Logger.warning("Product #{product.uuid} missing title, skipping migration")
        {:error, :missing_title}

      is_nil(product.slug) or product.slug == %{} ->
        Logger.warning("Product #{product.uuid} missing slug, skipping migration")
        {:error, :missing_slug}

      true ->
        :ok
    end
  end

  defp do_migrate_validated_images(product, user_id) do
    # Collect all unique image URLs from product
    image_urls = collect_image_urls(product)

    if Enum.empty?(image_urls) do
      Logger.info("No legacy images found for product #{product.uuid}")
      :ok
    else
      # Validate URLs first to skip unavailable images
      {valid_urls, invalid_urls} = ImageDownloader.validate_urls(image_urls)

      if invalid_urls != [] do
        Logger.warning(
          "Product #{product.uuid}: #{length(invalid_urls)} invalid URLs skipped: #{inspect(invalid_urls)}"
        )
      end

      if valid_urls == [] do
        Logger.warning("Product #{product.uuid}: All image URLs invalid, marking as failed")
        {:error, :all_urls_invalid}
      else
        Logger.info("Migrating #{length(valid_urls)} valid images for product #{product.uuid}")

        # Download and store all images
        results =
          ImageDownloader.download_batch(valid_urls, user_id,
            concurrency: 3,
            timeout: 60_000,
            on_progress: fn url, result, index, total ->
              broadcast_progress(product.uuid, index, total, url, result)
            end
          )

        # Build URL -> file_id mapping
        url_to_file_id = build_url_mapping(results)

        # Update product with new image IDs, preserving order
        update_product_with_storage_ids(product, url_to_file_id)
      end
    end
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

    # Combine and deduplicate
    (urls ++ legacy_image_urls)
    |> Enum.uniq()
  end

  defp build_url_mapping(results) do
    results
    |> Enum.reduce(%{}, fn
      {url, {:ok, file_id}}, acc ->
        Map.put(acc, url, file_id)

      {url, {:error, reason}}, acc ->
        Logger.warning("Failed to download image #{url}: #{inspect(reason)}")
        acc
    end)
  end

  defp update_product_with_storage_ids(product, url_to_file_id) do
    if map_size(url_to_file_id) == 0 do
      Logger.warning("No images were successfully downloaded for product #{product.uuid}")
      {:error, :no_images_downloaded}
    else
      # Map featured_image to featured_image_uuid
      featured_image_uuid = Map.get(url_to_file_id, product.featured_image)

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

      # If no featured_image_uuid but we have image_ids, use the first one
      featured_image_uuid = featured_image_uuid || List.first(image_ids)

      # Ensure featured image is first in image_ids (no duplicates)
      image_ids =
        if featured_image_uuid && featured_image_uuid in image_ids do
          [featured_image_uuid | Enum.reject(image_ids, &(&1 == featured_image_uuid))]
        else
          image_ids
        end

      # Update variant image mappings in metadata if present
      metadata = update_image_mappings(product.metadata, url_to_file_id)

      attrs = %{
        featured_image_uuid: featured_image_uuid,
        image_ids: image_ids,
        metadata: metadata,
        # Clear legacy fields after successful migration
        images: [],
        featured_image: nil
      }

      case Shop.update_product(product, attrs) do
        {:ok, updated_product} ->
          Logger.info(
            "Successfully migrated images for product #{product.uuid}: " <>
              "featured_image_uuid=#{featured_image_uuid}, image_ids=#{length(image_ids)}"
          )

          broadcast_complete(product.uuid, length(image_ids))
          {:ok, updated_product}

        {:error, changeset} ->
          Logger.error("Failed to update product #{product.uuid}: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end
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

  # PubSub broadcasts for progress tracking

  defp broadcast_progress(product_id, index, total, url, result) do
    status = if match?({:ok, _}, result), do: :success, else: :failed

    PhoenixKit.PubSubHelper.broadcast(
      "shop:image_migration:#{product_id}",
      {:image_progress,
       %{
         product_id: product_id,
         current: index,
         total: total,
         url: url,
         status: status
       }}
    )
  end

  defp broadcast_complete(product_id, image_count) do
    PhoenixKit.PubSubHelper.broadcast(
      "shop:image_migration:#{product_id}",
      {:migration_complete,
       %{
         product_id: product_id,
         images_migrated: image_count
       }}
    )

    # Also broadcast to the batch migration topic
    PhoenixKit.PubSubHelper.broadcast(
      "shop:image_migration:batch",
      {:product_migrated, %{product_id: product_id, images_migrated: image_count}}
    )
  end
end
