# Billing Module

The PhoenixKit Billing module provides a complete solution for managing orders, invoices, and payments with EU Standard support.

## Features

### Phase 1 (Current)

- **Orders** - Create and manage orders with line items
- **Invoices** - Generate invoices from orders, track status
- **Billing Profiles** - EU-compliant billing profiles (Individual/Company)
- **Currencies** - Multi-currency support with exchange rates
- **Manual Payments** - Bank transfer workflow with admin confirmation
- **Receipts** - Automatic receipt generation after payment

### Future Phases

- Payment Methods (saved cards, wallets)
- Stripe Integration
- PayPal Integration
- Razorpay Integration
- Subscriptions & Recurring Payments

## Workflow

```
1. User fills Billing Profile (personal or company details)
2. Admin creates Order for user
3. Invoice is generated from Order
4. Invoice is sent to user (email)
5. User pays via bank transfer
6. User notifies admin about payment
7. Admin marks Invoice as "paid"
8. Receipt is automatically generated
```

## Database Schema

### Tables

- `phoenix_kit_currencies` - Currency definitions (EUR, USD, etc.)
- `phoenix_kit_billing_profiles` - User billing information
- `phoenix_kit_orders` - Orders with line items
- `phoenix_kit_invoices` - Invoices with receipt support

### Order Statuses

| Status | Description |
|--------|-------------|
| `draft` | Order created, not yet confirmed |
| `pending` | Awaiting confirmation |
| `confirmed` | Order confirmed, ready for payment |
| `paid` | Payment received |
| `cancelled` | Order cancelled |
| `refunded` | Payment refunded |

### Invoice Statuses

| Status | Description |
|--------|-------------|
| `draft` | Invoice created, not sent |
| `sent` | Invoice sent to customer |
| `paid` | Payment received |
| `void` | Invoice cancelled |
| `overdue` | Past due date |

## Admin Routes

| Path | Description |
|------|-------------|
| `/admin/billing` | Billing dashboard with statistics |
| `/admin/billing/orders` | Orders list with filters |
| `/admin/billing/orders/new` | Create new order |
| `/admin/billing/orders/:id` | Order details |
| `/admin/billing/orders/:id/edit` | Edit order |
| `/admin/billing/invoices` | Invoices list with filters |
| `/admin/billing/invoices/:id` | Invoice details |
| `/admin/billing/profiles` | Billing profiles list |
| `/admin/billing/currencies` | Currency management |
| `/admin/settings/billing` | Module settings |

## Configuration

### Settings (via Admin UI)

- **Default Currency** - Default currency for new orders (EUR)
- **Invoice Prefix** - Prefix for invoice numbers (INV)
- **Order Prefix** - Prefix for order numbers (ORD)
- **Receipt Prefix** - Prefix for receipt numbers (RCP)
- **Invoice Due Days** - Default days until invoice due date (14)
- **Default Tax Rate** - Default tax rate for new orders (0%)
- **Company Information** - Your company billing details
- **Bank Details** - Bank account for payments

## API Usage

### Enable/Disable Module

```elixir
# Check if billing is enabled
PhoenixKit.Modules.Billing.enabled?()

# Enable billing module
PhoenixKit.Modules.Billing.enable_system()

# Disable billing module
PhoenixKit.Modules.Billing.disable_system()
```

### Orders

```elixir
# Create order
{:ok, order} = PhoenixKit.Modules.Billing.create_order(user, %{
  currency: "EUR",
  payment_method: "bank",
  line_items: [
    %{name: "Service", quantity: 1, unit_price: "100.00"}
  ]
})

# Get order with preloads
order = PhoenixKit.Modules.Billing.get_order(id, preload: [:user, :billing_profile])

# List orders with pagination
{orders, total} = PhoenixKit.Modules.Billing.list_orders_with_count(
  page: 1,
  per_page: 25,
  status: "confirmed",
  search: "customer@example.com"
)

# Update order status
{:ok, order} = PhoenixKit.Modules.Billing.confirm_order(order)
{:ok, order} = PhoenixKit.Modules.Billing.mark_order_paid(order)
{:ok, order} = PhoenixKit.Modules.Billing.cancel_order(order)
```

### Invoices

