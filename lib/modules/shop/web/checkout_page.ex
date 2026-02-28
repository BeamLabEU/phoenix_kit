defmodule PhoenixKit.Modules.Shop.Web.CheckoutPage do
  @moduledoc """
  Checkout page LiveView for converting cart to order.
  Supports both logged-in users (with billing profiles) and guest checkout.

  Supports real-time cart synchronization across multiple browser tabs
  via PubSub subscription.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.CountryData
  alias PhoenixKit.Modules.Billing.PaymentOption
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Events
  alias PhoenixKit.Modules.Shop.Web.Components.ShopLayouts

  import PhoenixKit.Modules.Shop.Web.Helpers,
    only: [
      format_price: 2,
      humanize_key: 1,
      profile_display_name: 1,
      profile_address: 1,
      get_current_user: 1
    ]

  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, session, socket) do
    user = get_current_user(socket)
    session_id = session["shop_session_id"]
    user_id = if user, do: user.uuid

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

      is_nil(cart.shipping_method_uuid) ->
        {:ok, redirect_to_cart(socket, "Please select a shipping method")}

      true ->
        {:ok, setup_checkout_assigns(socket, cart, user)}
    end
  end

  defp setup_checkout_assigns(socket, cart, user) do
    is_guest = is_nil(user)
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    # Subscribe to cart events for real-time sync across tabs
    if connected?(socket) do
      Events.subscribe_to_cart(cart)
    end

    # Load and auto-select payment option
    payment_options = Billing.list_active_payment_options()

    {cart, selected_payment_option, needs_payment_selection} =
      prepare_payment_options(cart, payment_options)

    # Load billing profiles
    billing_profiles = load_billing_profiles(user)
    {selected_profile, needs_profile_selection} = select_billing_profile(billing_profiles)

    # Determine if billing is needed and initial step
    needs_billing =
      payment_option_needs_billing?(selected_payment_option, is_guest, billing_profiles)

    initial_step =
      determine_initial_step(
        needs_payment_selection,
        needs_billing,
        is_guest,
        billing_profiles,
        needs_profile_selection
      )

    build_checkout_socket(socket, %{
      cart: cart,
      is_guest: is_guest,
      authenticated: authenticated,
      payment_options: payment_options,
      selected_payment_option: selected_payment_option,
      needs_payment_selection: needs_payment_selection,
      billing_profiles: billing_profiles,
      selected_profile: selected_profile,
      needs_profile_selection: needs_profile_selection,
      needs_billing: needs_billing,
      initial_step: initial_step,
      user: user
    })
  end

  defp prepare_payment_options(cart, payment_options) do
    {selected, needs_selection} = select_payment_option(payment_options, cart)
    cart = maybe_auto_select_payment(cart, payment_options)
    {cart, selected, needs_selection}
  end

  defp maybe_auto_select_payment(cart, payment_options) do
    if length(payment_options) == 1 and is_nil(cart.payment_option_uuid) do
      case Shop.set_cart_payment_option(cart, hd(payment_options)) do
        {:ok, updated_cart} -> updated_cart
        _ -> cart
      end
    else
      cart
    end
  end

  defp determine_initial_step(needs_payment, needs_billing, is_guest, profiles, needs_profile) do
    cond do
      needs_payment -> :payment
      needs_billing and (is_guest or profiles == []) -> :billing
      needs_billing and needs_profile -> :billing
      true -> :review
    end
  end

  defp build_checkout_socket(socket, assigns) do
    socket
    |> assign(:page_title, "Checkout")
    |> assign(:cart, assigns.cart)
    |> assign(:currency, Shop.get_default_currency())
    |> assign(:is_guest, assigns.is_guest)
    |> assign(:authenticated, assigns.authenticated)
    |> assign(:payment_options, assigns.payment_options)
    |> assign(:selected_payment_option, assigns.selected_payment_option)
    |> assign(:needs_payment_selection, assigns.needs_payment_selection)
    |> assign(:billing_profiles, assigns.billing_profiles)
    |> assign(
      :selected_profile_id,
      if(assigns.selected_profile, do: assigns.selected_profile.uuid)
    )
    |> assign(:use_new_profile, assigns.is_guest or assigns.billing_profiles == [])
    |> assign(:needs_profile_selection, assigns.needs_profile_selection)
    |> assign(:needs_billing, assigns.needs_billing)
    |> assign(:billing_data, initial_billing_data(assigns.user, assigns.cart))
    |> assign(:countries, CountryData.list_countries())
    |> assign(:step, assigns.initial_step)
    |> assign(:processing, false)
    |> assign(:error_message, nil)
    |> assign(:email_exists_error, false)
    |> assign(:form_errors, %{})
  end

  # Select payment option with smart defaults
  defp select_payment_option([], _cart), do: {nil, false}

  defp select_payment_option(options, cart) do
    # Check if cart already has a payment option selected
    selected =
      if cart.payment_option_uuid do
        Enum.find(options, &(&1.uuid == cart.payment_option_uuid))
      end

    cond do
      # Cart has valid selected option
      selected -> {selected, false}
      # Only one option available
      length(options) == 1 -> {hd(options), false}
      # Multiple options - user must choose
      true -> {hd(options), true}
    end
  end

  # Check if billing info is needed for the payment option
  defp payment_option_needs_billing?(nil, _is_guest, _profiles), do: true

  defp payment_option_needs_billing?(
         %PaymentOption{requires_billing_profile: true},
         _is_guest,
         _profiles
       ),
       do: true

  defp payment_option_needs_billing?(
         %PaymentOption{requires_billing_profile: false},
         true,
         _profiles
       ),
       do: true

  defp payment_option_needs_billing?(
         %PaymentOption{requires_billing_profile: false},
         false,
         _profiles
       ),
       do: false

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
  defp load_billing_profiles(user), do: Billing.list_user_billing_profiles(user.uuid)

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
  def handle_event("select_payment_option", %{"option_uuid" => option_uuid}, socket) do
    option = Enum.find(socket.assigns.payment_options, &(&1.uuid == option_uuid))

    if option do
      case Shop.set_cart_payment_option(socket.assigns.cart, option) do
        {:ok, updated_cart} ->
          # Update needs_billing based on new payment option
          needs_billing =
            payment_option_needs_billing?(
              option,
              socket.assigns.is_guest,
              socket.assigns.billing_profiles
            )

          {:noreply,
           socket
           |> assign(:cart, updated_cart)
           |> assign(:selected_payment_option, option)
           |> assign(:needs_billing, needs_billing)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to set payment option")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("proceed_to_billing", _params, socket) do
    if socket.assigns.needs_billing do
      {:noreply, assign(socket, :step, :billing)}
    else
      {:noreply, assign(socket, :step, :review)}
    end
  end

  @impl true
  def handle_event("back_to_payment", _params, socket) do
    {:noreply, assign(socket, :step, :payment)}
  end

  @impl true
  def handle_event("select_profile", %{"profile_id" => profile_id}, socket) do
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
             &(to_string(&1.uuid) == to_string(socket.assigns.selected_profile_id))
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
     |> assign(:selected_profile_id, if(profile, do: profile.uuid))}
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

    # Get user identifier from current scope if logged in
    user_uuid =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{user: %{uuid: uuid}} -> uuid
        _ -> nil
      end

    # Build options for convert_cart_to_order
    opts =
      if socket.assigns.use_new_profile do
        # Guest or new profile - use billing_data directly
        [billing_data: socket.assigns.billing_data, user_uuid: user_uuid]
      else
        # Logged-in user with existing profile
        [billing_profile_uuid: socket.assigns.selected_profile_id, user_uuid: user_uuid]
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
         |> assign(:email_exists_error, true)
         |> assign(:error_message, nil)}

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

  # ============================================
  # PUBSUB EVENT HANDLERS
  # ============================================

  @impl true
  def handle_info({:cart_updated, cart}, socket) do
    {:noreply, assign(socket, :cart, cart)}
  end

  @impl true
  def handle_info({:item_added, cart, _item}, socket) do
    {:noreply, assign(socket, :cart, cart)}
  end

  @impl true
  def handle_info({:item_removed, cart, _item_id}, socket) do
    # If cart becomes empty, redirect to cart page
    if Enum.empty?(cart.items) do
      {:noreply, redirect_to_cart(socket, "Your cart is empty")}
    else
      {:noreply, assign(socket, :cart, cart)}
    end
  end

  @impl true
  def handle_info({:quantity_updated, cart, _item}, socket) do
    {:noreply, assign(socket, :cart, cart)}
  end

  @impl true
  def handle_info({:shipping_selected, cart}, socket) do
    {:noreply, assign(socket, :cart, cart)}
  end

  @impl true
  def handle_info({:payment_selected, cart}, socket) do
    # Also update selected_payment_option if it changed
    selected = Enum.find(socket.assigns.payment_options, &(&1.uuid == cart.payment_option_uuid))

    {:noreply,
     socket
     |> assign(:cart, cart)
     |> assign(:selected_payment_option, selected)}
  end

  @impl true
  def handle_info({:cart_cleared, _cart}, socket) do
    # Cart was cleared, redirect to cart page
    {:noreply, redirect_to_cart(socket, "Your cart is empty")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ShopLayouts.shop_layout {assigns}>
      <div class="p-6 max-w-6xl mx-auto">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-3xl font-bold">Checkout</h1>
          <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
        </div>

        <%!-- Steps Indicator --%>
        <div class="steps w-full mb-8">
          <%= if length(@payment_options) > 1 do %>
            <div class={["step", @step in [:payment, :billing, :review] && "step-primary"]}>
              Payment
            </div>
          <% end %>
          <%= if @needs_billing do %>
            <div class={["step", @step in [:billing, :review] && "step-primary"]}>Billing</div>
          <% end %>
          <div class={["step", @step == :review && "step-primary"]}>Review & Confirm</div>
        </div>

        <%!-- Guest Checkout Info --%>
        <%= if @is_guest do %>
          <div class="alert alert-info mb-6">
            <.icon name="hero-envelope" class="w-5 h-5" />
            <div>
              <div class="font-semibold">Checking out as a guest</div>
              <div class="text-sm">
                After placing your order, we'll send a confirmation email to verify your address.
                Check your inbox and click the link to activate your account and track your order.
              </div>
            </div>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <%!-- Main Content --%>
          <div class="lg:col-span-2">
            <%= case @step do %>
              <% :payment -> %>
                <.payment_step
                  payment_options={@payment_options}
                  selected_payment_option={@selected_payment_option}
                  needs_billing={@needs_billing}
                />
              <% :billing -> %>
                <.billing_step
                  is_guest={@is_guest}
                  billing_profiles={@billing_profiles}
                  selected_profile_id={@selected_profile_id}
                  use_new_profile={@use_new_profile}
                  needs_profile_selection={@needs_profile_selection}
                  billing_data={@billing_data}
                  form_errors={@form_errors}
                  countries={@countries}
                  payment_options={@payment_options}
                />
              <% :review -> %>
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
                  email_exists_error={@email_exists_error}
                  selected_payment_option={@selected_payment_option}
                  needs_billing={@needs_billing}
                  payment_options={@payment_options}
                />
            <% end %>
          </div>

          <%!-- Order Summary Sidebar --%>
          <div class="lg:col-span-1">
            <.order_summary cart={@cart} currency={@currency} />
          </div>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  # Components

  defp payment_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title mb-4">Select Payment Method</h2>

        <div class="space-y-3">
          <%= for option <- @payment_options do %>
            <label class={[
              "flex items-center gap-4 p-4 border rounded-lg cursor-pointer transition-colors",
              if(@selected_payment_option && @selected_payment_option.uuid == option.uuid,
                do: "border-primary bg-primary/5",
                else: "border-base-300 hover:border-primary/50"
              )
            ]}>
              <input
                type="radio"
                name="payment_option"
                value={option.uuid}
                checked={@selected_payment_option && @selected_payment_option.uuid == option.uuid}
                phx-click="select_payment_option"
                phx-value-option_uuid={option.uuid}
                class="radio radio-primary"
              />
              <.icon name={PaymentOption.icon_name(option)} class="w-6 h-6 text-base-content/70" />
              <div class="flex-1">
                <div class="font-medium">{option.name}</div>
                <%= if option.description do %>
                  <div class="text-sm text-base-content/60">{option.description}</div>
                <% end %>
              </div>
            </label>
          <% end %>
        </div>

        <div class="card-actions justify-end mt-6">
          <button phx-click="proceed_to_billing" class="btn btn-primary">
            <%= if @needs_billing do %>
              Continue to Billing <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
            <% else %>
              Continue to Review <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
            <% end %>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp billing_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title mb-4">
          <%= if @is_guest or @billing_profiles == [] do %>
            Billing Information
          <% else %>
            Select Billing Profile
          <% end %>
        </h2>

        <%= if @use_new_profile do %>
          <%!-- Guest checkout or no profiles - show billing form --%>
          <.billing_form
            billing_data={@billing_data}
            form_errors={@form_errors}
            countries={@countries}
          />
        <% else %>
          <%!-- Authenticated user with multiple profiles - show selector --%>
          <.profile_selector
            billing_profiles={@billing_profiles}
            selected_profile_id={@selected_profile_id}
            needs_profile_selection={@needs_profile_selection}
          />
        <% end %>

        <div class="card-actions justify-between mt-6">
          <%= if length(@payment_options) > 1 do %>
            <button phx-click="back_to_payment" class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </button>
          <% else %>
            <div></div>
          <% end %>
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
      <%= if @needs_profile_selection do %>
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
          if(to_string(@selected_profile_id) == to_string(profile.uuid),
            do: "border-primary bg-primary/5",
            else: "border-base-300 hover:border-primary/50"
          )
        ]}>
          <label class="flex items-start gap-4 flex-1 cursor-pointer">
            <input
              type="radio"
              name="profile"
              value={profile.uuid}
              checked={to_string(@selected_profile_id) == to_string(profile.uuid)}
              phx-click="select_profile"
              phx-value-profile_id={profile.uuid}
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
          <%= if to_string(@selected_profile_id) == to_string(profile.uuid) do %>
            <.link
              navigate={
                Routes.path("/dashboard/billing-profiles/#{profile.uuid}/edit?return_to=/checkout")
              }
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
        <fieldset class="fieldset">
          <legend class="fieldset-legend">First Name *</legend>
          <input
            type="text"
            name="billing[first_name]"
            value={@billing_data["first_name"]}
            class={["input", @form_errors[:first_name] && "input-error"]}
            required
          />
          <%= if @form_errors[:first_name] do %>
            <p class="fieldset-label text-error">{@form_errors[:first_name]}</p>
          <% end %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Last Name *</legend>
          <input
            type="text"
            name="billing[last_name]"
            value={@billing_data["last_name"]}
            class={["input", @form_errors[:last_name] && "input-error"]}
            required
          />
          <%= if @form_errors[:last_name] do %>
            <p class="fieldset-label text-error">{@form_errors[:last_name]}</p>
          <% end %>
        </fieldset>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Email *</legend>
          <input
            type="email"
            name="billing[email]"
            value={@billing_data["email"]}
            class={["input", @form_errors[:email] && "input-error"]}
            required
          />
          <%= if @form_errors[:email] do %>
            <p class="fieldset-label text-error">{@form_errors[:email]}</p>
          <% end %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Phone</legend>
          <input
            type="tel"
            name="billing[phone]"
            value={@billing_data["phone"]}
            class="input"
          />
        </fieldset>
      </div>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Address *</legend>
        <input
          type="text"
          name="billing[address_line1]"
          value={@billing_data["address_line1"]}
          class={["input", @form_errors[:address_line1] && "input-error"]}
          placeholder="Street address"
          required
        />
        <%= if @form_errors[:address_line1] do %>
          <p class="fieldset-label text-error">{@form_errors[:address_line1]}</p>
        <% end %>
      </fieldset>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">City *</legend>
          <input
            type="text"
            name="billing[city]"
            value={@billing_data["city"]}
            class={["input", @form_errors[:city] && "input-error"]}
            required
          />
          <%= if @form_errors[:city] do %>
            <p class="fieldset-label text-error">{@form_errors[:city]}</p>
          <% end %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Postal Code</legend>
          <input
            type="text"
            name="billing[postal_code]"
            value={@billing_data["postal_code"]}
            class="input"
          />
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">Country *</legend>
          <select
            name="billing[country]"
            class={["select", @form_errors[:country] && "select-error"]}
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
            <p class="fieldset-label text-error">{@form_errors[:country]}</p>
          <% end %>
        </fieldset>
      </div>
    </form>
    """
  end

  defp review_step(assigns) do
    selected_profile =
      if assigns.use_new_profile do
        nil
      else
        Enum.find(
          assigns.billing_profiles,
          &(to_string(&1.uuid) == to_string(assigns.selected_profile_id))
        )
      end

    assigns = assign(assigns, :selected_profile, selected_profile)

    ~H"""
    <div class="space-y-6">
      <%!-- Payment Method --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">Payment Method</h2>
            <%= if length(@payment_options) > 1 do %>
              <button phx-click="back_to_payment" class="btn btn-ghost btn-sm">
                <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> Change
              </button>
            <% end %>
          </div>

          <%= if @selected_payment_option do %>
            <div class="flex items-center gap-3">
              <.icon
                name={PaymentOption.icon_name(@selected_payment_option)}
                class="w-6 h-6 text-base-content/70"
              />
              <div>
                <div class="font-medium">{@selected_payment_option.name}</div>
                <%= if @selected_payment_option.description do %>
                  <div class="text-sm text-base-content/60">
                    {@selected_payment_option.description}
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Billing Info (only if billing is needed) --%>
      <%= if @needs_billing do %>
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
      <% end %>

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
                  <%= if item.selected_specs && item.selected_specs != %{} do %>
                    <div class="text-xs text-base-content/60 mt-0.5">
                      <%= for {key, value} <- item.selected_specs do %>
                        <span class="inline-block mr-2">
                          <span class="font-medium">{humanize_key(key)}:</span>
                          <span>{value}</span>
                        </span>
                      <% end %>
                    </div>
                  <% end %>
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

      <%!-- Email Already Registered --%>
      <%= if @email_exists_error do %>
        <div class="card bg-warning/10 border border-warning">
          <div class="card-body">
            <div class="flex items-start gap-4">
              <.icon name="hero-user-circle" class="w-8 h-8 text-warning flex-shrink-0" />
              <div>
                <h3 class="font-semibold text-lg">Account already exists</h3>
                <p class="text-sm mt-1">
                  An account with this email is already registered.
                  Please log in to complete your order.
                </p>
                <div class="mt-3">
                  <.link
                    navigate={Routes.path("/users/log-in") <> "?return_to=" <> Routes.path("/checkout")}
                    class="btn btn-primary btn-sm"
                  >
                    <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4 mr-1" />
                    Log in to continue
                  </.link>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Error Message --%>
      <%= if @error_message do %>
        <div class="alert alert-error">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error_message}</span>
        </div>
      <% end %>

      <%!-- Confirm Button --%>
      <div class="flex justify-between items-center">
        <%= cond do %>
          <% @needs_billing -> %>
            <button phx-click="back_to_billing" class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </button>
          <% length(@payment_options) > 1 -> %>
            <button phx-click="back_to_payment" class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </button>
          <% true -> %>
            <div></div>
        <% end %>
        <button
          phx-click="confirm_order"
          class={["btn btn-primary btn-lg"]}
          disabled={@processing}
        >
          <%= if @processing do %>
            <span class="loading loading-spinner loading-sm"></span> Processing...
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
            <%= if is_nil(@cart.shipping_method_uuid) do %>
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
end
