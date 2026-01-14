defmodule PhoenixKit.Modules.Shop.Web.CheckoutPage do
  @moduledoc """
  Checkout page LiveView for converting cart to order.
  Supports both logged-in users (with billing profiles) and guest checkout.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.BillingProfile
  alias PhoenixKit.Modules.Billing.CountryData
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, session, socket) do
    user = get_current_user(socket)
    session_id = session["shop_session_id"]
    user_id = if user, do: user.id

    case Shop.find_active_cart(user_id: user_id, session_id: session_id) do
      nil ->
        {:ok, redirect_to_cart(socket, "Your cart is empty")}

      cart ->
        handle_cart_validation(socket, cart, user)
    end
  end

  defp handle_cart_validation(socket, cart, user) do
    cond do
      Enum.empty?(cart.items) ->
        {:ok, redirect_to_cart(socket, "Your cart is empty")}

      is_nil(cart.shipping_method_id) ->
        {:ok, redirect_to_cart(socket, "Please select a shipping method")}

      true ->
        {:ok, setup_checkout_assigns(socket, cart, user)}
    end
  end

  defp setup_checkout_assigns(socket, cart, user) do
    is_guest = is_nil(user)
    billing_profiles = load_billing_profiles(user)
    {selected_profile, show_profile_prompt} = select_billing_profile(billing_profiles)

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    socket
    |> assign(:page_title, "Checkout")
    |> assign(:cart, cart)
    |> assign(:currency, Shop.get_default_currency())
    |> assign(:is_guest, is_guest)
    |> assign(:billing_profiles, billing_profiles)
    |> assign(:selected_profile_id, if(selected_profile, do: selected_profile.id))
    |> assign(:use_new_profile, is_guest or billing_profiles == [])
    |> assign(:show_profile_prompt, show_profile_prompt)
    |> assign(:billing_data, initial_billing_data(user, cart))
    |> assign(:countries, CountryData.list_countries())
    |> assign(:step, :billing)
    |> assign(:processing, false)
    |> assign(:error_message, nil)
    |> assign(:form_errors, %{})
    |> assign(:authenticated, authenticated)
  end

  # Select billing profile with smart defaults
  defp select_billing_profile([]), do: {nil, false}

  defp select_billing_profile(profiles) do
    default = Enum.find(profiles, & &1.is_default)

    cond do
      # Has default profile - use it
      default -> {default, false}
      # Only one profile - auto-select it
      length(profiles) == 1 -> {hd(profiles), false}
      # Multiple profiles without default - select first, show prompt
      true -> {hd(profiles), true}
    end
  end

  defp load_billing_profiles(nil), do: []
  defp load_billing_profiles(user), do: Billing.list_user_billing_profiles(user.id)

  defp initial_billing_data(user, cart) do
    %{
      "type" => "individual",
      "first_name" => "",
      "last_name" => "",
      "email" => if(user, do: user.email, else: ""),
      "phone" => "",
      "address_line1" => "",
      "city" => "",
      "postal_code" => "",
      "country" => cart.shipping_country || "EE"
    }
  end

  defp profile_to_billing_data(profile, cart) do
    %{
      "type" => profile.type || "individual",
      "first_name" => profile.first_name || "",
      "last_name" => profile.last_name || "",
      "email" => profile.email || "",
      "phone" => profile.phone || "",
      "address_line1" => profile.address_line1 || "",
      "city" => profile.city || "",
      "postal_code" => profile.postal_code || "",
      "country" => profile.country || cart.shipping_country || "EE"
    }
  end

  defp redirect_to_cart(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_navigate(to: Routes.path("/cart"))
  end

  @impl true
  def handle_event("select_profile", %{"profile_id" => profile_id}, socket) do
    profile_id = String.to_integer(profile_id)

    {:noreply,
     socket
     |> assign(:selected_profile_id, profile_id)
     |> assign(:use_new_profile, false)}
  end

  @impl true
  def handle_event("use_new_profile", _params, socket) do
    # Pre-fill form from selected profile if available
    billing_data =
      case Enum.find(
             socket.assigns.billing_profiles,
             &(&1.id == socket.assigns.selected_profile_id)
           ) do
        nil -> socket.assigns.billing_data
        profile -> profile_to_billing_data(profile, socket.assigns.cart)
      end

    {:noreply,
     socket
     |> assign(:use_new_profile, true)
     |> assign(:billing_data, billing_data)
     |> assign(:selected_profile_id, nil)}
  end

  @impl true
  def handle_event("use_existing_profile", _params, socket) do
    default_profile = Enum.find(socket.assigns.billing_profiles, & &1.is_default)
    first_profile = List.first(socket.assigns.billing_profiles)
    profile = default_profile || first_profile

    {:noreply,
     socket
     |> assign(:use_new_profile, false)
     |> assign(:selected_profile_id, if(profile, do: profile.id))}
  end

  @impl true
  def handle_event("update_billing", %{"billing" => params}, socket) do
    billing_data = Map.merge(socket.assigns.billing_data, params)
    {:noreply, assign(socket, :billing_data, billing_data)}
  end

  @impl true
  def handle_event("proceed_to_review", _params, socket) do
    if socket.assigns.use_new_profile do
      # Validate billing data
      errors = validate_billing_data(socket.assigns.billing_data)

      if Enum.empty?(errors) do
        {:noreply, assign(socket, step: :review, form_errors: %{})}
      else
        {:noreply,
         socket
         |> assign(:form_errors, errors)
         |> put_flash(:error, "Please fill in all required fields")}
      end
    else
      if is_nil(socket.assigns.selected_profile_id) do
        {:noreply, put_flash(socket, :error, "Please select a billing profile")}
      else
        {:noreply, assign(socket, :step, :review)}
      end
    end
  end

  @impl true
  def handle_event("back_to_billing", _params, socket) do
    {:noreply, assign(socket, :step, :billing)}
  end

  @impl true
  def handle_event("confirm_order", _params, socket) do
    socket = assign(socket, :processing, true)

    cart = socket.assigns.cart

    # Get user_id from current scope if logged in
    user_id =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{user: %{id: id}} -> id
        _ -> nil
      end

    # Build options for convert_cart_to_order
    opts =
      if socket.assigns.use_new_profile do
        # Guest or new profile - use billing_data directly
        [billing_data: socket.assigns.billing_data, user_id: user_id]
      else
        # Logged-in user with existing profile
        [billing_profile_id: socket.assigns.selected_profile_id, user_id: user_id]
      end

    case Shop.convert_cart_to_order(cart, opts) do
      {:ok, order} ->
        {:noreply,
         socket
         |> assign(:processing, false)
         |> push_navigate(to: Routes.path("/checkout/complete/#{order.uuid}"))}

      {:error, :cart_not_active} ->
        {:noreply,
         socket
         |> assign(:processing, false)
         |> assign(:error_message, "Cart is no longer active")
         |> put_flash(:error, "Cart is no longer active")}

      {:error, :cart_empty} ->
        {:noreply,
         socket
         |> assign(:processing, false)
         |> push_navigate(to: Routes.path("/cart"))}

      {:error, :no_shipping_method} ->
        {:noreply,
         socket
         |> assign(:processing, false)
         |> put_flash(:error, "Please select a shipping method")
         |> push_navigate(to: Routes.path("/cart"))}

      {:error, :email_already_registered} ->
        {:noreply,
         socket
         |> assign(:processing, false)
         |> assign(
           :error_message,
           "An account with this email already exists. Please log in to continue."
         )
         |> put_flash(:error, "Email already registered. Please log in.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:processing, false)
         |> assign(:error_message, "Failed to create order. Please try again.")
         |> put_flash(:error, "Failed to create order")}
    end
  end

  defp validate_billing_data(data) do
    errors = %{}

    errors =
      if blank?(data["first_name"]),
        do: Map.put(errors, :first_name, "is required"),
        else: errors

    errors =
      if blank?(data["last_name"]),
        do: Map.put(errors, :last_name, "is required"),
        else: errors

    errors =
      if blank?(data["email"]),
        do: Map.put(errors, :email, "is required"),
        else: errors

    errors =
      if blank?(data["address_line1"]),
        do: Map.put(errors, :address_line1, "is required"),
        else: errors

    errors =
      if blank?(data["city"]), do: Map.put(errors, :city, "is required"), else: errors

    errors =
      if blank?(data["country"]),
        do: Map.put(errors, :country, "is required"),
        else: errors

    errors
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <.shop_layout {assigns}>
      <div class="p-6 max-w-6xl mx-auto">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-3xl font-bold">Checkout</h1>
          <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-sm gap-2">
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Cart
          </.link>
        </div>

        <%!-- Steps Indicator --%>
        <div class="steps w-full mb-8">
          <div class={["step", @step in [:billing, :review] && "step-primary"]}>Billing</div>
          <div class={["step", @step == :review && "step-primary"]}>Review & Confirm</div>
        </div>

        <%!-- Guest Checkout Warning --%>
        <%= if @is_guest do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div>
              <div class="font-semibold">Email confirmation required</div>
              <div class="text-sm">
                Your order will require email verification. After checkout, you will receive
                a confirmation email. Please click the link to verify your email address.
              </div>
            </div>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <%!-- Main Content --%>
          <div class="lg:col-span-2">
            <%= if @step == :billing do %>
              <.billing_step
                is_guest={@is_guest}
                billing_profiles={@billing_profiles}
                selected_profile_id={@selected_profile_id}
                use_new_profile={@use_new_profile}
                show_profile_prompt={@show_profile_prompt}
                billing_data={@billing_data}
                form_errors={@form_errors}
                countries={@countries}
              />
            <% else %>
              <.review_step
                cart={@cart}
                is_guest={@is_guest}
                billing_profiles={@billing_profiles}
                selected_profile_id={@selected_profile_id}
                use_new_profile={@use_new_profile}
                billing_data={@billing_data}
                currency={@currency}
                processing={@processing}
                error_message={@error_message}
              />
            <% end %>
          </div>

          <%!-- Order Summary Sidebar --%>
          <div class="lg:col-span-1">
            <.order_summary cart={@cart} currency={@currency} />
          </div>
        </div>
      </div>
    </.shop_layout>
    """
  end

  # Layout wrapper - uses dashboard for authenticated, app_layout for guests
  slot :inner_block, required: true

  defp shop_layout(assigns) do
    ~H"""
    <%= if @authenticated do %>
      <PhoenixKitWeb.Layouts.dashboard {assigns}>
        {render_slot(@inner_block)}
      </PhoenixKitWeb.Layouts.dashboard>
    <% else %>
      <PhoenixKitWeb.Components.LayoutWrapper.app_layout
        flash={@flash}
        phoenix_kit_current_scope={@phoenix_kit_current_scope}
        current_path={@url_path}
        current_locale={@current_locale}
        page_title={@page_title}
      >
        {render_slot(@inner_block)}
      </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    <% end %>
    """
  end

  # Components

  defp billing_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title mb-4">Billing Information</h2>

        <%!-- Toggle between existing profiles and new form (for logged-in users with profiles) --%>
        <%= if not @is_guest and @billing_profiles != [] do %>
          <div class="tabs tabs-boxed mb-6">
            <button
              phx-click="use_existing_profile"
              class={["tab", not @use_new_profile && "tab-active"]}
            >
              Use Existing Profile
            </button>
            <button phx-click="use_new_profile" class={["tab", @use_new_profile && "tab-active"]}>
              Enter New Details
            </button>
          </div>
        <% end %>

        <%= if @use_new_profile do %>
          <.billing_form
            billing_data={@billing_data}
            form_errors={@form_errors}
            countries={@countries}
          />
        <% else %>
          <.profile_selector
            billing_profiles={@billing_profiles}
            selected_profile_id={@selected_profile_id}
            show_profile_prompt={@show_profile_prompt}
          />
        <% end %>

        <div class="card-actions justify-end mt-6">
          <button phx-click="proceed_to_review" class="btn btn-primary">
            Continue to Review <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp profile_selector(assigns) do
    ~H"""
    <div class="space-y-3">
      <%!-- Show info alert when multiple profiles exist without a default --%>
      <%= if @show_profile_prompt do %>
        <div class="alert alert-info mb-4">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            You have multiple billing profiles. Please select one or <.link
              navigate={Routes.path("/dashboard/billing-profiles")}
              class="link"
            >
              set a default in your account settings
            </.link>.
          </span>
        </div>
      <% end %>

      <%= for profile <- @billing_profiles do %>
        <div class={[
          "flex items-start gap-4 p-4 border rounded-lg transition-colors",
          if(@selected_profile_id == profile.id,
            do: "border-primary bg-primary/5",
            else: "border-base-300 hover:border-primary/50"
          )
        ]}>
          <label class="flex items-start gap-4 flex-1 cursor-pointer">
            <input
              type="radio"
              name="profile"
              value={profile.id}
              checked={@selected_profile_id == profile.id}
              phx-click="select_profile"
              phx-value-profile_id={profile.id}
              class="radio radio-primary mt-1"
            />
            <div class="flex-1">
              <div class="font-medium flex items-center gap-2">
                {profile_display_name(profile)}
                <%= if profile.is_default do %>
                  <span class="badge badge-primary badge-sm">Default</span>
                <% end %>
              </div>
              <div class="text-sm text-base-content/60 mt-1">
                {profile_address(profile)}
              </div>
              <%= if profile.email do %>
                <div class="text-sm text-base-content/60">
                  {profile.email}
                </div>
              <% end %>
            </div>
          </label>
          <%!-- Edit button for selected profile --%>
          <%= if @selected_profile_id == profile.id do %>
            <.link
              navigate={Routes.path("/dashboard/billing-profiles/#{profile.id}/edit")}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
            </.link>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp billing_form(assigns) do
    ~H"""
    <form phx-change="update_billing" class="space-y-4">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label"><span class="label-text">First Name *</span></label>
          <input
            type="text"
            name="billing[first_name]"
            value={@billing_data["first_name"]}
            class={["input input-bordered", @form_errors[:first_name] && "input-error"]}
            required
          />
          <%= if @form_errors[:first_name] do %>
            <label class="label">
              <span class="label-text-alt text-error">{@form_errors[:first_name]}</span>
            </label>
          <% end %>
        </div>

        <div class="form-control">
          <label class="label"><span class="label-text">Last Name *</span></label>
          <input
            type="text"
            name="billing[last_name]"
            value={@billing_data["last_name"]}
            class={["input input-bordered", @form_errors[:last_name] && "input-error"]}
            required
          />
          <%= if @form_errors[:last_name] do %>
            <label class="label">
              <span class="label-text-alt text-error">{@form_errors[:last_name]}</span>
            </label>
          <% end %>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label"><span class="label-text">Email *</span></label>
          <input
            type="email"
            name="billing[email]"
            value={@billing_data["email"]}
            class={["input input-bordered", @form_errors[:email] && "input-error"]}
            required
          />
          <%= if @form_errors[:email] do %>
            <label class="label">
              <span class="label-text-alt text-error">{@form_errors[:email]}</span>
            </label>
          <% end %>
        </div>

        <div class="form-control">
          <label class="label"><span class="label-text">Phone</span></label>
          <input
            type="tel"
            name="billing[phone]"
            value={@billing_data["phone"]}
            class="input input-bordered"
          />
        </div>
      </div>

      <div class="form-control">
        <label class="label"><span class="label-text">Address *</span></label>
        <input
          type="text"
          name="billing[address_line1]"
          value={@billing_data["address_line1"]}
          class={["input input-bordered", @form_errors[:address_line1] && "input-error"]}
          placeholder="Street address"
          required
        />
        <%= if @form_errors[:address_line1] do %>
          <label class="label">
            <span class="label-text-alt text-error">{@form_errors[:address_line1]}</span>
          </label>
        <% end %>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div class="form-control">
          <label class="label"><span class="label-text">City *</span></label>
          <input
            type="text"
            name="billing[city]"
            value={@billing_data["city"]}
            class={["input input-bordered", @form_errors[:city] && "input-error"]}
            required
          />
          <%= if @form_errors[:city] do %>
            <label class="label">
              <span class="label-text-alt text-error">{@form_errors[:city]}</span>
            </label>
          <% end %>
        </div>

        <div class="form-control">
          <label class="label"><span class="label-text">Postal Code</span></label>
          <input
            type="text"
            name="billing[postal_code]"
            value={@billing_data["postal_code"]}
            class="input input-bordered"
          />
        </div>

        <div class="form-control">
          <label class="label"><span class="label-text">Country *</span></label>
          <select
            name="billing[country]"
            class={["select select-bordered", @form_errors[:country] && "select-error"]}
            required
          >
            <option value="">Select country...</option>
            <%= for country <- @countries do %>
              <option value={country.alpha2} selected={@billing_data["country"] == country.alpha2}>
                {country.name}
              </option>
            <% end %>
          </select>
          <%= if @form_errors[:country] do %>
            <label class="label">
              <span class="label-text-alt text-error">{@form_errors[:country]}</span>
            </label>
          <% end %>
        </div>
      </div>
    </form>
    """
  end

  defp review_step(assigns) do
    selected_profile =
      if assigns.use_new_profile do
        nil
      else
        Enum.find(assigns.billing_profiles, &(&1.id == assigns.selected_profile_id))
      end

    assigns = assign(assigns, :selected_profile, selected_profile)

    ~H"""
    <div class="space-y-6">
      <%!-- Billing Info --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Billing Information</h2>
            <button phx-click="back_to_billing" class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> Change
            </button>
          </div>

          <div class="text-sm">
            <%= if @use_new_profile do %>
              <div class="font-medium">
                {@billing_data["first_name"]} {@billing_data["last_name"]}
              </div>
              <div class="text-base-content/60">
                {[
                  @billing_data["address_line1"],
                  @billing_data["city"],
                  @billing_data["postal_code"],
                  @billing_data["country"]
                ]
                |> Enum.filter(&(&1 && &1 != ""))
                |> Enum.join(", ")}
              </div>
              <div class="text-base-content/60">{@billing_data["email"]}</div>
              <%= if @billing_data["phone"] && @billing_data["phone"] != "" do %>
                <div class="text-base-content/60">{@billing_data["phone"]}</div>
              <% end %>
            <% else %>
              <%= if @selected_profile do %>
                <div class="font-medium">{profile_display_name(@selected_profile)}</div>
                <div class="text-base-content/60">{profile_address(@selected_profile)}</div>
                <%= if @selected_profile.email do %>
                  <div class="text-base-content/60">{@selected_profile.email}</div>
                <% end %>
                <%= if @selected_profile.phone do %>
                  <div class="text-base-content/60">{@selected_profile.phone}</div>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Shipping Info --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Shipping Method</h2>
            <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> Change
            </.link>
          </div>

          <%= if @cart.shipping_method do %>
            <div class="flex justify-between items-center">
              <div>
                <div class="font-medium">{@cart.shipping_method.name}</div>
                <%= if @cart.shipping_method.description do %>
                  <div class="text-sm text-base-content/60">{@cart.shipping_method.description}</div>
                <% end %>
              </div>
              <div class="font-semibold">
                <%= if Decimal.compare(@cart.shipping_amount || Decimal.new("0"), Decimal.new("0")) == :eq do %>
                  <span class="text-success">FREE</span>
                <% else %>
                  {format_price(@cart.shipping_amount, @currency)}
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Order Items --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Order Items</h2>
            <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> Edit Cart
            </.link>
          </div>

          <div class="space-y-4">
            <%= for item <- @cart.items do %>
              <div class="flex items-center gap-4">
                <%= if item.product_image do %>
                  <div class="w-16 h-16 bg-base-200 rounded-lg overflow-hidden flex-shrink-0">
                    <img
                      src={item.product_image}
                      alt={item.product_title}
                      class="w-full h-full object-cover"
                    />
                  </div>
                <% else %>
                  <div class="w-16 h-16 bg-base-200 rounded-lg flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-cube" class="w-8 h-8 opacity-30" />
                  </div>
                <% end %>
                <div class="flex-1">
                  <div class="font-medium">{item.product_title}</div>
                  <div class="text-sm text-base-content/60">
                    Qty: {item.quantity} × {format_price(item.unit_price, @currency)}
                  </div>
                </div>
                <div class="font-semibold">
                  {format_price(item.line_total, @currency)}
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Error Message --%>
      <%= if @error_message do %>
        <div class="alert alert-error">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error_message}</span>
        </div>
      <% end %>

      <%!-- Confirm Button --%>
      <div class="flex justify-between items-center">
        <button phx-click="back_to_billing" class="btn btn-ghost">
          <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
        </button>
        <button
          phx-click="confirm_order"
          class={["btn btn-primary btn-lg", @processing && "loading"]}
          disabled={@processing}
        >
          <%= if @processing do %>
            Processing...
          <% else %>
            <.icon name="hero-check" class="w-5 h-5 mr-2" /> Confirm Order
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  defp order_summary(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg sticky top-6">
      <div class="card-body">
        <h2 class="card-title mb-4">Order Summary</h2>

        <div class="space-y-3 text-sm">
          <div class="flex justify-between">
            <span class="text-base-content/70">
              Subtotal ({@cart.items_count || 0} items)
            </span>
            <span>{format_price(@cart.subtotal, @currency)}</span>
          </div>

          <div class="flex justify-between">
            <span class="text-base-content/70">Shipping</span>
            <%= if is_nil(@cart.shipping_method_id) do %>
              <span class="text-base-content/50">-</span>
            <% else %>
              <%= if Decimal.compare(@cart.shipping_amount || Decimal.new("0"), Decimal.new("0")) == :eq do %>
                <span class="text-success">FREE</span>
              <% else %>
                <span>{format_price(@cart.shipping_amount, @currency)}</span>
              <% end %>
            <% end %>
          </div>

          <%= if @cart.tax_amount && Decimal.compare(@cart.tax_amount, Decimal.new("0")) == :gt do %>
            <div class="flex justify-between">
              <span class="text-base-content/70">Tax</span>
              <span>{format_price(@cart.tax_amount, @currency)}</span>
            </div>
          <% end %>

          <%= if @cart.discount_amount && Decimal.compare(@cart.discount_amount, Decimal.new("0")) == :gt do %>
            <div class="flex justify-between text-success">
              <span>Discount</span>
              <span>-{format_price(@cart.discount_amount, @currency)}</span>
            </div>
          <% end %>

          <div class="divider my-2"></div>

          <div class="flex justify-between text-lg font-bold">
            <span>Total</span>
            <span>{format_price(@cart.total, @currency)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helpers

  defp profile_display_name(%BillingProfile{type: "company"} = profile) do
    profile.company_name || "#{profile.first_name} #{profile.last_name}"
  end

  defp profile_display_name(%BillingProfile{} = profile) do
    "#{profile.first_name} #{profile.last_name}"
  end

  defp profile_address(%BillingProfile{} = profile) do
    [profile.address_line1, profile.city, profile.postal_code, profile.country]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp format_price(nil, _currency), do: "-"

  defp format_price(amount, %Currency{} = currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount, 2)}"
  end

  defp get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{id: _} = user} -> user
      _ -> nil
    end
  end
end
