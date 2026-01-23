# Plan: Variant Image Mapping for Shop Products

## Overview

Add ability to link product images to specific option values. When a customer selects an option (e.g., color "Red"), the product gallery automatically displays the corresponding image.

## Scope

**In scope:**
- Store image mappings in product `metadata._image_mappings`
- Admin UI to link images to option values in ProductForm
- Automatic image switching on CatalogProduct when option selected
- Fallback to featured_image/first gallery image when no mapping exists

**Out of scope:**
- Combination keys for multi-option mappings (e.g., "Red|Wood")
- Legacy URL-based images support (require Storage migration first)
- Image preloading optimization (can be added later)

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Multiple options precedence | Last selected option wins | Intuitive UX - user sees result of their last action |
| Admin UI location | Options & Pricing section | All option-related config in one place |
| Legacy images | Storage-only | Simpler implementation, encourages migration |
| Mapping structure | Single-level per option key | Simpler, covers 95% use cases |

## Data Model

### Metadata Structure

```elixir
# product.metadata
%{
  "_option_values" => %{"color" => ["Red", "Blue", "Green"]},
  "_price_modifiers" => %{"color" => %{"Red" => "0", "Blue" => "5"}},
  "_image_mappings" => %{    # NEW
    "color" => %{
      "Red" => "uuid-of-red-image",
      "Blue" => "uuid-of-blue-image"
    }
  }
}
```

### Validation Rules

- Image UUID must exist in product's `image_ids` or `featured_image_id`
- Option key must exist in `_option_values` or option schema
- Option value must be valid for that key

## Implementation Steps

### Step 1: Update CatalogProduct - Image Switching Logic

**File:** `lib/modules/shop/web/catalog_product.ex`

