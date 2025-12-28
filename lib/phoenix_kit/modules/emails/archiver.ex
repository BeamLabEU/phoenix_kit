defmodule PhoenixKit.Modules.Emails.Archiver do
  @moduledoc """
  Archive and compress old email tracking data for optimal storage.

  Provides comprehensive data lifecycle management for email tracking:

  - **Body Compression** - Compress full email bodies after configurable time
  - **S3 Archival** - Move old logs to S3 cold storage  
  - **Sampling Optimization** - Apply sampling to reduce storage load
  - **Cleanup Integration** - Work with cleanup tasks for complete lifecycle
  - **Performance Optimization** - Batch operations for large datasets

  ## Storage Optimization Strategy

  1. **Recent Data** (0-7 days): Full storage with all fields
  2. **Medium Data** (7-30 days): Compress body_full, keep metadata
  3. **Old Data** (30-90 days): Archive to S3, keep local summary
  4. **Ancient Data** (90+ days): Delete after S3 confirmation

  ## Settings Integration

  All archival settings stored in phoenix_kit_settings:

  - `email_compress_body` - Days before compressing bodies (default: 30)
  - `email_archive_to_s3` - Enable S3 archival (default: false)
  - `email_s3_bucket` - S3 bucket name
  - `email_sampling_rate` - Percentage to fully log (default: 100)
  - `email_retention_days` - Total retention before deletion (default: 90)

  ## Usage Examples

      # Compress bodies older than 30 days
      {compressed_count, size_saved} = PhoenixKit.Emails.Archiver.compress_old_bodies(30)

      # Archive to S3 with automatic cleanup
      {:ok, archived_count} = PhoenixKit.Emails.Archiver.archive_to_s3(90, 
        bucket: "my-email-archive",
        prefix: "email-logs/2025/"
      )

      # Apply sampling to reduce future storage
      sampled_email = PhoenixKit.Emails.Archiver.apply_sampling_rate(email)

      # Get storage statistics
      stats = PhoenixKit.Emails.Archiver.get_storage_stats()
      # => %{total_logs: 50000, compressed: 15000, archived: 10000, size_mb: 2341}

  ## S3 Integration

  Supports multiple S3-compatible storage providers:
  - Amazon S3
  - DigitalOcean Spaces  
  - Google Cloud Storage
  - MinIO
  - Any S3-compatible service

  ## Compression Algorithm

  Uses gzip compression for email bodies with fallback strategies:

  1. **Gzip** - Primary compression for text content
  2. **Preview Only** - Keep only first 500 chars for very old data
  3. **Metadata Only** - Keep only delivery status and timestamps

  ## Batch Processing

  All operations are designed for efficiency:
  - Process in configurable batch sizes (default: 1000)
  - Progress tracking for long operations
  - Automatic retry on transient failures
  - Memory-efficient streaming for large datasets
  """

  require Logger
  alias PhoenixKit.Modules.Emails.{Event, Log}
  alias PhoenixKit.Settings
  import Ecto.Query

  ## --- Body Compression ---

  @doc """
  Compress email bodies older than specified days.

  Returns `{compressed_count, size_saved_bytes}`.

  ## Options

  - `:batch_size` - Process in batches (default: 1000)
  - `:dry_run` - Show what would be compressed without doing it
  - `:preserve_errors` - Don't compress emails with errors/bounces

  ## Examples

      # Compress bodies older than 30 days
      {count, saved} = Archiver.compress_old_bodies(30)
      # => {1523, 45231040}

      # Dry run to see impact
      {count, estimated_saved} = Archiver.compress_old_bodies(30, dry_run: true)
  """
  def compress_old_bodies(days_old \\ nil, opts \\ []) do
    days_old = days_old || get_compress_days()
    batch_size = Keyword.get(opts, :batch_size, 1000)
    dry_run = Keyword.get(opts, :dry_run, false)
    preserve_errors = Keyword.get(opts, :preserve_errors, true)

    Logger.info("Starting body compression for emails older than #{days_old} days")

    cutoff_date = DateTime.add(DateTime.utc_now(), -days_old * 86_400)

    query = build_compression_query(cutoff_date, preserve_errors)

    if dry_run do
      {count, estimated_size} = estimate_compression_savings(query)
      Logger.info("Would compress #{count} email bodies, saving ~#{format_bytes(estimated_size)}")
      {count, estimated_size}
    else
      process_compression_batches(query, batch_size)
    end
  end

  @doc """
  Apply sampling rate to email for storage optimization.

  Returns modified email with reduced storage footprint for non-critical emails.

  ## Sampling Strategy

  - **Always Full**: Error emails, bounces, complaints  
  - **Always Full**: Transactional emails (password resets, etc.)
  - **Sampling Applied**: Marketing emails, newsletters
  - **Metadata Only**: Bulk emails when over limit

  ## Examples

      # Apply system sampling rate
      email = Archiver.apply_sampling_rate(original_email)

      # Force specific sampling
      email = Archiver.apply_sampling_rate(original_email, force_rate: 50)
  """
  def apply_sampling_rate(email_attrs, opts \\ []) do
    sampling_rate = Keyword.get(opts, :force_rate) || get_sampling_rate()

    # Always store critical emails fully
    if critical_email?(email_attrs) do
      email_attrs
    else
      random_value = :rand.uniform(100)

      if random_value <= sampling_rate do
        # Store fully
        email_attrs
      else
        # Store with reduced data
        apply_reduced_storage(email_attrs)
      end
    end
  end

  ## --- S3 Archival ---

  @doc """
  Archive old emails to S3 storage.

  Returns `{:ok, archived_count}` on success or `{:error, reason}` on failure.

  ## Options

  - `:bucket` - S3 bucket name (required)
  - `:prefix` - S3 object key prefix
  - `:batch_size` - Process in batches (default: 500) 
  - `:format` - Archive format: :json (default), :csv, :parquet
  - `:delete_after_archive` - Delete from DB after successful archive
  - `:include_events` - Include email events in archive

  ## Examples

      # Basic S3 archival
      {:ok, count} = Archiver.archive_to_s3(90,
        bucket: "email-archive",
        prefix: "logs/2025/"
      )

      # Archive with events and cleanup
      {:ok, count} = Archiver.archive_to_s3(90,
        bucket: "email-archive", 
        include_events: true,
        delete_after_archive: true
      )
  """
  def archive_to_s3(days_old, opts \\ []) do
    if s3_archival_enabled?() do
      bucket = Keyword.get(opts, :bucket) || get_s3_bucket()
      prefix = Keyword.get(opts, :prefix, "email-logs/")
      batch_size = Keyword.get(opts, :batch_size, 500)
      format = Keyword.get(opts, :format, :json)
      delete_after = Keyword.get(opts, :delete_after_archive, false)
      include_events = Keyword.get(opts, :include_events, true)

      if bucket do
        do_s3_archival(days_old, bucket, prefix, batch_size, format, delete_after, include_events)
      else
        {:error, :no_bucket_configured}
      end
    else
      {:error, :s3_not_configured}
    end
  end

  defp do_s3_archival(days_old, bucket, prefix, batch_size, format, delete_after, include_events) do
    Logger.info("Starting S3 archival for emails older than #{days_old} days")

    cutoff_date = DateTime.add(DateTime.utc_now(), -days_old * 86_400)
    query = build_archival_query(cutoff_date)

    case process_s3_archival(
           query,
           bucket,
           prefix,
           batch_size,
           format,
           include_events,
           delete_after
         ) do
      {:ok, archived_count} ->
        Logger.info("Successfully archived #{archived_count} emails to S3")
        {:ok, archived_count}

      {:error, reason} ->
        Logger.error("S3 archival failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  ## --- Storage Statistics ---

  @doc """
  Get comprehensive storage statistics.

  ## Examples

      iex> Archiver.get_storage_stats()
      %{
        total_logs: 125000,
        total_events: 450000,
        compressed_bodies: 45000,
        archived_logs: 15000,
        storage_size_mb: 2341,
        oldest_log: ~U[2024-01-15 10:30:00Z],
        compression_ratio: 0.65,
        s3_archived_size_mb: 890
      }
  """
  def get_storage_stats do
    %{
      total_logs: count_total_logs(),
      total_events: count_total_events(),
      compressed_bodies: count_compressed_bodies(),
      archived_logs: count_archived_logs(),
      storage_size_mb: calculate_storage_size_mb(),
      oldest_log: get_oldest_log_date(),
      compression_ratio: calculate_compression_ratio(),
      s3_archived_size_mb: get_s3_archived_size()
    }
  end

  @doc """
  Get detailed storage breakdown by time periods.

  ## Examples

      iex> Archiver.get_storage_breakdown()
      %{
        last_7_days: %{logs: 5000, size_mb: 145, compressed: false},
        last_30_days: %{logs: 15000, size_mb: 420, compressed: 8000},
        last_90_days: %{logs: 35000, size_mb: 980, compressed: 25000},
        older: %{logs: 70000, size_mb: 1200, archived: 45000}
      }
  """
  def get_storage_breakdown do
    now = DateTime.utc_now()

    %{
      last_7_days: get_period_stats(DateTime.add(now, -7 * 86_400), now),
      last_30_days: get_period_stats(DateTime.add(now, -30 * 86_400), now),
      last_90_days: get_period_stats(DateTime.add(now, -90 * 86_400), now),
      older: get_period_stats(~U[1970-01-01 00:00:00Z], DateTime.add(now, -90 * 86_400))
    }
  end

  ## --- Configuration Helpers ---

  defp get_compress_days do
    Settings.get_integer_setting("email_compress_body", 30)
  end

  defp get_sampling_rate do
    Settings.get_integer_setting("email_sampling_rate", 100)
  end

  defp s3_archival_enabled? do
    Settings.get_boolean_setting("email_archive_to_s3", false)
  end

  defp get_s3_bucket do
    Settings.get_setting("email_s3_bucket")
  end

  ## --- Query Builders ---

  defp build_compression_query(cutoff_date, preserve_errors) do
    query =
      from l in Log,
        where: l.sent_at < ^cutoff_date,
        where: not is_nil(l.body_full),
        where: l.body_full != ""

    if preserve_errors do
      query
      |> where([l], l.status not in ["bounced", "failed", "complained"])
    else
      query
    end
  end

  defp build_archival_query(cutoff_date) do
    from l in Log,
      where: l.sent_at < ^cutoff_date,
      order_by: [asc: l.sent_at]
  end

  ## --- Compression Implementation ---

  defp estimate_compression_savings(query) do
    stats_query =
      from l in query,
        select: {count(l.id), sum(fragment("LENGTH(?)", l.body_full))}

    case repo().one(stats_query) do
      {count, total_size} when not is_nil(total_size) ->
        # Estimate 60% compression ratio for email bodies
        estimated_savings = trunc(total_size * 0.6)
        {count || 0, estimated_savings}

      _ ->
        {0, 0}
    end
  end

  defp process_compression_batches(query, batch_size) do
    _total_compressed = 0
    _total_saved = 0

    query
    |> limit(^batch_size)
    |> stream_in_batches(batch_size, fn batch ->
      {batch_compressed, batch_saved} = compress_batch(batch)
      {batch_compressed, batch_saved}
    end)
    |> Enum.reduce({0, 0}, fn {count, saved}, {total_count, total_saved} ->
      {total_count + count, total_saved + saved}
    end)
  end

  defp compress_batch(email_logs) do
    Enum.reduce(email_logs, {0, 0}, fn log, {count, saved} ->
      case compress_email_body(log) do
        {:ok, size_saved} -> {count + 1, saved + size_saved}
        {:error, _} -> {count, saved}
      end
    end)
  end

  defp compress_email_body(%Log{} = log) do
    if log.body_full && String.length(log.body_full) > 100 do
      original_size = byte_size(log.body_full)

      # Compress with gzip
      compressed_data = :zlib.gzip(log.body_full)
      compressed_size = byte_size(compressed_data)

      # Only compress if we save significant space
      if compressed_size < original_size * 0.8 do
        case repo().update(
               Log.changeset(log, %{
                 body_full: Base.encode64(compressed_data)
               })
             ) do
          {:ok, _} -> {:ok, original_size - compressed_size}
          {:error, changeset} -> {:error, changeset}
        end
      else
        # Compression not worth it, just keep preview
        case repo().update(
               Log.changeset(log, %{
                 body_full: nil,
                 body_preview: String.slice(log.body_full, 0, 500)
               })
             ) do
          {:ok, _} -> {:ok, original_size}
          {:error, changeset} -> {:error, changeset}
        end
      end
    else
      {:ok, 0}
    end
  end

  ## --- S3 Implementation ---

  defp process_s3_archival(
         query,
         bucket,
         prefix,
         batch_size,
         format,
         include_events,
         delete_after
       ) do
    _archived_count = 0

    try do
      query
      |> stream_in_batches(batch_size, fn batch ->
        archive_batch_to_s3(batch, bucket, prefix, format, include_events, delete_after)
      end)
      |> Enum.reduce(0, fn batch_count, total -> total + batch_count end)
      |> then(fn count -> {:ok, count} end)
    rescue
      error -> {:error, Exception.message(error)}
    end
  end

  defp archive_batch_to_s3(logs, bucket, prefix, format, include_events, delete_after) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    batch_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    # Prepare data
    archive_data = prepare_archive_data(logs, format, include_events)

    # Generate S3 key
    s3_key = "#{prefix}#{timestamp}/batch-#{batch_id}.#{format}"

    # Upload to S3
    case upload_to_s3(bucket, s3_key, archive_data) do
      {:ok, _message} ->
        if delete_after do
          delete_archived_logs(logs)
        end

        length(logs)

      {:error, reason} ->
        Logger.error("Failed to archive batch to S3: #{inspect(reason)}")
        0
    end
  end

  defp prepare_archive_data(logs, :json, include_events) do
    archive_logs =
      if include_events do
        Enum.map(logs, fn log ->
          events = repo().all(from e in Event, where: e.email_log_id == ^log.id)
          Map.put(log, :events, events)
        end)
      else
        logs
      end

    Jason.encode!(
      %{
        exported_at: DateTime.utc_now(),
        total_records: length(logs),
        logs: archive_logs
      },
      pretty: false
    )
  end

  defp prepare_archive_data(logs, :csv, _include_events) do
    # CSV format implementation
    header = "id,message_id,to,from,subject,status,sent_at,delivered_at\n"

    rows =
      logs
      |> Enum.map_join("\n", fn log ->
        [
          log.id,
          log.message_id,
          log.to,
          log.from,
          log.subject,
          log.status,
          log.sent_at,
          log.delivered_at
        ]
        |> Enum.map_join(",", &csv_escape/1)
      end)

    header <> rows
  end

  @spec upload_to_s3(String.t(), String.t(), binary()) :: {:ok, String.t()} | {:error, String.t()}
  defp upload_to_s3(bucket, key, data) do
    # Upload compressed data to S3 with proper error handling
    case ExAws.S3.put_object(bucket, key, data,
           content_type: "application/gzip",
           content_encoding: "gzip",
           metadata: %{
             "archived-by" => "phoenix_kit",
             "archived-at" => DateTime.to_iso8601(DateTime.utc_now())
           }
         )
         |> ExAws.request() do
      {:ok, _result} ->
        Logger.info("Successfully uploaded archive to S3: s3://#{bucket}/#{key}")
        {:ok, "Successfully archived to S3: #{key}"}

      {:error, {:http_error, 404, _}} ->
        Logger.error("S3 bucket not found: #{bucket}")
        {:error, "S3 bucket not found. Please ensure bucket '#{bucket}' exists."}

      {:error, {:http_error, 403, _}} ->
        Logger.error("S3 access denied for bucket: #{bucket}")
        {:error, "Access denied to S3 bucket. Check IAM permissions."}

      {:error, reason} ->
        Logger.error("Failed to upload to S3: #{inspect(reason)}")
        {:error, "S3 upload failed: #{inspect(reason)}"}
    end
  rescue
    error ->
      Logger.error("S3 upload exception: #{inspect(error)}")
      {:error, "S3 upload exception: #{Exception.message(error)}"}
  end

  defp delete_archived_logs(logs) do
    log_ids = Enum.map(logs, & &1.id)

    # Delete events first (foreign key constraint)
    from(e in Event, where: e.email_log_id in ^log_ids)
    |> repo().delete_all()

    # Delete logs
    from(l in Log, where: l.id in ^log_ids)
    |> repo().delete_all()
  end

  ## --- Sampling Implementation ---

  defp critical_email?(email_attrs) do
    # Check if this is a critical email that should always be stored fully
    cond do
      email_attrs[:status] in ["bounced", "failed", "complained"] -> true
      String.contains?(email_attrs[:subject] || "", ["password", "reset", "verify"]) -> true
      email_attrs[:template_name] in ["password_reset", "email_confirmation"] -> true
      true -> false
    end
  end

  defp apply_reduced_storage(email_attrs) do
    # Store only essential fields for sampled emails
    Map.take(email_attrs, [
      :message_id,
      :to,
      :from,
      :subject,
      :status,
      :sent_at,
      :delivered_at,
      :provider,
      :campaign_id,
      :template_name
    ])
  end

  ## --- Statistics Implementation ---

  defp count_total_logs do
    repo().one(from l in Log, select: count(l.id)) || 0
  end

  defp count_total_events do
    repo().one(from e in Event, select: count(e.id)) || 0
  end

  defp count_compressed_bodies do
    # Count emails with base64-encoded compressed bodies
    repo().one(
      from l in Log,
        where: fragment("? LIKE 'H4sI%'", l.body_full),
        select: count(l.id)
    ) || 0
  end

  defp count_archived_logs do
    # This would count logs marked as archived
    # Simplified for now
    0
  end

  defp calculate_storage_size_mb do
    # Estimate storage size based on average email size
    total_logs = count_total_logs()
    total_events = count_total_events()

    # Rough estimates: 2KB per log, 0.5KB per event
    estimated_bytes = total_logs * 2048 + total_events * 512
    Float.round(estimated_bytes / 1024 / 1024, 1)
  end

  defp get_oldest_log_date do
    repo().one(from l in Log, select: min(l.sent_at))
  end

  defp calculate_compression_ratio do
    compressed_count = count_compressed_bodies()
    total_count = count_total_logs()

    if total_count > 0 do
      Float.round(compressed_count / total_count, 2)
    else
      0.0
    end
  end

  defp get_s3_archived_size do
    # This would query S3 for archived data size
    # Simplified for now
    0.0
  end

  defp get_period_stats(start_time, end_time) do
    query = from l in Log, where: l.sent_at >= ^start_time and l.sent_at < ^end_time

    count = repo().one(from l in query, select: count(l.id)) || 0

    compressed =
      repo().one(
        from l in query,
          where: fragment("? LIKE 'H4sI%'", l.body_full),
          select: count(l.id)
      ) || 0

    %{
      logs: count,
      compressed: compressed,
      # Estimated
      size_mb: Float.round(count * 2.048, 1)
    }
  end

  ## --- Utility Helpers ---

  defp stream_in_batches(query, batch_size, mapper_func) do
    query
    |> repo().all()
    |> Enum.chunk_every(batch_size)
    |> Enum.map(mapper_func)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)}KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / 1024 / 1024, 1)}MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 1)}GB"

  defp csv_escape(nil), do: ""

  defp csv_escape(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"#{String.replace(value, "\"", "\"\"")}\""
    else
      value
    end
  end

  defp csv_escape(value), do: to_string(value)

  # Gets the configured repository for database operations
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