```elixir
# Generate invoice from order
{:ok, invoice} = PhoenixKit.Modules.Billing.create_invoice_from_order(order)

# Update invoice status
{:ok, invoice} = PhoenixKit.Modules.Billing.send_invoice(invoice)
{:ok, invoice} = PhoenixKit.Modules.Billing.mark_invoice_paid(invoice)
{:ok, invoice} = PhoenixKit.Modules.Billing.void_invoice(invoice)

# Generate receipt after payment
{:ok, invoice} = PhoenixKit.Modules.Billing.generate_receipt(invoice)

# List invoices with pagination
{invoices, total} = PhoenixKit.Modules.Billing.list_invoices_with_count(
  page: 1,
  per_page: 25,
  status: "sent"
)
```

### Billing Profiles

```elixir
# Create individual profile
{:ok, profile} = PhoenixKit.Modules.Billing.create_billing_profile(user, %{
  type: "individual",
  first_name: "John",
  last_name: "Doe",
  address_line1: "123 Main St",
  city: "Tallinn",
  country: "EE"
})

# Create company profile (EU Standard)
{:ok, profile} = PhoenixKit.Modules.Billing.create_billing_profile(user, %{
  type: "company",
  company_name: "Acme OÜ",
  company_vat_number: "EE123456789",
  company_registration_number: "12345678",
  address_line1: "Business St 1",
  city: "Tallinn",
  country: "EE"
})

# Get user's billing profiles
profiles = PhoenixKit.Modules.Billing.list_user_billing_profiles(user_id)

# Set default profile
{:ok, profile} = PhoenixKit.Modules.Billing.set_default_billing_profile(profile)
```

### Currencies

```elixir
# List enabled currencies
currencies = PhoenixKit.Modules.Billing.list_currencies(enabled: true)

# Get default currency
currency = PhoenixKit.Modules.Billing.get_default_currency()

# Update currency
{:ok, currency} = PhoenixKit.Modules.Billing.update_currency(currency, %{
  exchange_rate: Decimal.new("1.08")
})
```

## Components

### Status Badges

```heex
<%!-- Order status badge --%>
<.order_status_badge status={@order.status} />
<.order_status_badge status={@order.status} size={:sm} />
<.order_status_badge status={@order.status} size={:lg} />

<%!-- Invoice status badge --%>
<.invoice_status_badge status={@invoice.status} />
<.invoice_status_badge status={@invoice.status} size={:md} />
```

### Currency Display

```heex
<%!-- Format currency amount --%>
<.currency_amount amount={@invoice.total} currency="EUR" />
<%!-- Output: €100.00 --%>

<%!-- Compact format (smaller) --%>
<.currency_compact amount={@order.subtotal} currency="USD" />

<%!-- Currency badge --%>
<.currency_badge code="EUR" />
<.currency_badge code="USD" size={:sm} />
```

## Events (PubSub)

The billing module broadcasts events for real-time updates:

```elixir
# Subscribe to billing events
PhoenixKit.Modules.Billing.Events.subscribe()

# Events broadcasted:
# {:order_created, order}
# {:order_updated, order}
# {:order_confirmed, order}
# {:order_paid, order}
# {:order_cancelled, order}
# {:invoice_created, invoice}
# {:invoice_sent, invoice}
# {:invoice_paid, invoice}
# {:invoice_voided, invoice}
```

## EU Compliance

The billing module supports EU Standard requirements:

- **VAT Number** - Company VAT registration (format: CC123456789)
- **Registration Number** - Company registration number
- **Legal Address** - Company legal address
- **Individual Data** - First name, last name, personal ID
- **Address Fields** - Full address with country codes

## Files Structure

```
lib/phoenix_kit/
├── billing/
│   ├── billing.ex           # Main context API
│   ├── currency.ex          # Currency schema
│   ├── billing_profile.ex   # Billing profile schema
│   ├── order.ex             # Order schema
│   ├── invoice.ex           # Invoice schema
│   └── events.ex            # PubSub events
│
├── migrations/postgres/
│   └── v29.ex               # Billing tables migration

lib/phoenix_kit_web/
├── live/modules/billing/
│   ├── README.md            # This file
│   ├── index.ex             # Dashboard
│   ├── orders.ex            # Orders list
│   ├── order_detail.ex      # Order details
│   ├── order_form.ex        # Create/Edit order
│   ├── invoices.ex          # Invoices list
│   ├── invoice_detail.ex    # Invoice details
│   ├── billing_profiles.ex  # Profiles list
│   ├── currencies.ex        # Currency management
│   └── settings.ex          # Module settings
│
└── components/core/
    ├── order_status_badge.ex
    ├── invoice_status_badge.ex
    └── currency_display.ex
```
