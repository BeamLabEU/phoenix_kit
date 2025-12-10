defmodule PhoenixKit.Billing do
  @moduledoc """
  Main context for PhoenixKit Billing system.

  Provides comprehensive billing functionality including currencies, billing profiles,
  orders, and invoices with manual bank transfer payments (Phase 1).

  ## Features

  - **Currencies**: Multi-currency support with exchange rates
  - **Billing Profiles**: User billing information (individuals & companies)
  - **Orders**: Order management with line items and status tracking
  - **Invoices**: Invoice generation with receipt functionality
  - **Bank Payments**: Manual bank transfer workflow

  ## System Enable/Disable

      # Check if billing is enabled
      PhoenixKit.Billing.enabled?()

      # Enable/disable billing system
      PhoenixKit.Billing.enable_system()
      PhoenixKit.Billing.disable_system()

  ## Order Workflow

      # Create order
      {:ok, order} = Billing.create_order(user, %{...})

      # Confirm order
      {:ok, order} = Billing.confirm_order(order)

      # Generate invoice
      {:ok, invoice} = Billing.create_invoice_from_order(order)

      # Send invoice
      {:ok, invoice} = Billing.send_invoice(invoice)

      # Mark as paid (generates receipt)
      {:ok, invoice} = Billing.mark_invoice_paid(invoice)
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Billing.BillingProfile
  alias PhoenixKit.Billing.Currency
  alias PhoenixKit.Billing.Invoice
  alias PhoenixKit.Billing.Order
  alias PhoenixKit.Emails.Templates
  alias PhoenixKit.Settings

  # ============================================
  # SYSTEM ENABLE/DISABLE
  # ============================================

  @doc """
  Checks if the billing system is enabled.
  """
  def enabled? do
    Settings.get_setting("billing_enabled", "false") == "true"
  end

  @doc """
  Enables the billing system.
  """
  def enable_system do
    Settings.update_setting("billing_enabled", "true")
  end

  @doc """
  Disables the billing system.
  """
  def disable_system do
    Settings.update_setting("billing_enabled", "false")
  end

  @doc """
  Returns the current billing configuration.
  """
  def get_config do
    %{
      enabled: enabled?(),
      default_currency: Settings.get_setting("billing_default_currency", "EUR"),
      tax_enabled: Settings.get_setting("billing_tax_enabled", "false") == "true",
      default_tax_rate: Settings.get_setting("billing_default_tax_rate", "0"),
      invoice_prefix: Settings.get_setting("billing_invoice_prefix", "INV"),
      order_prefix: Settings.get_setting("billing_order_prefix", "ORD"),
      receipt_prefix: Settings.get_setting("billing_receipt_prefix", "RCP"),
      invoice_due_days: String.to_integer(Settings.get_setting("billing_invoice_due_days", "14")),
      orders_count: count_orders(),
      invoices_count: count_invoices(),
      currencies_count: count_currencies()
    }
  end

  @doc """
  Returns dashboard statistics.
  """
  def get_dashboard_stats do
    today = Date.utc_today()
    start_of_month = Date.beginning_of_month(today)
    default_currency = Settings.get_setting("billing_default_currency", "EUR")

    %{
      total_orders: count_orders(),
      orders_this_month: count_orders_since(start_of_month),
      total_invoices: count_invoices(),
      invoices_this_month: count_invoices_since(start_of_month),
      total_paid_revenue: calculate_paid_revenue(),
      pending_revenue: calculate_pending_revenue(),
      paid_invoices_count: count_invoices_by_status("paid"),
      pending_invoices_count:
        count_invoices_by_status("sent") + count_invoices_by_status("overdue"),
      default_currency: default_currency
    }
  end

  defp count_orders do
    Order |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_invoices do
    Invoice |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_currencies do
    Currency |> where([c], c.enabled == true) |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_orders_since(date) do
    Order
    |> where([o], o.inserted_at >= ^NaiveDateTime.new!(date, ~T[00:00:00]))
    |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_invoices_since(date) do
    Invoice
    |> where([i], i.inserted_at >= ^NaiveDateTime.new!(date, ~T[00:00:00]))
    |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp count_invoices_by_status(status) do
    Invoice
    |> where([i], i.status == ^status)
    |> repo().aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp calculate_paid_revenue do
    result =
      Invoice
      |> where([i], i.status == "paid")
      |> select([i], sum(i.total))
      |> repo().one()

    result || Decimal.new(0)
  rescue
    _ -> Decimal.new(0)
  end

  defp calculate_pending_revenue do
    result =
      Invoice
      |> where([i], i.status in ["sent", "overdue"])
      |> select([i], sum(i.total))
      |> repo().one()

    result || Decimal.new(0)
  rescue
    _ -> Decimal.new(0)
  end

  # ============================================
  # CURRENCIES
  # ============================================

  @doc """
  Lists all currencies with optional filters.

  ## Options
  - `:enabled` - Filter by enabled status
  - `:order_by` - Custom ordering
  """
  def list_currencies(opts \\ []) do
    query = Currency

    query =
      case Keyword.get(opts, :enabled) do
        true -> where(query, [c], c.enabled == true)
        false -> where(query, [c], c.enabled == false)
        _ -> query
      end

    query =
      case Keyword.get(opts, :order_by) do
        nil -> order_by(query, [c], [c.sort_order, c.code])
        custom -> order_by(query, ^custom)
      end

    repo().all(query)
  end

  @doc """
  Lists enabled currencies.
  """
  def list_enabled_currencies do
    list_currencies(enabled: true)
  end

  @doc """
  Gets the default currency.
  """
  def get_default_currency do
    Currency
    |> where([c], c.is_default == true)
    |> repo().one()
  end

  @doc """
  Gets a currency by ID.
  """
  def get_currency!(id), do: repo().get!(Currency, id)

  @doc """
  Gets a currency by code.
  """
  def get_currency_by_code(code) do
    Currency
    |> where([c], c.code == ^String.upcase(code))
    |> repo().one()
  end

  @doc """
  Creates a currency.
  """
  def create_currency(attrs) do
    %Currency{}
    |> Currency.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a currency.
  """
  def update_currency(%Currency{} = currency, attrs) do
    currency
    |> Currency.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Sets a currency as default.
  """
  def set_default_currency(%Currency{} = currency) do
    repo().transaction(fn ->
      # Clear existing default
      Currency
      |> where([c], c.is_default == true)
      |> repo().update_all(set: [is_default: false])

      # Set new default
      currency
      |> Currency.changeset(%{is_default: true})
      |> repo().update!()
    end)
  end

  # ============================================
  # BILLING PROFILES
  # ============================================

  @doc """
  Lists billing profiles with optional filters.

  ## Options
  - `:user_id` - Filter by user ID
  - `:type` - Filter by type ("individual" or "company")
  - `:search` - Search in name/email/company fields
  - `:page` - Page number
  - `:per_page` - Items per page
  - `:preload` - Associations to preload
  """
  def list_billing_profiles(opts \\ []) do
    BillingProfile
    |> filter_by_user_id(Keyword.get(opts, :user_id))
    |> filter_by_type(Keyword.get(opts, :type))
    |> filter_by_search(Keyword.get(opts, :search))
    |> order_by([bp], desc: bp.is_default, desc: bp.inserted_at)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  defp filter_by_user_id(query, nil), do: query
  defp filter_by_user_id(query, user_id), do: where(query, [bp], bp.user_id == ^user_id)

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: where(query, [bp], bp.type == ^type)

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    search_term = "%#{search}%"

    where(
      query,
      [bp],
      ilike(bp.first_name, ^search_term) or
        ilike(bp.last_name, ^search_term) or
        ilike(bp.email, ^search_term) or
        ilike(bp.company_name, ^search_term)
    )
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  @doc """
  Lists billing profiles for a user (shorthand).
  """
  def list_user_billing_profiles(user_id) do
    list_billing_profiles(user_id: user_id)
  end

  @doc """
  Lists billing profiles with count for pagination.
  """
  def list_billing_profiles_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page

    base_query = BillingProfile

    base_query =
      case Keyword.get(opts, :type) do
        nil -> base_query
        type -> where(base_query, [bp], bp.type == ^type)
      end

    base_query =
      case Keyword.get(opts, :search) do
        nil ->
          base_query

        "" ->
          base_query

        search ->
          search_term = "%#{search}%"

          where(
            base_query,
            [bp],
            ilike(bp.first_name, ^search_term) or
              ilike(bp.last_name, ^search_term) or
              ilike(bp.email, ^search_term) or
              ilike(bp.company_name, ^search_term)
          )
      end

    total = repo().aggregate(base_query, :count, :id)

    preloads = Keyword.get(opts, :preload, [:user])

    profiles =
      base_query
      |> order_by([bp], desc: bp.is_default, desc: bp.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload(^preloads)
      |> repo().all()

    {profiles, total}
  end

  @doc """
  Gets the default billing profile for a user.
  """
  def get_default_billing_profile(user_id) do
    BillingProfile
    |> where([bp], bp.user_id == ^user_id and bp.is_default == true)
    |> repo().one()
  end

  @doc """
  Gets a billing profile by ID.
  """
  def get_billing_profile!(id), do: repo().get!(BillingProfile, id)

  @doc """
  Creates a billing profile.
  """
  def create_billing_profile(user_or_id, attrs) do
    user_id = extract_user_id(user_or_id)

    result =
      %BillingProfile{}
      |> BillingProfile.changeset(Map.put(attrs, :user_id, user_id))
      |> repo().insert()

    # If this is the first profile, make it default
    case result do
      {:ok, profile} ->
        if count_user_profiles(user_id) == 1 do
          set_default_billing_profile(profile)
        else
          {:ok, profile}
        end

      error ->
        error
    end
  end

  @doc """
  Updates a billing profile.
  """
  def update_billing_profile(%BillingProfile{} = profile, attrs) do
    profile
    |> BillingProfile.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a billing profile.
  """
  def delete_billing_profile(%BillingProfile{} = profile) do
    repo().delete(profile)
  end

  @doc """
  Sets a billing profile as default.
  """
  def set_default_billing_profile(%BillingProfile{} = profile) do
    repo().transaction(fn ->
      # Clear existing default for user
      BillingProfile
      |> where([bp], bp.user_id == ^profile.user_id and bp.is_default == true)
      |> repo().update_all(set: [is_default: false])

      # Set new default
      profile
      |> BillingProfile.changeset(%{is_default: true})
      |> repo().update!()
    end)
  end

  defp count_user_profiles(user_id) do
    BillingProfile
    |> where([bp], bp.user_id == ^user_id)
    |> repo().aggregate(:count, :id)
  end

  # ============================================
  # ORDERS
  # ============================================

  @doc """
  Lists all orders with optional filters.
  """
  def list_orders(filters \\ %{}) do
    Order
    |> apply_order_filters(filters)
    |> order_by([o], desc: o.inserted_at)
    |> preload([:user, :billing_profile])
    |> repo().all()
  end

  @doc """
  Lists orders for a specific user.
  """
  def list_user_orders(user_id, filters \\ %{}) do
    Order
    |> where([o], o.user_id == ^user_id)
    |> apply_order_filters(filters)
    |> order_by([o], desc: o.inserted_at)
    |> repo().all()
  end

  @doc """
  Lists orders with count for pagination.
  """
  def list_orders_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    search = Keyword.get(opts, :search)
    status = Keyword.get(opts, :status)

    base_query = Order

    base_query =
      case status do
        nil -> base_query
        status -> where(base_query, [o], o.status == ^status)
      end

    base_query =
      case search do
        nil ->
          base_query

        "" ->
          base_query

        search ->
          search_term = "%#{search}%"

          base_query
          |> join(:left, [o], u in assoc(o, :user))
          |> where(
            [o, u],
            ilike(o.order_number, ^search_term) or
              ilike(u.email, ^search_term)
          )
      end

    total = repo().aggregate(base_query, :count, :id)

    preloads = Keyword.get(opts, :preload, [:user])

    orders =
      base_query
      |> order_by([o], desc: o.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload(^preloads)
      |> repo().all()

    {orders, total}
  end

  @doc """
  Gets an order by ID.
  """
  def get_order!(id) do
    Order
    |> preload([:user, :billing_profile])
    |> repo().get!(id)
  end

  @doc """
  Gets an order by ID with optional preloads.
  """
  def get_order(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:user, :billing_profile])

    Order
    |> preload(^preloads)
    |> repo().get(id)
  end

  @doc """
  Gets an order by order number.
  """
  def get_order_by_number(order_number) do
    Order
    |> where([o], o.order_number == ^order_number)
    |> preload([:user, :billing_profile])
    |> repo().one()
  end

  @doc """
  Creates an order for a user.
  """
  def create_order(user_or_id, attrs) do
    user_id = extract_user_id(user_or_id)
    config = get_config()

    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> maybe_set_order_number(config)
      |> maybe_set_billing_snapshot()

    %Order{}
    |> Order.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Creates an order from attributes (user_id included in attrs).
  """
  def create_order(attrs) when is_map(attrs) do
    config = get_config()

    attrs =
      attrs
      |> maybe_set_order_number(config)
      |> maybe_set_billing_snapshot()

    %Order{}
    |> Order.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Returns an order changeset for form building.
  """
  def change_order(%Order{} = order, attrs \\ %{}) do
    Order.changeset(order, attrs)
  end

  @doc """
  Updates an order.
  """
  def update_order(%Order{} = order, attrs) do
    if Order.editable?(order) do
      order
      |> Order.changeset(attrs)
      |> repo().update()
    else
      {:error, :order_not_editable}
    end
  end

  @doc """
  Confirms an order.
  """
  def confirm_order(%Order{} = order) do
    order
    |> Order.status_changeset("confirmed")
    |> repo().update()
  end

  @doc """
  Marks an order as paid.
  """
  def mark_order_paid(%Order{} = order) do
    if Order.payable?(order) do
      order
      |> Order.status_changeset("paid")
      |> repo().update()
    else
      {:error, :order_not_payable}
    end
  end

  @doc """
  Cancels an order.
  """
  def cancel_order(%Order{} = order, reason \\ nil) do
    if Order.cancellable?(order) do
      changeset =
        order
        |> Order.status_changeset("cancelled")

      changeset =
        if reason do
          Ecto.Changeset.put_change(changeset, :internal_notes, reason)
        else
          changeset
        end

      repo().update(changeset)
    else
      {:error, :order_not_cancellable}
    end
  end

  @doc """
  Deletes an order (only drafts).
  """
  def delete_order(%Order{status: "draft"} = order) do
    repo().delete(order)
  end

  def delete_order(_order), do: {:error, :can_only_delete_drafts}

  defp apply_order_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, q when is_binary(status) ->
        where(q, [o], o.status == ^status)

      {:statuses, statuses}, q when is_list(statuses) ->
        where(q, [o], o.status in ^statuses)

      {:from_date, date}, q ->
        where(q, [o], o.inserted_at >= ^date)

      {:to_date, date}, q ->
        where(q, [o], o.inserted_at <= ^date)

      _, q ->
        q
    end)
  end

  defp maybe_set_order_number(attrs, config) do
    # Check both atom and string keys since params may come from forms (string keys)
    if Map.has_key?(attrs, :order_number) || Map.has_key?(attrs, "order_number") do
      attrs
    else
      Map.put(attrs, "order_number", generate_order_number(config.order_prefix))
    end
  end

  defp maybe_set_billing_snapshot(attrs) do
    # Check both atom and string keys
    profile_id = Map.get(attrs, :billing_profile_id) || Map.get(attrs, "billing_profile_id")

    case profile_id do
      nil ->
        attrs

      "" ->
        attrs

      id ->
        profile_id = if is_binary(id), do: String.to_integer(id), else: id
        profile = get_billing_profile!(profile_id)
        Map.put(attrs, "billing_snapshot", BillingProfile.to_snapshot(profile))
    end
  end

  # ============================================
  # INVOICES
  # ============================================

  @doc """
  Lists all invoices with optional filters.
  """
  def list_invoices(filters \\ %{}) do
    Invoice
    |> apply_invoice_filters(filters)
    |> order_by([i], desc: i.inserted_at)
    |> preload([:user, :order])
    |> repo().all()
  end

  @doc """
  Lists invoices for a specific user.
  """
  def list_user_invoices(user_id, filters \\ %{}) do
    Invoice
    |> where([i], i.user_id == ^user_id)
    |> apply_invoice_filters(filters)
    |> order_by([i], desc: i.inserted_at)
    |> repo().all()
  end

  @doc """
  Lists invoices with count for pagination.
  """
  def list_invoices_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    search = Keyword.get(opts, :search)
    status = Keyword.get(opts, :status)

    base_query = Invoice

    base_query =
      case status do
        nil -> base_query
        status -> where(base_query, [i], i.status == ^status)
      end

    base_query =
      case search do
        nil ->
          base_query

        "" ->
          base_query

        search ->
          search_term = "%#{search}%"

          base_query
          |> join(:left, [i], u in assoc(i, :user))
          |> where(
            [i, u],
            ilike(i.invoice_number, ^search_term) or
              ilike(u.email, ^search_term)
          )
      end

    total = repo().aggregate(base_query, :count, :id)

    preloads = Keyword.get(opts, :preload, [:user, :order])

    invoices =
      base_query
      |> order_by([i], desc: i.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload(^preloads)
      |> repo().all()

    {invoices, total}
  end

  @doc """
  Gets an invoice by ID.
  """
  def get_invoice!(id) do
    Invoice
    |> preload([:user, :order])
    |> repo().get!(id)
  end

  @doc """
  Gets an invoice by ID with optional preloads.
  """
  def get_invoice(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [:user, :order])

    Invoice
    |> preload(^preloads)
    |> repo().get(id)
  end

  @doc """
  Lists invoices for a specific order.
  """
  def list_invoices_for_order(order_id) do
    Invoice
    |> where([i], i.order_id == ^order_id)
    |> order_by([i], desc: i.inserted_at)
    |> repo().all()
  end

  @doc """
  Gets an invoice by invoice number.
  """
  def get_invoice_by_number(invoice_number) do
    Invoice
    |> where([i], i.invoice_number == ^invoice_number)
    |> preload([:user, :order])
    |> repo().one()
  end

  @doc """
  Creates an invoice from an order.
  """
  def create_invoice_from_order(%Order{} = order, opts \\ []) do
    config = get_config()

    opts =
      opts
      |> Keyword.put_new(:due_days, config.invoice_due_days)
      |> Keyword.put_new(:invoice_number, generate_invoice_number(config.invoice_prefix))
      |> Keyword.put_new(:bank_details, get_bank_details())
      |> Keyword.put_new(:payment_terms, get_payment_terms())

    invoice = Invoice.from_order(order, opts)

    invoice
    |> Invoice.changeset(%{})
    |> repo().insert()
  end

  @doc """
  Creates a standalone invoice (without order).
  """
  def create_invoice(user_or_id, attrs) do
    user_id = extract_user_id(user_or_id)
    config = get_config()

    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put_new(:invoice_number, generate_invoice_number(config.invoice_prefix))

    %Invoice{}
    |> Invoice.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates an invoice.
  """
  def update_invoice(%Invoice{} = invoice, attrs) do
    if Invoice.editable?(invoice) do
      invoice
      |> Invoice.changeset(attrs)
      |> repo().update()
    else
      {:error, :invoice_not_editable}
    end
  end

  @doc """
  Sends an invoice (marks as sent and sends email).

  Options:
  - `:send_email` - Whether to send email (default: true)
  - `:invoice_url` - URL to view invoice online (optional)
  """
  def send_invoice(%Invoice{} = invoice, opts \\ []) do
    if Invoice.sendable?(invoice) do
      send_email? = Keyword.get(opts, :send_email, true)

      # Update status first
      case invoice |> Invoice.status_changeset("sent") |> repo().update() do
        {:ok, updated_invoice} ->
          # Send email if requested and user exists
          if send_email? do
            send_invoice_email(updated_invoice, opts)
          end

          {:ok, updated_invoice}

        error ->
          error
      end
    else
      {:error, :invoice_not_sendable}
    end
  end

  @doc """
  Sends invoice email to the customer.
  """
  def send_invoice_email(%Invoice{} = invoice, opts \\ []) do
    # Preload user if not loaded
    invoice = ensure_preloaded(invoice, [:user, :order])

    case invoice.user do
      nil ->
        {:error, :no_user}

      user ->
        variables = build_invoice_email_variables(invoice, user, opts)

        Templates.send_email(
          "billing_invoice",
          user.email,
          variables,
          user_id: user.id,
          metadata: %{invoice_id: invoice.id, invoice_number: invoice.invoice_number}
        )
    end
  end

  defp ensure_preloaded(%{__struct__: _} = struct, preloads) do
    Enum.reduce(preloads, struct, fn preload, acc ->
      case Map.get(acc, preload) do
        %Ecto.Association.NotLoaded{} -> repo().preload(acc, preload)
        _ -> acc
      end
    end)
  end

  defp build_invoice_email_variables(invoice, user, opts) do
    invoice_url = Keyword.get(opts, :invoice_url, "")
    bank_details = invoice.bank_details || %{}
    billing_details = invoice.billing_details || %{}

    %{
      "user_email" => user.email,
      "user_name" => extract_user_name(billing_details, user),
      "invoice_number" => invoice.invoice_number,
      "invoice_date" => format_date(invoice.inserted_at),
      "due_date" => format_date(invoice.due_date),
      "subtotal" => format_decimal(invoice.subtotal),
      "tax_amount" => format_decimal(invoice.tax_amount),
      "total" => format_decimal(invoice.total),
      "currency" => invoice.currency,
      "line_items_html" => format_line_items_html(invoice.line_items),
      "line_items_text" => format_line_items_text(invoice.line_items),
      "company_name" => Settings.get_setting("billing_company_name", ""),
      "company_address" => Settings.get_setting("billing_company_address", ""),
      "company_vat" => Settings.get_setting("billing_company_vat", ""),
      "bank_name" => bank_details["bank_name"] || Settings.get_setting("billing_bank_name", ""),
      "bank_iban" => bank_details["iban"] || Settings.get_setting("billing_bank_iban", ""),
      "bank_swift" => bank_details["swift"] || Settings.get_setting("billing_bank_swift", ""),
      "payment_terms" =>
        invoice.payment_terms ||
          Settings.get_setting("billing_payment_terms", "Payment due within 14 days."),
      "invoice_url" => invoice_url
    }
  end

  defp extract_user_name(%{"company_name" => name}, _user) when is_binary(name) and name != "",
    do: name

  defp extract_user_name(%{"first_name" => first, "last_name" => last}, _user)
       when is_binary(first) and first != "",
       do: "#{first} #{last}"

  defp extract_user_name(_billing, %{first_name: first, last_name: last})
       when is_binary(first) and first != "",
       do: "#{first} #{last}"

  defp extract_user_name(_billing, user), do: user.email

  defp format_line_items_html(nil), do: ""

  defp format_line_items_html(items) do
    Enum.map_join(items, "\n", fn item ->
      desc =
        if item["description"],
          do: "<div class=\"item-desc\">#{item["description"]}</div>",
          else: ""

      """
      <tr>
        <td>
          <div class="item-name">#{item["name"]}</div>
          #{desc}
        </td>
        <td class="text-right">#{item["quantity"]}</td>
        <td class="text-right">#{item["unit_price"]}</td>
        <td class="text-right">#{item["total"]}</td>
      </tr>
      """
    end)
  end

  defp format_line_items_text(nil), do: ""

  defp format_line_items_text(items) do
    Enum.map_join(items, "\n", fn item ->
      "#{item["name"]} x #{item["quantity"]} @ #{item["unit_price"]} = #{item["total"]}"
    end)
  end

  defp format_date(nil), do: "-"
  defp format_date(%Date{} = date), do: Calendar.strftime(date, "%B %d, %Y")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%B %d, %Y")
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%B %d, %Y")

  defp format_decimal(nil), do: "0.00"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  @doc """
  Marks an invoice as paid (generates receipt).
  """
  def mark_invoice_paid(%Invoice{} = invoice) do
    if Invoice.payable?(invoice) do
      config = get_config()
      receipt_number = generate_receipt_number(config.receipt_prefix)

      result =
        invoice
        |> Invoice.paid_changeset(receipt_number)
        |> repo().update()

      # Also mark the order as paid if linked
      case result do
        {:ok, invoice} ->
          maybe_mark_linked_order_paid(invoice)
          {:ok, invoice}

        error ->
          error
      end
    else
      {:error, :invoice_not_payable}
    end
  end

  @doc """
  Voids an invoice.
  """
  def void_invoice(%Invoice{} = invoice, reason \\ nil) do
    if Invoice.voidable?(invoice) do
      changeset = Invoice.status_changeset(invoice, "void")

      changeset =
        if reason do
          Ecto.Changeset.put_change(changeset, :notes, reason)
        else
          changeset
        end

      repo().update(changeset)
    else
      {:error, :invoice_not_voidable}
    end
  end

  @doc """
  Generates a receipt for a paid invoice.
  """
  def generate_receipt(%Invoice{status: "paid"} = invoice) do
    if is_nil(invoice.receipt_number) do
      config = get_config()
      receipt_number = generate_receipt_number(config.receipt_prefix)

      invoice
      |> Ecto.Changeset.change(%{
        receipt_number: receipt_number,
        receipt_generated_at: DateTime.utc_now(),
        receipt_data: build_receipt_data(invoice)
      })
      |> repo().update()
    else
      {:error, :receipt_already_generated}
    end
  end

  def generate_receipt(_invoice), do: {:error, :invoice_not_paid}

  defp build_receipt_data(invoice) do
    %{
      invoice_number: invoice.invoice_number,
      total: Decimal.to_string(invoice.total),
      currency: invoice.currency,
      paid_at: DateTime.to_iso8601(invoice.paid_at),
      billing_details: invoice.billing_details
    }
  end

  @doc """
  Marks overdue invoices.
  """
  def mark_overdue_invoices do
    today = Date.utc_today()

    {count, _} =
      Invoice
      |> where([i], i.status == "sent" and i.due_date < ^today)
      |> repo().update_all(set: [status: "overdue"])

    {:ok, count}
  end

  defp apply_invoice_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, q when is_binary(status) ->
        where(q, [i], i.status == ^status)

      {:statuses, statuses}, q when is_list(statuses) ->
        where(q, [i], i.status in ^statuses)

      {:from_date, date}, q ->
        where(q, [i], i.inserted_at >= ^date)

      {:to_date, date}, q ->
        where(q, [i], i.inserted_at <= ^date)

      {:overdue, true}, q ->
        today = Date.utc_today()
        where(q, [i], i.status in ["sent", "overdue"] and i.due_date < ^today)

      _, q ->
        q
    end)
  end

  # ============================================
  # NUMBER GENERATION
  # ============================================

  defp generate_order_number(prefix) do
    year = Date.utc_today().year
    sequence = get_next_sequence("order", year)
    "#{prefix}-#{year}-#{String.pad_leading(to_string(sequence), 4, "0")}"
  end

  defp generate_invoice_number(prefix) do
    year = Date.utc_today().year
    sequence = get_next_sequence("invoice", year)
    "#{prefix}-#{year}-#{String.pad_leading(to_string(sequence), 4, "0")}"
  end

  defp generate_receipt_number(prefix) do
    year = Date.utc_today().year
    sequence = get_next_sequence("receipt", year)
    "#{prefix}-#{year}-#{String.pad_leading(to_string(sequence), 4, "0")}"
  end

  defp get_next_sequence(type, year) do
    # Simple approach: count existing records for the year
    # For production, consider using a separate sequence table
    start_of_year = Date.new!(year, 1, 1)
    end_of_year = Date.new!(year, 12, 31)

    count =
      case type do
        "order" ->
          Order
          |> where([o], fragment("DATE(?)", o.inserted_at) >= ^start_of_year)
          |> where([o], fragment("DATE(?)", o.inserted_at) <= ^end_of_year)
          |> repo().aggregate(:count, :id)

        "invoice" ->
          Invoice
          |> where([i], fragment("DATE(?)", i.inserted_at) >= ^start_of_year)
          |> where([i], fragment("DATE(?)", i.inserted_at) <= ^end_of_year)
          |> repo().aggregate(:count, :id)

        "receipt" ->
          Invoice
          |> where([i], not is_nil(i.receipt_number))
          |> where([i], fragment("DATE(?)", i.receipt_generated_at) >= ^start_of_year)
          |> where([i], fragment("DATE(?)", i.receipt_generated_at) <= ^end_of_year)
          |> repo().aggregate(:count, :id)
      end

    count + 1
  end

  # ============================================
  # HELPERS
  # ============================================

  defp extract_user_id(%{id: id}), do: id
  defp extract_user_id(id) when is_integer(id), do: id

  defp maybe_mark_linked_order_paid(%{order_id: nil}), do: :ok

  defp maybe_mark_linked_order_paid(%{order_id: order_id}) do
    case get_order!(order_id) do
      %Order{status: "confirmed"} = order -> mark_order_paid(order)
      _ -> :ok
    end
  end

  defp get_bank_details do
    %{
      bank_name: Settings.get_setting("billing_bank_name", ""),
      iban: Settings.get_setting("billing_bank_iban", ""),
      swift: Settings.get_setting("billing_bank_swift", ""),
      account_holder: Settings.get_setting("billing_bank_account_holder", "")
    }
  end

  defp get_payment_terms do
    Settings.get_setting("billing_payment_terms", "Payment due within 14 days of invoice date.")
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
