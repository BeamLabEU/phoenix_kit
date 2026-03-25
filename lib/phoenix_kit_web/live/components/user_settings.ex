defmodule PhoenixKitWeb.Live.Components.UserSettings do
  @moduledoc """
  Reusable LiveComponent for user settings management.

  Provides profile, email, password, and OAuth settings in a self-contained
  component that can be embedded in any LiveView.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Live.Components.UserSettings}
        id="user-settings"
        user={@current_user}
      />

  ## Required assigns

    * `user` — the current user struct
    * `id` — unique component ID

  ## Optional assigns

    * `sections` — list of sections to display: `:identity`, `:custom_fields`, `:email`, `:password`, `:oauth`
      (default: all five). `:profile` is accepted as a legacy alias that expands to `[:identity, :custom_fields]`
    * `email_confirm_url_fn` — `(token -> url)` for email confirmation links
      (default: `&Routes.url("/dashboard/settings/confirm-email/\#{&1}")`)
    * `return_to` — where OAuth redirect returns to (default: `"/dashboard/settings"`)

  ## Parent notifications

  Sends `{:phoenix_kit_user_updated, updated_user}` to the parent LiveView
  when user data changes (profile, avatar, email, password).
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.OAuth
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Utils.Routes

  @default_sections [:identity, :custom_fields, :email, :password, :oauth]

  @impl true
  def update(%{action: :check_avatar_uploads_complete}, socket) do
    entries = socket.assigns.uploads.avatar.entries

    Logger.info(
      "check_avatar_uploads_complete: entries=#{length(entries)}, done?=#{inspect(Enum.map(entries, & &1.done?))}"
    )

    if entries != [] && Enum.all?(entries, & &1.done?) do
      Logger.info("Avatar uploads done! Processing...")
      process_avatar_uploads(socket)
    else
      Logger.info("Still uploading avatar, checking again...")

      send_update_after(
        __MODULE__,
        %{id: socket.assigns.id, action: :check_avatar_uploads_complete},
        500
      )

      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    user = assigns[:user] || socket.assigns[:user]
    sections = assigns[:sections] || socket.assigns[:sections] || @default_sections

    # Expand legacy :profile into fine-grained sections for backward compatibility
    sections =
      Enum.flat_map(sections, fn
        :profile -> [:identity, :custom_fields]
        other -> [other]
      end)

    email_confirm_url_fn =
      assigns[:email_confirm_url_fn] || socket.assigns[:email_confirm_url_fn] ||
        (&Routes.url("/dashboard/settings/confirm-email/#{&1}"))

    return_to = assigns[:return_to] || socket.assigns[:return_to] || "/dashboard/settings"

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:user, user)
      |> assign(:sections, sections)
      |> assign(:email_confirm_url_fn, email_confirm_url_fn)
      |> assign(:return_to, return_to)
      |> assign_new(:profile_success_message, fn -> nil end)
      |> assign_new(:email_success_message, fn -> assigns[:email_success_message] end)
      |> assign_new(:email_error_message, fn -> assigns[:email_error_message] end)
      |> assign_new(:password_success_message, fn -> nil end)
      |> assign_new(:password_error_message, fn -> nil end)
      |> assign_new(:oauth_success_message, fn -> nil end)
      |> assign_new(:oauth_error_message, fn -> nil end)
      |> assign_new(:avatar_success_message, fn -> nil end)
      |> assign_new(:avatar_error_message, fn -> nil end)
      |> assign_new(:current_password, fn -> nil end)
      |> assign_new(:email_form_current_password, fn -> nil end)
      |> assign_new(:current_email, fn -> user.email end)
      |> assign_new(:email_form, fn -> to_form(Auth.change_user_email(user)) end)
      |> assign_new(:password_form, fn -> to_form(Auth.change_user_password(user)) end)
      |> assign_new(:profile_form, fn -> to_form(Auth.change_user_profile(user)) end)
      |> assign_new(:timezone_options, fn ->
        setting_options = Settings.get_setting_options()
        [{"Use System Default", nil} | setting_options["time_zone"]]
      end)
      |> assign_new(:browser_timezone_name, fn -> nil end)
      |> assign_new(:browser_timezone_offset, fn -> nil end)
      |> assign_new(:timezone_mismatch_warning, fn -> nil end)
      |> assign_new(:trigger_submit, fn -> false end)
      |> assign_new(:oauth_providers, fn -> OAuth.get_user_oauth_providers(user.uuid) end)
      |> assign_new(:oauth_available, fn -> OAuthAvailability.oauth_available?() end)
      |> assign_new(:available_providers, fn ->
        oauth_providers = OAuth.get_user_oauth_providers(user.uuid)
        get_available_oauth_providers(oauth_providers)
      end)
      |> assign_new(:custom_field_definitions, fn ->
        CustomFields.list_user_accessible_field_definitions()
      end)
      |> assign_new(:last_uploaded_avatar_uuid, fn -> nil end)
      |> assign_new(:show_email_form, fn -> false end)
      |> assign_new(:show_password_form, fn -> false end)
      |> maybe_allow_upload()

    {:ok, socket}
  end

  defp maybe_allow_upload(socket) do
    if socket.assigns[:uploads] && socket.assigns.uploads[:avatar] do
      socket
    else
      allow_upload(socket, :avatar,
        accept: ["image/*"],
        max_entries: 1,
        max_file_size: 10_000_000,
        auto_upload: true
      )
    end
  end

  # Event handlers

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.user
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
    user = socket.assigns.user

    case Auth.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          socket.assigns.email_confirm_url_fn
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
      socket.assigns.user
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
    user = socket.assigns.user

    case Auth.update_user_password(user, password, user_params) do
      {:ok, user} ->
        password_form =
          user
          |> Auth.change_user_password(user_params)
          |> to_form()

        send(self(), {:phoenix_kit_user_updated, user})

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

    socket =
      if params["_target"] == ["avatar"] do
        entries = socket.assigns.uploads.avatar.entries

        if entries != [] do
          send_update_after(
            __MODULE__,
            %{id: socket.assigns.id, action: :check_avatar_uploads_complete},
            500
          )
        end

        socket
      else
        socket
      end

    socket =
      case {params["browser_timezone_name"], params["browser_timezone_offset"]} do
        {name, offset} when is_binary(name) and is_binary(offset) ->
          socket
          |> assign(:browser_timezone_name, name)
          |> assign(:browser_timezone_offset, offset)

        _ ->
          socket
      end

    merged_params = merge_custom_fields(params, user_params)

    profile_form =
      socket.assigns.user
      |> Auth.change_user_profile(merged_params)
      |> Map.put(:action, :validate)
      |> to_form()

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
    user = socket.assigns.user

    merged_params = merge_custom_fields_for_save(params, user_params, user)

    case Auth.update_user_profile(user, merged_params) do
      {:ok, updated_user} ->
        send(self(), {:phoenix_kit_user_updated, updated_user})

        socket =
          socket
          |> assign(:user, updated_user)
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
      user = socket.assigns.user
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
    return_to = socket.assigns.return_to
    oauth_url = Routes.url("/users/auth/#{provider}?return_to=#{return_to}")

    socket =
      socket
      |> assign(:oauth_info_message, "Redirecting to #{format_provider_name(provider)}...")
      |> redirect(external: oauth_url)

    {:noreply, socket}
  end

  def handle_event("disconnect_oauth_provider", %{"provider" => provider}, socket) do
    user = socket.assigns.user

    if can_disconnect_provider?(user, provider) do
      case OAuth.unlink_oauth_provider(user.uuid, provider) do
        {:ok, _} ->
          oauth_providers = OAuth.get_user_oauth_providers(user.uuid)
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

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("toggle_email_form", _params, socket) do
    {:noreply, assign(socket, :show_email_form, not socket.assigns.show_email_form)}
  end

  def handle_event("toggle_password_form", _params, socket) do
    {:noreply, assign(socket, :show_password_form, not socket.assigns.show_password_form)}
  end

  # Private helpers

  defp check_timezone_mismatch(socket, selected_timezone) do
    browser_offset = socket.assigns[:browser_timezone_offset]
    browser_name = socket.assigns[:browser_timezone_name]

    user_timezone =
      selected_timezone ||
        get_in(socket.assigns.profile_form.params, ["user_timezone"]) ||
        socket.assigns.user.user_timezone

    case {browser_offset, user_timezone} do
      {nil, _} ->
        assign(socket, :timezone_mismatch_warning, nil)

      {browser_tz, nil} when browser_tz != "0" ->
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
        normalized_user_tz = String.replace(user_tz, "+", "")
        normalized_browser_tz = String.replace(browser_tz, "+", "")

        if normalized_browser_tz != normalized_user_tz do
          warning_msg =
            "Your browser timezone appears to be #{browser_name} (#{format_timezone_offset(browser_tz)}) " <>
              "but you selected #{format_timezone_offset(user_tz)}. Please verify this is correct."

          assign(socket, :timezone_mismatch_warning, warning_msg)
        else
          assign(socket, :timezone_mismatch_warning, nil)
        end

      _ ->
        assign(socket, :timezone_mismatch_warning, nil)
    end
  end

  defp format_timezone_offset(offset) do
    case offset do
      "0" ->
        "UTC+0"

      "+" <> _ ->
        "UTC" <> offset

      "-" <> _ ->
        "UTC" <> offset

      _ when is_binary(offset) ->
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

  defp get_available_oauth_providers(oauth_providers) do
    connected = Enum.map(oauth_providers, & &1.provider)
    all_providers = ["google", "apple", "github"]

    all_providers
    |> Enum.reject(&(&1 in connected))
    |> Enum.filter(&provider_enabled?/1)
  end

  defp provider_enabled?("google"), do: OAuthAvailability.provider_enabled?(:google)
  defp provider_enabled?("apple"), do: OAuthAvailability.provider_enabled?(:apple)
  defp provider_enabled?("github"), do: OAuthAvailability.provider_enabled?(:github)
  defp provider_enabled?(_), do: false

  defp can_disconnect_provider?(user, _provider) do
    has_password = user.hashed_password != nil
    oauth_count = length(OAuth.get_user_oauth_providers(user.uuid))
    has_password or oauth_count > 1
  end

  defp extract_custom_fields(params) do
    get_in(params, ["profile_form", "user", "custom_fields"])
  end

  defp merge_custom_fields(params, user_params) do
    case extract_custom_fields(params) do
      custom_fields when is_map(custom_fields) ->
        Map.put(user_params, "custom_fields", custom_fields)

      _ ->
        user_params
    end
  end

  # Merges form custom fields on top of all existing user custom fields for persistence.
  # Ensures fields not present in the form (e.g. avatar_file_uuid, programmatic fields)
  # are preserved when saving.
  defp merge_custom_fields_for_save(params, user_params, user) do
    existing = user.custom_fields || %{}

    case extract_custom_fields(params) do
      form_fields when is_map(form_fields) ->
        Map.put(user_params, "custom_fields", Map.merge(existing, form_fields))

      _ when map_size(existing) > 0 ->
        Map.put(user_params, "custom_fields", existing)

      _ ->
        user_params
    end
  end

  defp format_provider_name("google"), do: "Google"
  defp format_provider_name("apple"), do: "Apple"
  defp format_provider_name("github"), do: "GitHub"
  defp format_provider_name(provider), do: String.capitalize(provider)

  defp process_avatar_uploads(socket) do
    uploaded_avatars =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
        current_user = socket.assigns.user
        user_uuid = current_user.uuid

        {:ok, stat} = Elixir.File.stat(path)
        file_size = stat.size
        file_hash = Auth.calculate_file_hash(path)

        case Storage.store_file_in_buckets(
               path,
               "image",
               user_uuid,
               file_hash,
               ext,
               entry.client_name
             ) do
          {:ok, file, :duplicate} ->
            Logger.info("Avatar file is duplicate with ID: #{file.uuid}")

            {:ok,
             %{
               file_uuid: file.uuid,
               filename: entry.client_name,
               size: file_size,
               duplicate: true
             }}

          {:ok, file} ->
            Logger.info("Avatar file stored with ID: #{file.uuid}")

            {:ok,
             %{
               file_uuid: file.uuid,
               filename: entry.client_name,
               size: file_size
             }}

          {:error, reason} ->
            Logger.error("Storage Error: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    Logger.info("Uploaded avatars: #{inspect(uploaded_avatars)}")
    avatar_file_uuids = Enum.map(uploaded_avatars, &get_avatar_file_uuid/1)
    Logger.info("Avatar file UUIDs: #{inspect(avatar_file_uuids)}")
    avatar_file_uuid = List.first(avatar_file_uuids)
    Logger.info("First avatar file UUID: #{inspect(avatar_file_uuid)}")

    socket =
      if avatar_file_uuid && avatar_file_uuid != nil do
        user = socket.assigns.user

        case Auth.update_user_fields(user, %{"avatar_file_uuid" => avatar_file_uuid}) do
          {:ok, updated_user} ->
            Logger.info("Avatar file UUID saved: #{avatar_file_uuid}")
            send(self(), {:phoenix_kit_user_updated, updated_user})

            socket
            |> assign(:user, updated_user)
            |> assign(:last_uploaded_avatar_uuid, avatar_file_uuid)
            |> assign(:avatar_success_message, gettext("Avatar uploaded successfully!"))
            |> assign(:avatar_error_message, nil)

          {:error, changeset} ->
            Logger.error("Failed to save avatar file UUID: #{inspect(changeset)}")

            socket
            |> assign(:last_uploaded_avatar_uuid, avatar_file_uuid)
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

    {:ok, socket}
  end

  defp get_avatar_file_uuid(%{file_uuid: file_uuid}), do: file_uuid
  defp get_avatar_file_uuid({:ok, %{file_uuid: file_uuid}}), do: file_uuid
  defp get_avatar_file_uuid(_), do: nil

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm max-w-4xl mx-auto">
      <div class="card-body">
        <%!-- Identity Section (avatar, name, username, timezone) --%>
        <%= if :identity in @sections do %>
          <div>
            <%!-- Success Message --%>
            <%= if @profile_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@profile_success_message}</span>
              </div>
            <% end %>

            <%!-- Avatar Upload Messages --%>
            <%= if @last_uploaded_avatar_uuid do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>Avatar uploaded successfully!</span>
              </div>
            <% end %>
            <%= if @avatar_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@avatar_error_message}</span>
              </div>
            <% end %>

            <%!-- Identity Form with Avatar --%>
            <.simple_form
              for={@profile_form}
              id={"#{@id}-profile-form"}
              phx-submit="update_profile"
              phx-change="validate_profile"
              phx-target={@myself}
            >
              <div class="flex flex-col gap-6 lg:flex-row lg:gap-4 lg:items-start">
                <%!-- Avatar Section --%>
                <div class="flex flex-col items-center gap-2 mx-auto lg:mx-0">
                  <%= if get_in(@user.custom_fields, ["avatar_file_uuid"]) do %>
                    <% avatar_url =
                      PhoenixKit.Modules.Storage.URLSigner.signed_url(
                        get_in(@user.custom_fields, ["avatar_file_uuid"]),
                        "thumbnail"
                      ) %>
                    <img
                      src={avatar_url}
                      alt="Avatar"
                      class="w-40 h-40 rounded-full object-cover border-2 border-primary"
                    />
                  <% else %>
                    <div class="w-40 h-40 rounded-full bg-primary/10 border-2 border-primary flex items-center justify-center">
                      <span class="text-5xl font-bold text-primary">
                        {String.upcase(String.at(@user.email, 0))}
                      </span>
                    </div>
                  <% end %>
                  <.file_upload
                    upload={@uploads.avatar}
                    variant="button"
                    label="Upload"
                  />
                </div>

                <%!-- Name Fields --%>
                <div class="flex-1 grid grid-cols-1 lg:grid-cols-2 gap-3 w-full">
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
                  <div class="col-span-1 lg:col-span-2">
                    <.input
                      field={@profile_form[:username]}
                      type="text"
                      label="Username"
                    />
                  </div>
                </div>
              </div>

              <%!-- Timezone Section --%>
              <div id={"#{@id}-timezone-detector"}>
                <.select
                  field={@profile_form[:user_timezone]}
                  label="Personal Timezone"
                  options={@timezone_options}
                />

                <%= if assigns[:timezone_mismatch_warning] do %>
                  <div class="alert alert-warning text-sm mt-2">
                    <.icon
                      name="hero-exclamation-triangle"
                      class="stroke-current shrink-0 h-4 w-4"
                    />
                    <div>
                      <div class="font-semibold">Timezone Mismatch Detected</div>
                      <div class="text-xs">
                        {@timezone_mismatch_warning}
                      </div>
                    </div>
                  </div>
                <% end %>

                <%= if assigns[:browser_timezone_name] do %>
                  <div class="text-xs text-base-content/60 mt-1">
                    Browser detected: {@browser_timezone_name} ({@browser_timezone_offset})
                  </div>
                <% end %>
              </div>

              <:actions>
                <div class="ml-auto">
                  <.button phx-disable-with="Updating..." class="btn-primary">
                    Update Profile
                  </.button>
                </div>
              </:actions>
            </.simple_form>
            <%= if Enum.any?([:custom_fields, :email, :password, :oauth], & &1 in @sections) do %>
              <div class="divider"></div>
            <% end %>
          </div>
        <% end %>

        <%!-- Custom Fields Section --%>
        <%= if :custom_fields in @sections and length(@custom_field_definitions) > 0 do %>
          <div>
            <.simple_form
              for={@profile_form}
              id={"#{@id}-custom-fields-form"}
              phx-submit="update_profile"
              phx-change="validate_profile"
              phx-target={@myself}
            >
              <%= if :identity in @sections do %>
                <div class="divider text-sm text-base-content/60">Additional Information</div>
              <% else %>
                <h2 class="text-lg font-semibold mb-2">Additional Information</h2>
              <% end %>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
                <%= for field <- @custom_field_definitions do %>
                  <% field_name = "profile_form[user][custom_fields][#{field["key"]}]" %>
                  <% field_value =
                    get_in(@user.custom_fields, [field["key"]]) || field["default"] || "" %>
                  <div class="col-span-1 lg:col-span-2">
                    <%= case field["type"] do %>
                      <% "select" -> %>
                        <.select
                          name={field_name}
                          label={field["label"]}
                          options={
                            Enum.map(field["options"] || [], fn opt ->
                              if is_binary(opt),
                                do: {opt, opt},
                                else: {opt["label"], opt["value"]}
                            end)
                          }
                          value={field_value}
                          required={field["required"]}
                        />
                      <% "textarea" -> %>
                        <.textarea
                          name={field_name}
                          label={field["label"]}
                          value={field_value}
                          required={field["required"]}
                        />
                      <% "number" -> %>
                        <.input
                          name={field_name}
                          type="number"
                          label={field["label"]}
                          value={field_value}
                          required={field["required"]}
                        />
                      <% "email" -> %>
                        <.input
                          name={field_name}
                          type="email"
                          label={field["label"]}
                          value={field_value}
                          required={field["required"]}
                        />
                      <% "url" -> %>
                        <.input
                          name={field_name}
                          type="url"
                          label={field["label"]}
                          value={field_value}
                          required={field["required"]}
                        />
                      <% "date" -> %>
                        <.input
                          name={field_name}
                          type="date"
                          label={field["label"]}
                          value={field_value}
                          required={field["required"]}
                        />
                      <% _ -> %>
                        <.input
                          name={field_name}
                          type="text"
                          label={field["label"]}
                          value={field_value}
                          required={field["required"]}
                        />
                    <% end %>
                  </div>
                <% end %>
              </div>

              <:actions>
                <div class="ml-auto">
                  <.button phx-disable-with="Updating..." class="btn-primary">
                    Update Custom Fields
                  </.button>
                </div>
              </:actions>
            </.simple_form>
            <%= if Enum.any?([:email, :password, :oauth], & &1 in @sections) do %>
              <div class="divider"></div>
            <% end %>
          </div>
        <% end %>

        <%!-- Email Section --%>
        <%= if :email in @sections do %>
          <div>
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-envelope" class="w-5 h-5 text-primary" /> Email Address
              </h2>
              <button
                type="button"
                phx-click="toggle_email_form"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                <.icon
                  name={if @show_email_form, do: "hero-x-mark", else: "hero-pencil"}
                  class="w-4 h-4"
                />
                {if @show_email_form, do: "Cancel", else: "Change Email"}
              </button>
            </div>

            <div class="text-sm text-base-content/60 mb-4">{@current_email}</div>

            <%= if @email_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@email_success_message}</span>
              </div>
            <% end %>
            <%= if @email_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@email_error_message}</span>
              </div>
            <% end %>

            <%= if @show_email_form do %>
              <.simple_form
                for={@email_form}
                id={"#{@id}-email-form"}
                phx-submit="update_email"
                phx-change="validate_email"
                phx-target={@myself}
              >
                <.input
                  field={@email_form[:email]}
                  type="email"
                  label="New Email"
                  required
                />
                <.input
                  field={@email_form[:current_password]}
                  name="current_password"
                  id={"#{@id}-current-password-for-email"}
                  type="password"
                  label="Current Password"
                  value={@email_form_current_password}
                  required
                />
                <:actions>
                  <div class="ml-auto">
                    <.button phx-disable-with="Changing..." class="btn-primary">
                      Update Email
                    </.button>
                  </div>
                </:actions>
              </.simple_form>
            <% end %>
          </div>
        <% end %>

        <%= if :email in @sections and Enum.any?([:password, :oauth], & &1 in @sections) do %>
          <div class="divider"></div>
        <% end %>

        <%!-- Password Section --%>
        <%= if :password in @sections do %>
          <div>
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-lock-closed" class="w-5 h-5 text-primary" /> Password
              </h2>
              <button
                type="button"
                phx-click="toggle_password_form"
                phx-target={@myself}
                class="btn btn-sm btn-outline"
              >
                <.icon
                  name={if @show_password_form, do: "hero-x-mark", else: "hero-pencil"}
                  class="w-4 h-4"
                />
                {if @show_password_form, do: "Cancel", else: "Change Password"}
              </button>
            </div>

            <div class="text-sm text-base-content/60 mb-4">••••••••</div>

            <%= if @password_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@password_success_message}</span>
              </div>
            <% end %>
            <%= if @password_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@password_error_message}</span>
              </div>
            <% end %>

            <%= if @show_password_form do %>
              <.simple_form
                for={@password_form}
                id={"#{@id}-password-form"}
                action={Routes.path("/users/log-in?_action=password_updated")}
                method="post"
                phx-change="validate_password"
                phx-submit="update_password"
                phx-trigger-action={@trigger_submit}
                phx-target={@myself}
              >
                <input
                  name={@password_form[:email].name}
                  type="hidden"
                  id={"#{@id}-hidden-user-email"}
                  value={@current_email}
                />
                <.input
                  field={@password_form[:password]}
                  type="password"
                  label="New Password"
                  required
                />
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  label="Confirm New Password"
                />
                <.input
                  field={@password_form[:current_password]}
                  name="current_password"
                  type="password"
                  label="Current Password"
                  id={"#{@id}-current-password-for-password"}
                  value={@current_password}
                  required
                />
                <:actions>
                  <div class="ml-auto">
                    <.button phx-disable-with="Changing..." class="btn-primary">
                      Update Password
                    </.button>
                  </div>
                </:actions>
              </.simple_form>
            <% end %>
          </div>
        <% end %>

        <%!-- OAuth Section --%>
        <%= if :oauth in @sections and @oauth_available do %>
          <div class="divider"></div>
          <div>
            <h2 class="text-lg font-semibold flex items-center gap-2 mb-4">
              <.icon name="hero-link" class="w-5 h-5 text-primary" /> Connected Accounts
            </h2>

            <%= if @oauth_success_message do %>
              <div class="alert alert-success text-sm mb-4">
                <.icon name="hero-check" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@oauth_success_message}</span>
              </div>
            <% end %>
            <%= if @oauth_error_message do %>
              <div class="alert alert-error text-sm mb-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <span>{@oauth_error_message}</span>
              </div>
            <% end %>

            <%!-- Connected Providers --%>
            <%= if length(@oauth_providers) > 0 do %>
              <div class="space-y-2 mb-4">
                <%= for provider <- @oauth_providers do %>
                  <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                    <div class="flex items-center gap-3">
                      <%= case provider.provider do %>
                        <% "google" -> %>
                          <.icon name="hero-globe-alt" class="w-5 h-5" />
                        <% "apple" -> %>
                          <.icon name="hero-device-phone-mobile" class="w-5 h-5" />
                        <% "github" -> %>
                          <.icon name="hero-code-bracket" class="w-5 h-5" />
                        <% _ -> %>
                          <.icon name="hero-link" class="w-5 h-5" />
                      <% end %>
                      <div>
                        <span class="font-medium">{format_provider_name(provider.provider)}</span>
                        <div class="text-xs text-base-content/60">
                          {provider.provider_email || @current_email}
                        </div>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="disconnect_oauth_provider"
                      phx-target={@myself}
                      phx-value-provider={provider.provider}
                      class="btn btn-sm btn-outline btn-error"
                      data-confirm="Are you sure you want to disconnect this account? You won't be able to sign in with it anymore."
                    >
                      Disconnect
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Available Providers --%>
            <%= if length(@available_providers) > 0 do %>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <%= for provider <- @available_providers do %>
                  <button
                    type="button"
                    phx-click="connect_oauth_provider"
                    phx-target={@myself}
                    phx-value-provider={provider}
                    class="btn btn-outline"
                  >
                    <.icon name="hero-plus" class="w-4 h-4 mr-1" />
                    Connect {format_provider_name(provider)}
                  </button>
                <% end %>
              </div>
            <% end %>

            <%!-- Password Warning for OAuth-only Users --%>
            <%= if length(@oauth_providers) > 0 and @user.hashed_password == nil do %>
              <div class="alert alert-warning text-sm mt-4">
                <.icon name="hero-exclamation-triangle" class="stroke-current shrink-0 h-4 w-4" />
                <div>
                  <div class="font-semibold">No Password Set</div>
                  <div class="text-xs">
                    You signed up using OAuth. Consider setting a password above as a backup sign-in method.
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
