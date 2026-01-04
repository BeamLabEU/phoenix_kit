defmodule PhoenixKitWeb.Live.Modules do
  @moduledoc """
  Admin modules management LiveView for PhoenixKit.

  Displays available system modules and their configuration status.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.AI
  alias PhoenixKit.Billing
  alias PhoenixKit.DB
  alias PhoenixKit.Entities
  alias PhoenixKit.Jobs
  alias PhoenixKit.Modules.Connections
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Modules.SEO
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Pages
  alias PhoenixKit.Posts
  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Settings
  alias PhoenixKit.Sitemap
  alias PhoenixKit.Sync
  alias PhoenixKit.Tickets
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitWeb.Live.Modules.Blogging

  def mount(_params, _session, socket) do
    # Set locale for LiveView process

    # Get project title from settings cache
    project_title = Settings.get_setting_cached("project_title", "PhoenixKit")

    # Load module states
    referral_codes_config = ReferralCodes.get_config()
    email_config = PhoenixKit.Emails.get_config()
    languages_config = Languages.get_config()
    entities_config = Entities.get_config()
    pages_enabled = Pages.enabled?()
    blogging_enabled = Blogging.enabled?()
    under_construction_config = Maintenance.get_config()
    seo_config = SEO.get_config()
    storage_config = Storage.get_config()
    sitemap_config = Sitemap.get_config()
    billing_config = Billing.get_config()
    posts_config = Posts.get_config()
    ai_config = AI.get_config()
    db_sync_config = Sync.get_config()
    tickets_config = Tickets.get_config()
    connections_config = Connections.get_config()
    jobs_config = Jobs.get_config()
    legal_config = Legal.get_config()
    db_explorer_config = DB.get_config()

    socket =
      socket
      |> assign(:page_title, "Modules")
      |> assign(:project_title, project_title)
      |> assign(:referral_codes_enabled, referral_codes_config.enabled)
      |> assign(:referral_codes_required, referral_codes_config.required)
      |> assign(:max_uses_per_code, referral_codes_config.max_uses_per_code)
      |> assign(:max_codes_per_user, referral_codes_config.max_codes_per_user)
      |> assign(:email_enabled, email_config.enabled)
      |> assign(:email_save_body, email_config.save_body)
      |> assign(:email_ses_events, email_config.ses_events)
      |> assign(:email_retention_days, email_config.retention_days)
      |> assign(:languages_enabled, languages_config.enabled)
      |> assign(:languages_count, languages_config.language_count)
      |> assign(:languages_enabled_count, languages_config.enabled_count)
      |> assign(:languages_default, languages_config.default_language)
      |> assign(:entities_enabled, entities_config.enabled)
      |> assign(:entities_count, entities_config.entity_count)
      |> assign(:entities_total_data, entities_config.total_data_count)
      |> assign(:pages_enabled, pages_enabled)
      |> assign(:blogging_enabled, blogging_enabled)
      |> assign(:under_construction_module_enabled, under_construction_config.module_enabled)
      |> assign(:under_construction_enabled, under_construction_config.enabled)
      |> assign(:under_construction_header, under_construction_config.header)
      |> assign(:under_construction_subtext, under_construction_config.subtext)
      |> assign(:storage_enabled, storage_config.module_enabled)
      |> assign(:storage_buckets_count, storage_config.buckets_count)
      |> assign(:storage_active_buckets_count, storage_config.active_buckets_count)
      |> assign(:seo_module_enabled, seo_config.module_enabled)
      |> assign(:seo_no_index_enabled, seo_config.no_index_enabled)
      |> assign(:sitemap_enabled, sitemap_config.enabled)
      |> assign(:sitemap_url_count, sitemap_config.url_count)
      |> assign(:sitemap_last_generated, sitemap_config.last_generated)
      |> assign(:sitemap_schedule_enabled, sitemap_config.schedule_enabled)
      |> assign(:billing_enabled, billing_config.enabled)
      |> assign(:billing_orders_count, billing_config.orders_count)
      |> assign(:billing_invoices_count, billing_config.invoices_count)
      |> assign(:billing_currencies_count, billing_config.currencies_count)
      |> assign(:ai_enabled, ai_config.enabled)
      |> assign(:ai_endpoints_count, ai_config.endpoints_count)
      |> assign(:ai_total_requests, ai_config.total_requests)
      |> assign(:posts_enabled, posts_config.enabled)
      |> assign(:posts_total, posts_config.total_posts)
      |> assign(:posts_published, posts_config.published_posts)
      |> assign(:posts_draft, posts_config.draft_posts)
      |> assign(:sync_enabled, db_sync_config.enabled)
      |> assign(:sync_active_sessions, db_sync_config.active_sessions)
      |> assign(:tickets_enabled, tickets_config.enabled)
      |> assign(:tickets_total, tickets_config.total_tickets)
      |> assign(:tickets_open, tickets_config.open_tickets)
      |> assign(:tickets_in_progress, tickets_config.in_progress_tickets)
      |> assign(:connections_enabled, connections_config.enabled)
      |> assign(:connections_follows_count, connections_config.follows_count)
      |> assign(:connections_connections_count, connections_config.connections_count)
      |> assign(:connections_blocks_count, connections_config.blocks_count)
      |> assign(:jobs_enabled, jobs_config.enabled)
      |> assign(:jobs_stats, jobs_config.stats)
      |> assign(:legal_enabled, legal_config.enabled)
      |> assign(:blogging_enabled_for_legal, legal_config.blogging_enabled)
      |> assign(:db_explorer_enabled, db_explorer_config.enabled)
      |> assign(:db_explorer_table_count, db_explorer_config.table_count)
      |> assign(:db_explorer_total_rows, db_explorer_config.approx_rows)
      |> assign(:db_explorer_total_size, db_explorer_config.total_size_bytes)
      |> assign(:db_explorer_database_size, db_explorer_config.database_size_bytes)

    {:ok, socket}
  end

  def handle_event("toggle_referral_codes", _params, socket) do
    # Since we're sending "toggle", we just flip the current state
    new_enabled = !socket.assigns.referral_codes_enabled

    result =
      if new_enabled do
        ReferralCodes.enable_system()
      else
        ReferralCodes.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:referral_codes_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Referral codes enabled",
              else: "Referral codes disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update referral codes")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_emails", _params, socket) do
    # Toggle email system
    new_enabled = !socket.assigns.email_enabled

    result =
      if new_enabled do
        PhoenixKit.Emails.enable_system()
      else
        PhoenixKit.Emails.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:email_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Email system enabled",
              else: "Email system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update email system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_languages", _params, socket) do
    # Toggle languages
    new_enabled = !socket.assigns.languages_enabled

    result =
      if new_enabled do
        Languages.enable_system()
      else
        Languages.disable_system()
      end

    case result do
      {:ok, _} ->
        # Reload languages configuration to get fresh data
        languages_config = Languages.get_config()

        socket =
          socket
          |> assign(:languages_enabled, new_enabled)
          |> assign(:languages_count, languages_config.language_count)
          |> assign(:languages_enabled_count, languages_config.enabled_count)
          |> assign(:languages_default, languages_config.default_language)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Languages enabled with default English",
              else: "Languages disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update languages")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_entities", _params, socket) do
    # Toggle entities system
    new_enabled = !socket.assigns.entities_enabled

    result =
      if new_enabled do
        Entities.enable_system()
      else
        Entities.disable_system()
      end

    case result do
      {:ok, _} ->
        # Reload entities configuration to get fresh data
        entities_config = Entities.get_config()

        socket =
          socket
          |> assign(:entities_enabled, new_enabled)
          |> assign(:entities_count, entities_config.entity_count)
          |> assign(:entities_total_data, entities_config.total_data_count)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Entities system enabled",
              else: "Entities system disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update entities system")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_seo_module", _params, socket) do
    new_enabled = !socket.assigns.seo_module_enabled

    result =
      if new_enabled do
        SEO.enable_module()
      else
        SEO.disable_module()
      end

    case result do
      {:ok, _setting} ->
        seo_no_index_enabled =
          if new_enabled do
            SEO.no_index_enabled?()
          else
            false
          end

        message =
          if new_enabled do
            "SEO module enabled - configure options in Settings → SEO"
          else
            "SEO module disabled and search directives reset"
          end

        socket =
          socket
          |> assign(:seo_module_enabled, new_enabled)
          |> assign(:seo_no_index_enabled, seo_no_index_enabled)
          |> put_flash(:info, message)

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update SEO module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_blogging", _params, socket) do
    new_enabled = !socket.assigns.blogging_enabled

    result =
      if new_enabled do
        Blogging.enable_system()
      else
        Blogging.disable_system()
      end

    case result do
      {:ok, _} ->
        socket =
          socket
          |> assign(:blogging_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Blogging module enabled",
              else: "Blogging module disabled"
            )
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update blogging module")}
    end
  end

  def handle_event("toggle_pages", _params, socket) do
    # Toggle pages system
    new_enabled = !socket.assigns.pages_enabled

    result =
      if new_enabled do
        Pages.enable_system()
      else
        Pages.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:pages_enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Pages module enabled",
              else: "Pages module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update pages module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_under_construction", _params, socket) do
    # Toggle under construction module (settings page access)
    new_module_enabled = !socket.assigns.under_construction_module_enabled

    result =
      if new_module_enabled do
        Maintenance.enable_module()
      else
        Maintenance.disable_module()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:under_construction_module_enabled, new_module_enabled)
          |> put_flash(
            :info,
            if(new_module_enabled,
              do: "Maintenance mode module enabled - configure settings to activate",
              else: "Maintenance mode module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update maintenance mode module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_sitemap", _params, socket) do
    new_enabled = !socket.assigns.sitemap_enabled

    result =
      if new_enabled do
        Sitemap.enable_system()
      else
        Sitemap.disable_system()
      end

    case result do
      {:ok, _} ->
        sitemap_config = Sitemap.get_config()

        socket =
          socket
          |> assign(:sitemap_enabled, new_enabled)
          |> assign(:sitemap_url_count, sitemap_config.url_count)
          |> assign(:sitemap_last_generated, sitemap_config.last_generated)
          |> assign(:sitemap_schedule_enabled, sitemap_config.schedule_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Sitemap module enabled",
              else: "Sitemap module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update sitemap module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_billing", _params, socket) do
    new_enabled = !socket.assigns.billing_enabled

    result =
      if new_enabled do
        Billing.enable_system()
      else
        Billing.disable_system()
      end

    case result do
      {:ok, _} ->
        billing_config = Billing.get_config()

        socket =
          socket
          |> assign(:billing_enabled, new_enabled)
          |> assign(:billing_orders_count, billing_config.orders_count)
          |> assign(:billing_invoices_count, billing_config.invoices_count)
          |> assign(:billing_currencies_count, billing_config.currencies_count)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Billing module enabled",
              else: "Billing module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update billing module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_ai", _params, socket) do
    new_enabled = !socket.assigns.ai_enabled

    result =
      if new_enabled do
        AI.enable_system()
      else
        AI.disable_system()
      end

    case result do
      {:ok, _} ->
        ai_config = AI.get_config()

        socket =
          socket
          |> assign(:ai_enabled, new_enabled)
          |> assign(:ai_endpoints_count, ai_config.endpoints_count)
          |> assign(:ai_total_requests, ai_config.total_requests)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "AI module enabled",
              else: "AI module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update AI module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_posts", _params, socket) do
    new_enabled = !socket.assigns.posts_enabled

    result =
      if new_enabled do
        Posts.enable_system()
      else
        Posts.disable_system()
      end

    case result do
      {:ok, _} ->
        posts_config = Posts.get_config()

        socket =
          socket
          |> assign(:posts_enabled, new_enabled)
          |> assign(:posts_total, posts_config.total_posts)
          |> assign(:posts_published, posts_config.published_posts)
          |> assign(:posts_draft, posts_config.draft_posts)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Posts module enabled",
              else: "Posts module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update posts module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_sync", _params, socket) do
    new_enabled = !socket.assigns.sync_enabled

    result =
      if new_enabled do
        Sync.enable_system()
      else
        Sync.disable_system()
      end

    case result do
      {:ok, _} ->
        sync_config = Sync.get_config()

        socket =
          socket
          |> assign(:sync_enabled, new_enabled)
          |> assign(:sync_active_sessions, sync_config.active_sessions)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Sync module enabled",
              else: "Sync module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update DB Sync module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_db_explorer", _params, socket) do
    new_enabled = !socket.assigns.db_explorer_enabled

    result =
      if new_enabled do
        DB.enable_system()
      else
        DB.disable_system()
      end

    case result do
      {:ok, _} ->
        config = DB.get_config()

        socket =
          socket
          |> assign(:db_explorer_enabled, config.enabled)
          |> assign(:db_explorer_table_count, config.table_count)
          |> assign(:db_explorer_total_rows, config.approx_rows)
          |> assign(:db_explorer_total_size, config.total_size_bytes)
          |> assign(:db_explorer_database_size, config.database_size_bytes)
          |> put_flash(
            :info,
            if(config.enabled,
              do: "DB Explorer enabled",
              else: "DB Explorer disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update DB Explorer")}
    end
  end

  def handle_event("toggle_tickets", _params, socket) do
    new_enabled = !socket.assigns.tickets_enabled

    result =
      if new_enabled do
        Tickets.enable_system()
      else
        Tickets.disable_system()
      end

    case result do
      {:ok, _} ->
        tickets_config = Tickets.get_config()

        socket =
          socket
          |> assign(:tickets_enabled, new_enabled)
          |> assign(:tickets_total, tickets_config.total_tickets)
          |> assign(:tickets_open, tickets_config.open_tickets)
          |> assign(:tickets_in_progress, tickets_config.in_progress_tickets)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Tickets module enabled",
              else: "Tickets module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update tickets module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_connections", _params, socket) do
    new_enabled = !socket.assigns.connections_enabled

    result =
      if new_enabled do
        Connections.enable_system()
      else
        Connections.disable_system()
      end

    case result do
      {:ok, _} ->
        connections_config = Connections.get_config()

        socket =
          socket
          |> assign(:connections_enabled, new_enabled)
          |> assign(:connections_follows_count, connections_config.follows_count)
          |> assign(:connections_connections_count, connections_config.connections_count)
          |> assign(:connections_blocks_count, connections_config.blocks_count)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Connections module enabled",
              else: "Connections module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update connections module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_jobs", _params, socket) do
    new_enabled = !socket.assigns.jobs_enabled

    result =
      if new_enabled do
        Jobs.enable_system()
      else
        Jobs.disable_system()
      end

    case result do
      {:ok, _} ->
        jobs_config = Jobs.get_config()

        socket =
          socket
          |> assign(:jobs_enabled, new_enabled)
          |> assign(:jobs_stats, jobs_config.stats)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Jobs module enabled",
              else: "Jobs module disabled"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update Jobs module")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_legal", _params, socket) do
    if socket.assigns.legal_enabled do
      case Legal.disable_system() do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:legal_enabled, false)
           |> put_flash(:info, gettext("Legal module disabled"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to disable Legal module"))}
      end
    else
      case Legal.enable_system() do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:legal_enabled, true)
           |> put_flash(:info, gettext("Legal module enabled"))}

        {:error, :blogging_required} ->
          {:noreply, put_flash(socket, :error, gettext("Please enable Blogging module first"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to enable Legal module"))}
      end
    end
  end

  # Format ISO8601 timestamp string to user-friendly format with system timezone
  def format_timestamp(nil), do: "Never"

  def format_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        # Use fake user with nil timezone to get system timezone from Settings
        fake_user = %{user_timezone: nil}
        date_str = UtilsDate.format_date_with_user_timezone(dt, fake_user)
        time_str = UtilsDate.format_time_with_user_timezone(dt, fake_user)
        "#{date_str} #{time_str}"

      _ ->
        iso_string
    end
  end

  def format_timestamp(_), do: "Never"

  def format_bytes(nil), do: "0 B"
  def format_bytes(0), do: "0 B"

  def format_bytes(%Decimal{} = bytes) do
    bytes |> Decimal.to_integer() |> format_bytes()
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024 do
    "#{bytes} B"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  def format_bytes(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  def format_bytes(_), do: "0 B"
end
