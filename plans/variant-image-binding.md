# Plan: Variant Image Binding for Shop Products

## Overview

Enable binding specific images from the product gallery to option values (variants), so when a user selects a variant, the corresponding image automatically displays.

## Current State

### Image System
- **Storage images**: `featured_image_id` (UUID), `image_ids` (UUID array)
- **Legacy images**: `images` (array of maps/strings), `featured_image` (URL string)
- Images displayed via `get_display_images/1` → Storage URLSigner

### Variant/Options System
- Options defined at: Global (`shop_config`) + Category (`category.option_schema`)
- Product-specific values: `metadata["_option_values"]` = `%{"material" => ["PLA", "PETG"], ...}`
- Price modifiers: `metadata["_price_modifiers"]` = `%{"material" => %{"PETG" => "10.00"}, ...}`
- No separate variants table — everything in product metadata JSONB

### Product Detail Page (`catalog_product.ex`)
- `select_spec` event updates `selected_specs` and recalculates price
- `selected_image` assign controls main image display
- Thumbnails clickable via `select_image`/`select_storage_image` events
- **No automatic image switch on variant selection**

## Proposed Solution

### Data Model

Add new metadata key `_option_images` to product metadata:

```elixir
%{
  "_option_images" => %{
    "material" => %{
      "PLA" => "uuid-of-pla-image",
      "PETG" => "uuid-of-petg-image"
    },
    "color" => %{
      "White" => "uuid-of-white-image",
      "Black" => "uuid-of-black-image"
    }
  }
}
```

- Keys are option keys (same as in `_option_values`)
- Values map option value → image UUID from `image_ids`
- Only Storage images supported (UUIDs), not legacy URLs

### Why This Approach

1. **Consistent with existing patterns**: Same structure as `_option_values` and `_price_modifiers`
2. **No schema changes**: Uses existing JSONB `metadata` field
3. **No migration needed**: Just add data to existing field
4. **Flexible**: Any option can have image bindings, not just specific ones

## Implementation Tasks

### Task 1: Update Product Detail Page (catalog_product.ex)

**File**: `lib/modules/shop/web/catalog_product.ex`

1. On `select_spec` event, after updating `selected_specs`:
   - Check if `product.metadata["_option_images"][key]` exists
   - If image UUID found for selected value, update `selected_image` assign
   - Use existing `get_storage_image_url/2` to resolve URL

2. Add helper function:
```elixir
defp get_image_for_spec(product, key, value) do
  case get_in(product.metadata || %{}, ["_option_images", key, value]) do
    nil -> nil
    image_id -> get_storage_image_url(image_id, "large")
  end
end
```

3. Modify `handle_event("select_spec", ...)` to call `maybe_update_selected_image/3`

### Task 2: Admin UI for Image Binding (product_form.ex)

**File**: `lib/modules/shop/web/product_form.ex`

1. Add UI section in price-affecting options area:
   - Show option values with image selector dropdown
   - Dropdown lists available gallery images (from `image_ids`)
   - Show thumbnail preview of selected image

2. Add state:
   - `option_images` assign to track current bindings
   - Load from `metadata["_option_images"]` on mount

3. Add events:
   - `bind_option_image` - Set image for option value
   - `unbind_option_image` - Remove image binding

4. Save bindings to `metadata["_option_images"]` on form submit

### Task 3: Context Functions (shop.ex)

**File**: `lib/modules/shop/shop.ex`

Add helper functions:
```elixir
@doc "Get image UUID for option value"
def get_option_image(product, option_key, option_value)

@doc "Set image binding for option value"
def set_option_image(product, option_key, option_value, image_id)

@doc "Remove image binding for option value"
def remove_option_image(product, option_key, option_value)

@doc "Get all option images map"
def get_option_images(product)
```

### Task 4: Initial Image Selection on Mount

**File**: `lib/modules/shop/web/catalog_product.ex`

1. In `mount/3`, after building `selected_specs`:
   - Check if any default spec has an image binding
   - Set `selected_image` to bound image if found
   - Fall back to `first_image(product)` if no binding

2. Priority: Bound image > Featured image > First gallery image

## UI Design

### Admin Product Form

```
┌─────────────────────────────────────────────────────────┐
│ Options & Pricing                                       │
├─────────────────────────────────────────────────────────┤
│ Material                                                │
│ ┌─────────────────────────────────────────────────────┐│
│ │ Value      │ Price   │ Final   │ Image             ││
│ ├────────────┼─────────┼─────────┼───────────────────┤│
│ │ PLA        │ €0.00   │ €25.00  │ [🖼️ Select ▼]    ││
│ │ PETG       │ €10.00  │ €35.00  │ [🖼️ PETG.jpg ▼] ││
│ │ ABS        │ €5.00   │ €30.00  │ [No image ▼]     ││
│ └─────────────────────────────────────────────────────┘│
│                                                         │
│ Color                                                   │
│ ┌─────────────────────────────────────────────────────┐│
│ │ Value      │ Price   │ Final   │ Image             ││
│ ├────────────┼─────────┼─────────┼───────────────────┤│
│ │ White      │ €0.00   │ €25.00  │ [🖼️ White.jpg ▼] ││
│ │ Black      │ €0.00   │ €25.00  │ [🖼️ Black.jpg ▼] ││
│ └─────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘
```

### Catalog Product Page

No visible UI changes — image switches automatically when variant selected.

## Migration Path

1. No database migration needed
2. Existing products continue to work (no `_option_images` = no auto-switch)
3. Admin can gradually add image bindings to products

## Files to Modify

| File | Changes |
|------|---------|
| `lib/modules/shop/web/catalog_product.ex` | Auto-switch image on spec selection |
| `lib/modules/shop/web/product_form.ex` | Image binding UI in options table |
| `lib/modules/shop/shop.ex` | Helper functions for option images |

## Testing Checklist

- [ ] Create product with multiple images and options
- [ ] Bind images to option values in admin
- [ ] Verify image switches when selecting options in catalog
- [ ] Verify multiple options can each have bound images
- [ ] Verify last selected option's image takes priority
- [ ] Verify fallback to featured/first image when no binding
- [ ] Verify unbinding works correctly
- [ ] Verify save/load cycle preserves bindings

## Edge Cases

1. **Multiple options selected**: Last changed option's image wins
2. **Option with no bound image**: Keep current image (don't reset)
3. **Image deleted from gallery**: Binding becomes orphaned (show placeholder)
4. **Import products with images**: CSV import could include `_option_images` JSON
