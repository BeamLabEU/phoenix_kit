defmodule PhoenixKitWeb.Users.SettingsLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Account Settings"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh]">
        <div class="w-full max-w-lg px-4">
          <div class="text-center mb-8">
            <div class="flex items-center justify-center mb-4">
              <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-12 h-12 text-primary" />
            </div>
            <h1 class="text-3xl font-bold mb-2">Account Settings</h1>
            <p class="text-base-content/60 text-sm">
              Manage your account email address and password settings
            </p>
          </div>

          <div class="space-y-8">
            <!-- Email Settings Card -->
            <div class="card bg-base-100 shadow-2xl">
              <div class="card-body">
                <div class="flex items-center mb-4">
                  <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-6 h-6 text-primary mr-3" />
                  <div>
                    <h2 class="text-xl font-bold">Email Address</h2>
                    <p class="text-sm text-base-content/60">Change your account email address</p>
                  </div>
                </div>

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
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input
                    field={@email_form[:current_password]}
                    name="current_password"
                    id="current_password_for_email"
                    type="password"
                    label="Current password"
                    value={@email_form_current_password}
                    required
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <:actions>
                    <.button
                      phx-disable-with="Changing..."
                      class="btn-primary transition-all hover:scale-[1.02] active:scale-[0.98]"
                    >
                      <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-5 h-5 mr-2" />
                      Change Email
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Profile Settings Card -->
            <div class="card bg-base-100 shadow-2xl">
              <div class="card-body">
                <div class="flex items-center mb-4">
                  <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-6 h-6 text-primary mr-3" />
                  <div>
                    <h2 class="text-xl font-bold">Profile Information</h2>
                    <p class="text-sm text-base-content/60">Update your personal information</p>
                  </div>
                </div>

                <.simple_form
                  for={@profile_form}
                  id="profile_form"
                  phx-submit="update_profile"
                  phx-change="validate_profile"
                >
                  <.input
                    field={@profile_form[:first_name]}
                    type="text"
                    label="First Name"
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input field={@profile_form[:last_name]} type="text" label="Last Name">
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <:actions>
                    <.button
                      phx-disable-with="Updating..."
                      class="btn-primary transition-all hover:scale-[1.02] active:scale-[0.98]"
                    >
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-5 h-5 mr-2" />
                      Update Profile
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Password Settings Card -->
            <div class="card bg-base-100 shadow-2xl">
              <div class="card-body">
                <div class="flex items-center mb-4">
                  <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-6 h-6 text-primary mr-3" />
                  <div>
                    <h2 class="text-xl font-bold">Password</h2>
                    <p class="text-sm text-base-content/60">Update your account password</p>
                  </div>
                </div>

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
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input
                    field={@password_form[:password_confirmation]}
                    type="password"
                    label="Confirm new password"
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input
                    field={@password_form[:current_password]}
                    name="current_password"
                    type="password"
                    label="Current password"
                    id="current_password_for_password"
                    value={@current_password}
                    required
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <:actions>
                    <.button
                      phx-disable-with="Changing..."
                      class="btn-primary transition-all hover:scale-[1.02] active:scale-[0.98]"
                    >
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-5 h-5 mr-2" />
                      Change Password
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Development Mode Notice -->
            <div :if={show_dev_notice?()} class="alert alert-info">
              <PhoenixKitWeb.Components.Core.Icons.icon_info class="stroke-current shrink-0 h-6 w-6" />
              <span>
                Development mode: Check
                <.link href="/dev/mailbox" class="font-semibold underline">mailbox</.link>
                for confirmation emails
              </span>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Auth.update_user_email(socket.assigns.phoenix_kit_current_user, token) do
        :ok ->
          put_flash(socket, :info, "Email changed successfully.")

        :error ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: Routes.path("/users/settings"))}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.phoenix_kit_current_user
    email_changeset = Auth.change_user_email(user)
    password_changeset = Auth.change_user_password(user)
    profile_changeset = Auth.change_user_profile(user)

    socket =
      socket
      |> assign(:current_password, nil)
      |> assign(:email_form_current_password, nil)
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form, email_form_current_password: password)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &Routes.url("/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info) |> assign(email_form_current_password: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form, current_password: password)}
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

        {:noreply, assign(socket, trigger_submit: true, password_form: password_form)}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end

  def handle_event("validate_profile", params, socket) do
    %{"user" => user_params} = params

    profile_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_profile(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, profile_form: profile_form)}
  end

  def handle_event("update_profile", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.update_user_profile(user, user_params) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, "Profile updated successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  defp show_dev_notice? do
    case Application.get_env(:phoenix_kit, PhoenixKit.Mailer)[:adapter] do
      Swoosh.Adapters.Local -> true
      _ -> false
    end
  end
end
