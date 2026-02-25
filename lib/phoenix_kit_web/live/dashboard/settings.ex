defmodule PhoenixKitWeb.Live.Dashboard.Settings do
  @moduledoc """
  Settings LiveView for PhoenixKit Dashboard.

  Allows authenticated users to update their email, password, profile information,
  and personal preferences such as timezone, date format, and time format.
  """
  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Auth.update_user_email(socket.assigns.phoenix_kit_current_user, token) do
        :ok ->
          socket
          |> assign(:email_success_message, gettext("Email changed successfully."))

        :error ->
          socket
          |> assign(
            :email_error_message,
            gettext("Email change link is invalid or it has expired.")
          )
      end

    {:ok, push_navigate(socket, to: Routes.path("/dashboard/settings"))}
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.phoenix_kit_current_user
    email_changeset = Auth.change_user_email(user)
    password_changeset = Auth.change_user_password(user)
    profile_changeset = Auth.change_user_profile(user)

    # Get timezone options from Settings module
    setting_options = Settings.get_setting_options()
    timezone_options = [{"Use System Default", nil} | setting_options["time_zone"]]

    # Load OAuth providers for the user
    oauth_providers = OAuth.get_user_oauth_providers(user.id)
    oauth_available = OAuthAvailability.oauth_available?()

    # Check which providers are available to connect
    available_providers = get_available_oauth_providers(oauth_providers)

    # Load user-accessible custom fields
    custom_field_definitions = CustomFields.list_user_accessible_field_definitions()

    socket =
      socket
      |> assign(:page_title, gettext("Settings"))
      |> assign(:profile_success_message, nil)
      |> assign(:email_success_message, nil)
      |> assign(:email_error_message, nil)
      |> assign(:password_success_message, nil)
      |> assign(:password_error_message, nil)
      |> assign(:oauth_success_message, nil)
      |> assign(:oauth_error_message, nil)
      |> assign(:avatar_success_message, nil)
      |> assign(:avatar_error_message, nil)
      |> allow_upload(:avatar,
        accept: ["image/*"],
        max_entries: 1,
        max_file_size: 10_000_000,
        auto_upload: true
      )
      |> assign(:current_password, nil)
      |> assign(:email_form_current_password, nil)
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:timezone_options, timezone_options)
      |> assign(:browser_timezone_name, nil)
      |> assign(:browser_timezone_offset, nil)
      |> assign(:timezone_mismatch_warning, nil)
      |> assign(:trigger_submit, false)
      |> assign(:oauth_providers, oauth_providers)
      |> assign(:oauth_available, oauth_available)
      |> assign(:available_providers, available_providers)
      |> assign(:custom_field_definitions, custom_field_definitions)
      |> assign(:last_uploaded_avatar_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket,
       email_form: email_form,
       email_form_current_password: password,
       email_success_message: nil,
       email_error_message: nil
     )}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &Routes.url("/dashboard/settings/confirm-email/#{&1}")
        )

        socket =
          socket
          |> assign(
            :email_success_message,
            gettext("A link to confirm your email change has been sent to the new address.")
          )
          |> assign(email_form_current_password: nil)

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:email_form, to_form(Map.put(changeset, :action, :insert)))
          |> assign(:email_success_message, nil)
          |> assign(:email_error_message, nil)

        {:noreply, socket}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket,
       password_form: password_form,
       current_password: password,
       password_success_message: nil,
       password_error_message: nil
     )}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.update_user_password(user, password, user_params) do
      {:ok, user} ->
        password_form =
          user
          |> Auth.change_user_password(user_params)
          |> to_form()

        socket =
          socket
          |> assign(trigger_submit: true, password_form: password_form)
          |> assign(:password_success_message, gettext("Password changed successfully."))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(password_form: to_form(changeset))
          |> assign(:password_success_message, nil)

        {:noreply, socket}
    end
  end

  def handle_event("validate_profile", params, socket) do
    %{"user" => user_params} = params

    # Check if browser timezone data is included in the form submission
    socket =
      case {params["browser_timezone_name"], params["browser_timezone_offset"]} do
        {name, offset} when is_binary(name) and is_binary(offset) ->
          socket
          |> assign(:browser_timezone_name, name)
          |> assign(:browser_timezone_offset, offset)

        _ ->
          socket
      end

    # Merge custom fields if present
    merged_params =
      case params["custom_fields"] do
        custom_fields when is_map(custom_fields) ->
          Map.put(user_params, "custom_fields", custom_fields)

        _ ->
          user_params
      end

    profile_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_profile(merged_params)
      |> Map.put(:action, :validate)
      |> to_form()

    # Check for timezone mismatch when user changes timezone
    socket =
      socket
      |> assign(profile_form: profile_form)
      |> assign(:profile_success_message, nil)
      |> assign(:email_error_message, nil)
      |> assign(:oauth_error_message, nil)
      |> assign(:avatar_error_message, nil)
      |> check_timezone_mismatch(user_params["user_timezone"])

    {:noreply, socket}
  end

  def handle_event("update_profile", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    # Merge custom fields if present, preserving avatar_file_id
    merged_params =
      case params["custom_fields"] do
        custom_fields when is_map(custom_fields) ->
          # Preserve avatar_file_id from existing custom_fields
          existing_avatar = get_in(user.custom_fields, ["avatar_file_id"])

          updated_custom_fields =
            if existing_avatar do
              Map.put(custom_fields, "avatar_file_id", existing_avatar)
            else
              custom_fields
            end

          Map.put(user_params, "custom_fields", updated_custom_fields)

        _ ->
          # No custom fields in form, but preserve avatar if it exists
          existing_avatar = get_in(user.custom_fields, ["avatar_file_id"])

          if existing_avatar do
            Map.put(user_params, "custom_fields", %{"avatar_file_id" => existing_avatar})
          else
            user_params
          end
      end

    case Auth.update_user_profile(user, merged_params) do
      {:ok, updated_user} ->
        socket =
          socket
          |> assign(:phoenix_kit_current_user, updated_user)
          |> assign(:profile_success_message, gettext("Profile updated successfully"))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:profile_form, to_form(Map.put(changeset, :action, :insert)))
          |> assign(:profile_success_message, nil)

        {:noreply, socket}
    end
  end

  def handle_event("use_browser_timezone", _params, socket) do
    browser_offset = socket.assigns.browser_timezone_offset

    if browser_offset do
      # Update the profile form with browser timezone
      user = socket.assigns.phoenix_kit_current_user
      updated_attrs = %{"user_timezone" => browser_offset}

      profile_form =
        user
        |> Auth.change_user_profile(updated_attrs)
        |> to_form()

      socket =
        socket
        |> assign(:profile_form, profile_form)
        |> assign(:timezone_mismatch_warning, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("connect_oauth_provider", %{"provider" => provider}, socket) do
    # Redirect to OAuth authorization URL
    # Store return_to in session so OAuth callback knows to return here
    oauth_url = Routes.url("/users/auth/#{provider}?return_to=/dashboard/settings")

    socket =
      socket
      |> assign(:oauth_info_message, "Redirecting to #{format_provider_name(provider)}...")
      |> redirect(external: oauth_url)

    {:noreply, socket}
  end

  def handle_event("disconnect_oauth_provider", %{"provider" => provider}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    # Check if user can safely disconnect this provider
    if can_disconnect_provider?(user, provider) do
      case OAuth.unlink_oauth_provider(user.id, provider) do
        {:ok, _} ->
          # Reload OAuth providers list
          oauth_providers = OAuth.get_user_oauth_providers(user.id)
          available_providers = get_available_oauth_providers(oauth_providers)

          socket =
            socket
            |> assign(:oauth_providers, oauth_providers)
            |> assign(:available_providers, available_providers)
            |> assign(
              :oauth_success_message,
              gettext("%{provider} account disconnected successfully",
                provider: format_provider_name(provider)
              )
            )
            |> assign(:oauth_error_message, nil)

          {:noreply, socket}

        {:error, :not_found} ->
          socket =
            assign(socket, :oauth_error_message, gettext("Provider not found"))
            |> assign(:oauth_success_message, nil)

          {:noreply, socket}

        {:error, _reason} ->
          socket =
            assign(
              socket,
              :oauth_error_message,
              gettext("Failed to disconnect provider. Please try again.")
            )
            |> assign(:oauth_success_message, nil)

          {:noreply, socket}
      end
    else
      # User cannot disconnect - show warning
      warning_message =
        if user.hashed_password == nil do
          gettext(
            "Cannot disconnect %{provider}. This is your only sign-in method. Please set a password or connect another provider first.",
            provider: format_provider_name(provider)
          )
        else
          gettext(
            "Cannot disconnect %{provider}. Please ensure you have at least one sign-in method available.",
            provider: format_provider_name(provider)
          )
        end

      socket =
        assign(socket, :oauth_error_message, warning_message)
        |> assign(:oauth_success_message, nil)

      {:noreply, socket}
    end
  end

  def handle_event("validate", %{"_target" => ["avatar"]}, socket) do
    # Avatar file selection event - files will auto-upload
    entries = socket.assigns.uploads.avatar.entries
    Logger.info("avatar validate event: entries=#{length(entries)}")

    if entries != [] do
      Logger.info("avatar validate: scheduling check_uploads_complete")
      Process.send_after(self(), :check_avatar_uploads_complete, 500)
    end

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  # Check for timezone mismatch based on current form values
  defp check_timezone_mismatch(socket, selected_timezone) do
    browser_offset = socket.assigns[:browser_timezone_offset]
    browser_name = socket.assigns[:browser_timezone_name]

    # Get selected timezone from parameters or current form value
    user_timezone =
      selected_timezone ||
        get_in(socket.assigns.profile_form.params, ["user_timezone"]) ||
        socket.assigns.phoenix_kit_current_user.user_timezone

    case {browser_offset, user_timezone} do
      {nil, _} ->
        # No browser timezone detected, no warning
        assign(socket, :timezone_mismatch_warning, nil)

      {browser_tz, nil} when browser_tz != "0" ->
        # User selected "Use System Default" but browser is not UTC
        system_tz = Settings.get_setting("time_zone", "0")

        if browser_tz != system_tz do
          warning_msg =
            "Your browser timezone appears to be #{browser_name} (#{format_timezone_offset(browser_tz)}) " <>
              "but you selected 'Use System Default' which is #{format_timezone_offset(system_tz)}."

          assign(socket, :timezone_mismatch_warning, warning_msg)
        else
          assign(socket, :timezone_mismatch_warning, nil)
        end

      {browser_tz, user_tz} when browser_tz != user_tz ->
        # Normalize user timezone for comparison (remove + if present, browser_tz has +)
        normalized_user_tz = String.replace(user_tz, "+", "")
        normalized_browser_tz = String.replace(browser_tz, "+", "")

        # Only show warning if they're actually different (not just formatting)
        if normalized_browser_tz != normalized_user_tz do
          # User selected specific timezone that doesn't match browser
          warning_msg =
            "Your browser timezone appears to be #{browser_name} (#{format_timezone_offset(browser_tz)}) " <>
              "but you selected #{format_timezone_offset(user_tz)}. Please verify this is correct."

          assign(socket, :timezone_mismatch_warning, warning_msg)
        else
          assign(socket, :timezone_mismatch_warning, nil)
        end

      _ ->
        # Timezones match or no significant difference
        assign(socket, :timezone_mismatch_warning, nil)
    end
  end

  # Format timezone offset for display
  defp format_timezone_offset(offset) do
    case offset do
      "0" ->
        "UTC+0"

      "+" <> _ ->
        "UTC" <> offset

      "-" <> _ ->
        "UTC" <> offset

      _ when is_binary(offset) ->
        # If it's a positive number without +, add the +
        case Integer.parse(offset) do
          {num, ""} when num > 0 -> "UTC+" <> offset
          {num, ""} when num < 0 -> "UTC" <> offset
          {0, ""} -> "UTC+0"
          _ -> "UTC" <> offset
        end

      _ ->
        "Unknown"
    end
  end

  # OAuth helper functions

  defp get_available_oauth_providers(oauth_providers) do
    # Get list of connected provider names
    connected = Enum.map(oauth_providers, & &1.provider)

    # All possible providers
    all_providers = ["google", "apple", "github"]

    # Filter out connected ones and check if each is enabled
    all_providers
    |> Enum.reject(&(&1 in connected))
    |> Enum.filter(&provider_enabled?/1)
  end

  defp provider_enabled?("google"), do: OAuthAvailability.provider_enabled?(:google)
  defp provider_enabled?("apple"), do: OAuthAvailability.provider_enabled?(:apple)
  defp provider_enabled?("github"), do: OAuthAvailability.provider_enabled?(:github)
  defp provider_enabled?(_), do: false

  defp can_disconnect_provider?(user, _provider) do
    # User can disconnect if they have:
    # 1. A password set, OR
    # 2. Multiple OAuth providers connected

    has_password = user.hashed_password != nil
    oauth_count = length(OAuth.get_user_oauth_providers(user.id))

    has_password or oauth_count > 1
  end

  defp format_provider_name("google"), do: "Google"
  defp format_provider_name("apple"), do: "Apple"
  defp format_provider_name("github"), do: "GitHub"
  defp format_provider_name(provider), do: String.capitalize(provider)

  # Avatar upload processing

  @impl true
  def handle_info(:check_avatar_uploads_complete, socket) do
    entries = socket.assigns.uploads.avatar.entries

    Logger.info(
      "check_avatar_uploads_complete: entries=#{length(entries)}, done?=#{inspect(Enum.map(entries, & &1.done?))}"
    )

    # Check if all entries are done uploading
    if entries != [] && Enum.all?(entries, & &1.done?) do
      Logger.info("Avatar uploads done! Processing...")
      # All done - process them
      process_avatar_uploads(socket)
    else
      # Still uploading - check again later
      Logger.info("Still uploading avatar, checking again...")
      Process.send_after(self(), :check_avatar_uploads_complete, 500)
      {:noreply, socket}
    end
  end

  defp process_avatar_uploads(socket) do
    # Process uploaded avatar files
    uploaded_avatars =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        # Get file info
        ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")

        # Get current user
        current_user = socket.assigns.phoenix_kit_current_user
        user_id = current_user.id

        # Get file size
        {:ok, stat} = Elixir.File.stat(path)
        file_size = stat.size

        # Calculate hash
        file_hash = Auth.calculate_file_hash(path)

        # Store file in storage
        case Storage.store_file_in_buckets(
               path,
               "image",
               user_id,
               file_hash,
               ext,
               entry.client_name
             ) do
          {:ok, file, :duplicate} ->
            Logger.info("Avatar file is duplicate with ID: #{file.uuid}")

            {:ok,
             %{
               file_id: file.uuid,
               filename: entry.client_name,
               size: file_size,
               duplicate: true
             }}

          {:ok, file} ->
            Logger.info("Avatar file stored with ID: #{file.uuid}")

            {:ok,
             %{
               file_id: file.uuid,
               filename: entry.client_name,
               size: file_size
             }}

          {:error, reason} ->
            Logger.error("Storage Error: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    # Extract file IDs for use
    Logger.info("Uploaded avatars: #{inspect(uploaded_avatars)}")
    avatar_file_ids = Enum.map(uploaded_avatars, &get_avatar_file_id/1)
    Logger.info("Avatar file IDs: #{inspect(avatar_file_ids)}")
    avatar_file_id = List.first(avatar_file_ids)
    Logger.info("First avatar file ID: #{inspect(avatar_file_id)}")

    # Save the avatar file ID to the user's custom fields
    socket =
      if avatar_file_id && avatar_file_id != nil do
        user = socket.assigns.phoenix_kit_current_user

        case Auth.update_user_fields(user, %{"avatar_file_id" => avatar_file_id}) do
          {:ok, updated_user} ->
            Logger.info("Avatar file ID saved: #{avatar_file_id}")

            socket
            |> assign(:phoenix_kit_current_user, updated_user)
            |> assign(:last_uploaded_avatar_id, avatar_file_id)
            |> assign(:avatar_success_message, gettext("Avatar uploaded successfully!"))
            |> assign(:avatar_error_message, nil)

          {:error, changeset} ->
            Logger.error("Failed to save avatar file ID: #{inspect(changeset)}")

            socket
            |> assign(:last_uploaded_avatar_id, avatar_file_id)
            |> assign(
              :avatar_error_message,
              gettext("Avatar uploaded but failed to save to profile")
            )
            |> assign(:avatar_success_message, nil)
        end
      else
        socket
        |> assign(:avatar_error_message, gettext("Failed to upload avatar"))
        |> assign(:avatar_success_message, nil)
      end

    {:noreply, socket}
  end

  defp get_avatar_file_id(%{file_id: file_id}), do: file_id
  defp get_avatar_file_id({:ok, %{file_id: file_id}}), do: file_id
  defp get_avatar_file_id(_), do: nil

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="max-w-6xl mx-auto">
        <%!-- Development Mode Notice --%>
        <.dev_mailbox_notice class="mb-6 flex w-full sm:w-fit" />

        <div class="mb-8">
          <h1 class="text-3xl font-bold text-base-content mb-2">Settings</h1>
          <p class="text-base-content/70">Manage your account settings and preferences</p>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <!-- Left Column - Profile -->
          <div class="lg:col-span-2 space-y-6">
            <!-- Profile Information Card -->
            <div class="card bg-base-100 shadow-sm border border-base-300">
              <div class="card-body">
                <h2 class="card-title flex items-center gap-2">
                  <.icon name="hero-user" class="w-5 h-5" /> Profile Information
                </h2>
                
    <!-- Success Message -->
                <%= if @profile_success_message do %>
                  <div class="alert alert-success text-sm mb-4">
                    <.icon name="hero-check" class="stroke-current shrink-0 h-5 w-5" />
                    <span>{@profile_success_message}</span>
                  </div>
                <% end %>
                
    <!-- Avatar Upload Section -->
                <div>
                  <label class="label">
                    <span class="label-text font-semibold">Profile Picture</span>
                  </label>

                  <div class="flex items-start gap-6">
                    <!-- Avatar Preview -->
                    <div class="flex-shrink-0">
                      <%= if get_in(@phoenix_kit_current_user.custom_fields, ["avatar_file_id"]) do %>
                        <% avatar_url =
                          PhoenixKit.Modules.Storage.URLSigner.signed_url(
                            get_in(@phoenix_kit_current_user.custom_fields, ["avatar_file_id"]),
                            "thumbnail"
                          ) %>
                        <img
                          src={avatar_url}
                          alt="Avatar"
                          class="w-24 h-24 rounded-full object-cover border-2 border-base-300"
                        />
                      <% else %>
                        <div class="w-24 h-24 rounded-full bg-primary/10 border-2 border-base-300 flex items-center justify-center">
                          <span class="text-2xl font-bold text-primary">
                            {String.upcase(String.at(@phoenix_kit_current_user.email, 0))}
                          </span>
                        </div>
                      <% end %>
                    </div>
                    
    <!-- Upload Controls -->
                    <div class="flex-1">
                      <.file_upload
                        upload={@uploads.avatar}
                        variant="button"
                        label="Choose Profile Picture"
                      />

                      <p class="text-sm text-base-content/60 mt-2 mb-2">
                        Upload a profile picture (max 10MB). Accepts JPG, PNG, GIF.
                      </p>
                      
    <!-- Success Message -->
                      <%= if @last_uploaded_avatar_id do %>
                        <div class="alert alert-success text-sm">
                          <.icon name="hero-check" class="stroke-current shrink-0 h-5 w-5" />
                          <span>Avatar uploaded successfully!</span>
                        </div>
                      <% end %>
                      
    <!-- Avatar Error Message -->
                      <%= if @avatar_error_message do %>
                        <div class="alert alert-error text-sm">
                          <.icon
                            name="hero-exclamation-triangle"
                            class="stroke-current shrink-0 h-5 w-5"
                          />
                          <span>{@avatar_error_message}</span>
                        </div>
                      <% end %>
                    </div>
                  </div>
                  
    <!-- Divider after avatar section -->
                  <div class="divider"></div>
                </div>

                <.simple_form
                  for={@profile_form}
                  id="profile_form"
                  phx-submit="update_profile"
                  phx-change="validate_profile"
                >
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <.input
                      field={@profile_form[:first_name]}
                      type="text"
                      label="First Name"
                    />
                    <.input
                      field={@profile_form[:last_name]}
                      type="text"
                      label="Last Name"
                    />
                  </div>
                  
    <!-- Custom Fields Section -->
                  <%= if length(@custom_field_definitions) > 0 do %>
                    <div class="divider text-sm text-base-content/60">Additional Information</div>

                    <%= for field_def <- @custom_field_definitions do %>
                      <%= case field_def["type"] do %>
                        <% "text" -> %>
                          <.input
                            name={"custom_fields[#{field_def["key"]}]"}
                            type="text"
                            label={field_def["label"]}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                        <% "textarea" -> %>
                          <.textarea
                            name={"custom_fields[#{field_def["key"]}]"}
                            label={field_def["label"]}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                        <% "number" -> %>
                          <.input
                            name={"custom_fields[#{field_def["key"]}]"}
                            type="number"
                            label={field_def["label"]}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                        <% "email" -> %>
                          <.input
                            name={"custom_fields[#{field_def["key"]}]"}
                            type="email"
                            label={field_def["label"]}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                        <% "url" -> %>
                          <.input
                            name={"custom_fields[#{field_def["key"]}]"}
                            type="url"
                            label={field_def["label"]}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                        <% "date" -> %>
                          <.input
                            name={"custom_fields[#{field_def["key"]}]"}
                            type="date"
                            label={field_def["label"]}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                        <% "select" -> %>
                          <.select
                            name={"custom_fields[#{field_def["key"]}]"}
                            label={field_def["label"]}
                            options={Enum.map(field_def["options"], &{&1, &1})}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                        <% _ -> %>
                          <!-- Fallback for unknown field types -->
                          <.input
                            name={"custom_fields[#{field_def["key"]}]"}
                            type="text"
                            label={field_def["label"]}
                            value={
                              get_in(@phoenix_kit_current_user.custom_fields, [field_def["key"]]) ||
                                field_def["default"]
                            }
                            required={field_def["required"]}
                          />
                      <% end %>
                    <% end %>
                  <% end %>

                  <div id="timezone-detector">
                    <.select
                      field={@profile_form[:user_timezone]}
                      label="Personal Timezone"
                      options={@timezone_options}
                    />
                    
    <!-- Timezone Mismatch Warning -->
                    <%= if assigns[:timezone_mismatch_warning] do %>
                      <div class="alert alert-warning text-sm mt-2">
                        <.icon
                          name="hero-exclamation-triangle"
                          class="stroke-current shrink-0 h-5 w-5"
                        />
                        <div>
                          <div class="font-semibold">Timezone Mismatch Detected</div>
                          <div class="text-xs">
                            {@timezone_mismatch_warning}
                          </div>
                        </div>
                      </div>
                    <% end %>
                    
    <!-- Browser Timezone Info -->
                    <%= if assigns[:browser_timezone_name] do %>
                      <div class="text-xs text-base-content/60 mt-1">
                        Browser detected: {@browser_timezone_name} ({@browser_timezone_offset})
                      </div>
                    <% end %>
                    
    <!-- Debug button for timezone detection -->
                    <div class="mt-2">
                      <button
                        type="button"
                        class="btn btn-sm btn-outline"
                        onclick="detectAndStoreTimezone(); return false;"
                      >
                        🐛 Detect Browser Timezone (Debug)
                      </button>
                      <div class="text-xs text-base-content/60 mt-1">
                        Click if timezone detection isn't working automatically
                      </div>
                    </div>
                  </div>
                  <:actions>
                    <.button
                      phx-disable-with="Updating..."
                      class="btn-primary"
                    >
                      <.icon name="hero-user" class="w-4 h-4 mr-2" /> Update Profile
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Email Settings Card -->
            <div class="card bg-base-100 shadow-sm border border-base-300">
              <div class="card-body">
                <h2 class="card-title flex items-center gap-2">
                  <.icon name="hero-envelope" class="w-5 h-5" /> Email Address
                </h2>
                <p class="text-sm text-base-content/60 mb-4">Change your account email address</p>
                
    <!-- Email Success Message -->
                <%= if @email_success_message do %>
                  <div class="alert alert-success text-sm mb-4">
                    <.icon name="hero-check" class="stroke-current shrink-0 h-5 w-5" />
                    <span>{@email_success_message}</span>
                  </div>
                <% end %>
                
    <!-- Email Error Message -->
                <%= if @email_error_message do %>
                  <div class="alert alert-error text-sm mb-4">
                    <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-5 w-5" />
                    <span>{@email_error_message}</span>
                  </div>
                <% end %>

                <.simple_form
                  for={@email_form}
                  id="email_form"
                  phx-submit="update_email"
                  phx-change="validate_email"
                >
                  <.input
                    field={@email_form[:email]}
                    type="email"
                    label="Email"
                    required
                  />
                  <.input
                    field={@email_form[:current_password]}
                    name="current_password"
                    id="current_password_for_email"
                    type="password"
                    label="Current password"
                    value={@email_form_current_password}
                    required
                  />
                  <:actions>
                    <.button
                      phx-disable-with="Changing..."
                      class="btn-primary"
                    >
                      <.icon name="hero-envelope" class="w-4 h-4 mr-2" /> Change Email
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Password Settings Card -->
            <div class="card bg-base-100 shadow-sm border border-base-300">
              <div class="card-body">
                <h2 class="card-title flex items-center gap-2">
                  <.icon name="hero-lock-closed" class="w-5 h-5" /> Password
                </h2>
                <p class="text-sm text-base-content/60 mb-4">Update your account password</p>
                
    <!-- Password Success Message -->
                <%= if @password_success_message do %>
                  <div class="alert alert-success text-sm mb-4">
                    <.icon name="hero-check" class="stroke-current shrink-0 h-5 w-5" />
                    <span>{@password_success_message}</span>
                  </div>
                <% end %>
                
    <!-- Password Error Message -->
                <%= if @password_error_message do %>
                  <div class="alert alert-error text-sm mb-4">
                    <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-5 w-5" />
                    <span>{@password_error_message}</span>
                  </div>
                <% end %>

                <.simple_form
                  for={@password_form}
                  id="password_form"
                  action={Routes.path("/users/log-in?_action=password_updated")}
                  method="post"
                  phx-change="validate_password"
                  phx-submit="update_password"
                  phx-trigger-action={@trigger_submit}
                >
                  <input
                    name={@password_form[:email].name}
                    type="hidden"
                    id="hidden_user_email"
                    value={@current_email}
                  />
                  <.input
                    field={@password_form[:password]}
                    type="password"
                    label="New password"
                    required
                  />
                  <.input
                    field={@password_form[:password_confirmation]}
                    type="password"
                    label="Confirm new password"
                  />
                  <.input
                    field={@password_form[:current_password]}
                    name="current_password"
                    type="password"
                    label="Current password"
                    id="current_password_for_password"
                    value={@current_password}
                    required
                  />
                  <:actions>
                    <.button
                      phx-disable-with="Changing..."
                      class="btn-primary"
                    >
                      <.icon name="hero-lock-closed" class="w-4 h-4 mr-2" /> Change Password
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
          </div>
          
    <!-- Right Column -->
          <div class="space-y-6">
            <!-- Connected Accounts Card -->
            <%= if @oauth_available do %>
              <div class="card bg-base-100 shadow-sm border border-base-300">
                <div class="card-body">
                  <h2 class="card-title flex items-center gap-2">
                    <.icon name="hero-link" class="w-5 h-5" /> Connected Accounts
                  </h2>
                  <p class="text-sm text-base-content/60 mb-4">
                    Manage OAuth providers for quick sign-in
                  </p>
                  
    <!-- OAuth Success Message -->
                  <%= if @oauth_success_message do %>
                    <div class="alert alert-success text-sm mb-4">
                      <.icon name="hero-check" class="stroke-current shrink-0 h-5 w-5" />
                      <span>{@oauth_success_message}</span>
                    </div>
                  <% end %>
                  
    <!-- OAuth Error Message -->
                  <%= if @oauth_error_message do %>
                    <div class="alert alert-error text-sm mb-4">
                      <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-5 w-5" />
                      <span>{@oauth_error_message}</span>
                    </div>
                  <% end %>
                  
    <!-- Connected Providers List -->
                  <%= if length(@oauth_providers) > 0 do %>
                    <div class="space-y-3 mb-4">
                      <h3 class="font-semibold text-sm text-base-content/70">Connected Providers</h3>
                      <%= for provider <- @oauth_providers do %>
                        <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                          <div class="flex items-center gap-3">
                            <%= case provider.provider do %>
                              <% "google" -> %>
                                <.icon name="hero-globe-alt" class="w-6 h-6" />
                              <% "apple" -> %>
                                <.icon name="hero-device-phone-mobile" class="w-6 h-6" />
                              <% "github" -> %>
                                <.icon name="hero-code-bracket" class="w-6 h-6" />
                              <% _ -> %>
                                <.icon name="hero-link" class="w-6 h-6" />
                            <% end %>
                            <div>
                              <div class="font-semibold">
                                {format_provider_name(provider.provider)}
                              </div>
                              <div class="text-xs text-base-content/60">
                                {provider.provider_email || @current_email}
                              </div>
                            </div>
                          </div>
                          <button
                            type="button"
                            phx-click="disconnect_oauth_provider"
                            phx-value-provider={provider.provider}
                            class="btn btn-sm btn-outline btn-error"
                            data-confirm="Are you sure you want to disconnect this account? You won't be able to sign in with it anymore."
                          >
                            <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Disconnect
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="alert alert-info text-sm mb-4">
                      <.icon name="hero-information-circle" class="stroke-current shrink-0 h-5 w-5" />
                      <span>
                        You don't have any OAuth providers connected yet. Connect one for faster sign-in.
                      </span>
                    </div>
                  <% end %>
                  
    <!-- Available Providers to Connect -->
                  <%= if length(@available_providers) > 0 do %>
                    <div class="space-y-3">
                      <h3 class="font-semibold text-sm text-base-content/70">
                        Connect Additional Providers
                      </h3>
                      <div class="space-y-2">
                        <%= for provider <- @available_providers do %>
                          <button
                            type="button"
                            phx-click="connect_oauth_provider"
                            phx-value-provider={provider}
                            class="btn btn-outline w-full flex items-center justify-start gap-3"
                          >
                            <%= case provider do %>
                              <% "google" -> %>
                                <.icon name="hero-globe-alt" class="w-5 h-5" />
                                <span>Connect Google Account</span>
                              <% "apple" -> %>
                                <.icon name="hero-device-phone-mobile" class="w-5 h-5" />
                                <span>Connect Apple Account</span>
                              <% "github" -> %>
                                <.icon name="hero-code-bracket" class="w-5 h-5" />
                                <span>Connect GitHub Account</span>
                              <% _ -> %>
                                <.icon name="hero-link" class="w-5 h-5" />
                                <span>Connect {format_provider_name(provider)}</span>
                            <% end %>
                          </button>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                  
    <!-- Password Warning for OAuth-only Users -->
                  <%= if length(@oauth_providers) > 0 and @phoenix_kit_current_user.hashed_password == nil do %>
                    <div class="alert alert-warning text-sm mt-4">
                      <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-5 w-5" />
                      <div>
                        <div class="font-semibold">No Password Set</div>
                        <div class="text-xs">
                          You signed up using OAuth. Consider setting a password above as a backup sign-in method.
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end
end