1. Add `last_selected_option` to socket assigns (track which option was last changed)
2. Modify `handle_event("select_spec", ...)` to:
   - Store which option key was just selected
   - Look up `_image_mappings` for that option key + value
   - If found, update `selected_image` to mapped image URL
   - If not found, keep current image (don't revert to default)

```elixir
# In handle_event("select_spec", params, socket)
def handle_event("select_spec", params, socket) do
  key = params["key"] || ""
  value = params["opt"] || ""

  selected_specs = Map.put(socket.assigns.selected_specs, key, value)
  product = socket.assigns.product

  # Check for image mapping
  selected_image = get_mapped_image(product, key, value, socket.assigns.selected_image)

  # ... existing price calculation ...

  socket
  |> assign(:selected_specs, selected_specs)
  |> assign(:selected_image, selected_image)
  |> assign(:calculated_price, calculated_price)
  # ...
end

defp get_mapped_image(product, option_key, option_value, current_image) do
  case get_in(product.metadata, ["_image_mappings", option_key, option_value]) do
    nil -> current_image  # Keep current if no mapping
    image_id -> get_storage_image_url(image_id, "large")
  end
end
```

**Acceptance:**
- [ ] Selecting option with image mapping updates main product image
- [ ] Selecting option without mapping keeps current image
- [ ] Works with multiple option selections (last one with mapping wins)

### Step 2: Add Admin UI in ProductForm

**File:** `lib/modules/shop/web/product_form.ex`

Add new section after "Option Prices" for image mappings:

1. Only show for products with `image_ids` (has gallery images)
2. Only show for options that have `_option_values` defined
3. For each option value, show dropdown to select image from gallery
4. Save to `metadata._image_mappings`

```heex
<%!-- Image Mappings Section --%>
<%= if @gallery_image_ids != [] and has_mappable_options?(assigns) do %>
  <div class="card bg-base-100 shadow-xl">
    <div class="card-body">
      <h2 class="card-title">
        <.icon name="hero-photo" class="w-5 h-5" /> Variant Images
      </h2>
      <p class="text-sm text-base-content/60 mb-4">
        Link images to option values. When customer selects an option, the corresponding image displays.
      </p>

      <%= for {option_key, option_values} <- get_mappable_options(assigns) do %>
        <div class="p-4 bg-base-200 rounded-lg mb-4">
          <h3 class="font-medium mb-3">{humanize_key(option_key)}</h3>
          <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
            <%= for value <- option_values do %>
              <div class="flex flex-col gap-2">
                <span class="text-sm font-medium">{value}</span>
                <select
                  name={"product[metadata][_image_mappings][#{option_key}][#{value}]"}
                  class="select select-bordered select-sm"
                >
                  <option value="">No image</option>
                  <%= for image_id <- @gallery_image_ids do %>
                    <option
                      value={image_id}
                      selected={get_image_mapping(@metadata, option_key, value) == image_id}
                    >
                      Image #{Enum.find_index(@gallery_image_ids, &(&1 == image_id)) + 1}
                    </option>
                  <% end %>
                </select>
                <%!-- Preview thumbnail --%>
                <%= if mapping = get_image_mapping(@metadata, option_key, value) do %>
                  <img
                    src={get_image_url(mapping, "thumbnail")}
                    class="w-16 h-16 object-cover rounded"
                  />
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
  </div>
<% end %>
```

**Helper functions:**

```elixir
defp has_mappable_options?(assigns) do
  assigns[:original_option_values] != %{} or
    Enum.any?(assigns[:option_schema] || [], &(&1["type"] in ["select", "multiselect"]))
end

defp get_mappable_options(assigns) do
  # Combine schema options with product-specific option values
  schema_options =
    (assigns[:option_schema] || [])
    |> Enum.filter(&(&1["type"] in ["select", "multiselect"]))
    |> Enum.map(&{&1["key"], &1["options"] || []})
    |> Map.new()

  product_options = assigns[:original_option_values] || %{}

  Map.merge(schema_options, product_options, fn _k, schema, product ->
    Enum.uniq(schema ++ product)
  end)
  |> Enum.reject(fn {_k, v} -> v == [] end)
end

defp get_image_mapping(metadata, option_key, value) do
  get_in(metadata, ["_image_mappings", option_key, value])
end

defp humanize_key(key) do
  key
  |> String.replace("_", " ")
  |> String.capitalize()
end
```

**Acceptance:**
- [ ] Section only appears when product has gallery images AND mappable options
- [ ] Each option value has dropdown with gallery images
- [ ] Selected mappings show thumbnail preview
- [ ] Mappings persist on save

### Step 3: Handle Image Mappings in Form Save

**File:** `lib/modules/shop/web/product_form.ex`

Update `handle_event("save", ...)` to clean up image mappings:

```elixir
# In handle_event("save", ...)
# After existing metadata processing

# Clean up _image_mappings - remove empty values
metadata = clean_image_mappings(metadata, socket.assigns.gallery_image_ids)

defp clean_image_mappings(metadata, valid_image_ids) do
  case metadata["_image_mappings"] do
    nil -> metadata
    mappings when is_map(mappings) ->
      cleaned =
        mappings
        |> Enum.map(fn {option_key, value_mappings} ->
          cleaned_values =
            value_mappings
            |> Enum.reject(fn {_v, image_id} ->
              image_id == "" or image_id == nil or image_id not in valid_image_ids
            end)
            |> Map.new()

          {option_key, cleaned_values}
        end)
        |> Enum.reject(fn {_k, v} -> v == %{} end)
        |> Map.new()

      if cleaned == %{} do
        Map.delete(metadata, "_image_mappings")
      else
        Map.put(metadata, "_image_mappings", cleaned)
      end
  end
end
```

**Acceptance:**
- [ ] Empty mappings not saved
- [ ] Invalid image IDs (deleted images) not saved
- [ ] Mappings for removed option values cleaned up

### Step 4: Update Thumbnail Gallery Sync

**File:** `lib/modules/shop/web/catalog_product.ex`

When image changes via option selection, highlight corresponding thumbnail:

```elixir
# In template, update thumbnail button class logic
<button
  phx-click="select_storage_image"
  phx-value-id={image_id}
  class={[
    "w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 border-2 transition-colors",
    if(is_selected_image?(@selected_image, image_id),
      do: "border-primary",
      else: "border-transparent hover:border-base-300"
    )
  ]}
>

# Helper
defp is_selected_image?(selected_url, image_id) do
  expected_url = get_storage_image_url(image_id, "large")
  selected_url == expected_url
end
```

**Acceptance:**
- [ ] Thumbnail border updates when option changes image
- [ ] Clicking thumbnail still works independently

### Step 5: Validate Image Mappings on Product Load

**File:** `lib/modules/shop/web/product_form.ex`

In `apply_action(:edit, ...)`, validate and clean stale mappings:

```elixir
# After loading product
metadata = product.metadata || %{}
gallery_ids = product.image_ids || []
featured_id = product.featured_image_id

# Clean stale image mappings (images that no longer exist)
valid_ids = if featured_id, do: [featured_id | gallery_ids], else: gallery_ids
metadata = clean_stale_image_mappings(metadata, valid_ids)

defp clean_stale_image_mappings(metadata, valid_ids) do
  case metadata["_image_mappings"] do
    nil -> metadata
    mappings ->
      cleaned =
        Enum.map(mappings, fn {key, value_map} ->
          filtered = Enum.filter(value_map, fn {_v, id} -> id in valid_ids end) |> Map.new()
          {key, filtered}
        end)
        |> Enum.reject(fn {_k, v} -> v == %{} end)
        |> Map.new()

      if cleaned == %{},
        do: Map.delete(metadata, "_image_mappings"),
        else: Map.put(metadata, "_image_mappings", cleaned)
  end
end
```

**Acceptance:**
- [ ] Opening edit form removes mappings to deleted images
- [ ] Warning shown if mappings were cleaned

## Testing Checklist

### Manual Testing

1. **Create product with options and images**
   - Add gallery images (3+)
   - Add option "Color" with values Red, Blue, Green
   - Map Red -> Image 1, Blue -> Image 2
   - Save and verify mappings persisted

2. **Customer view**
   - Open product page
   - Select Color: Red -> Image 1 shown
   - Select Color: Blue -> Image 2 shown
   - Select Color: Green -> Previous image stays (no mapping)

3. **Multiple options**
   - Add second option "Size" with image mapping
   - Select Color: Red (Image 1 shown)
   - Select Size: Large (Image 3 shown - last selected wins)
   - Select Color: Blue (Image 2 shown - overrides Size)

4. **Edge cases**
   - Delete an image from gallery, verify mapping cleaned on edit
   - Remove option value, verify mapping cleaned on save
   - Product without gallery images - section hidden

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Orphan mappings after image deletion | Clean on product edit, graceful handling on catalog |
| Performance with many options | Lazy evaluation, only process visible options |
| User confusion with last-wins logic | Clear UI indication of which option controls image |

## References

- Product schema: `/app/lib/modules/shop/schemas/product.ex:70-77`
- CatalogProduct select_spec: `/app/lib/modules/shop/web/catalog_product.ex:201-237`
- ProductForm media handling: `/app/lib/modules/shop/web/product_form.ex:253-267`
- Storage URL signing: `/app/lib/modules/storage/services/url_signer.ex`

## Future Enhancements

- Combination mappings (color+material)
- Default mappings in option schema (global/category level)
- Bulk mapping tool (copy mappings between products)
- Image preloading for faster switching
- Animation/transition effects
