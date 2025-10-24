defmodule PhoenixKitWeb.Components.PersistentPopup do
  @moduledoc """
  A draggable, resizable popup component with state persistence across LiveView navigation.

  This component provides a floating popup that maintains its position, size, scroll,
  and open/closed state across LiveView page transitions and browser refreshes using
  sessionStorage.

  ## Features

  - Drag to reposition
  - Resize from bottom-right corner
  - Persists state across navigation and refresh
  - Resets to defaults when manually opened
  - Keyboard accessible (Escape to close)
  - No flicker during LiveView navigation
  - Multiple independent popups supported

  ## Usage

  Place the popup container somewhere in your layout:

      <.persistent_popup id="my-debug-popup">
        <div>Your popup content here</div>
      </.persistent_popup>

  Add a button to toggle it (can be anywhere):

      <.popup_button target_id="my-debug-popup" class="btn btn-primary">
        Open Debug Info
      </.popup_button>

  ## Multiple Popups

  You can have as many popups as you want, each with a unique ID:

      <.persistent_popup id="debug-popup">Debug info</.persistent_popup>
      <.persistent_popup id="console-popup">Console</.persistent_popup>
      <.persistent_popup id="errors-popup">Errors</.persistent_popup>

      <.popup_button target_id="debug-popup">Debug</.popup_button>
      <.popup_button target_id="console-popup">Console</.popup_button>
      <.popup_button target_id="errors-popup">Errors</.popup_button>

  ## Implementation Notes

  - Popups are automatically registered when the page loads
  - Each popup maintains independent state in sessionStorage
  - State includes: position, size, scroll, and open/closed status
  - Uses requestAnimationFrame for flicker-free navigation
  - Automatically cleans up stale popups after LiveView navigation
  """

  use Phoenix.Component

  @doc """
  Renders a persistent popup container.

  The popup is hidden by default. Use `popup_button` to toggle it.
  """
  attr :id, :string, required: true, doc: "Unique identifier for this popup"
  attr :class, :string, default: "", doc: "Additional CSS classes for the popup container"
  slot :inner_block, required: true, doc: "Popup content"

  def persistent_popup(assigns) do
    ~H"""
    <div
      id={@id}
      class={["fixed inset-0 z-[70] pointer-events-none", @class]}
      aria-hidden="true"
      style="display: none;"
      data-popup-container
      data-popup-id={@id}
      data-popup-register={@id}
    >
      <section
        data-popup-panel
        role="dialog"
        aria-modal="true"
        aria-label="Popup"
        tabindex="-1"
        class="absolute flex flex-col rounded-2xl border border-base-300 bg-base-100 shadow-2xl pointer-events-auto opacity-0 transition-opacity duration-75"
        style="left: 50%; top: 20%; transform: translateX(-50%); width: 448px; min-height: 320px;"
      >
        <%!-- Drag Handle --%>
        <header
          data-popup-handle
          class="cursor-grab active:cursor-grabbing select-none rounded-t-2xl border-b border-base-200 bg-gradient-to-r from-primary/10 to-primary/5 px-6 py-4 text-base-content flex-shrink-0"
        >
          <div class="flex w-full justify-center">
            <span class="h-2 w-16 rounded-full bg-primary/30"></span>
          </div>
        </header>

        <%!-- Content Area --%>
        <div
          data-popup-content
          class="px-6 py-5 space-y-4 text-sm text-base-content/80 min-h-0 flex-1 overflow-auto"
        >
          {render_slot(@inner_block)}
        </div>

        <%!-- Footer with Close Button --%>
        <footer class="flex items-center justify-end border-t border-base-200 px-6 py-4 gap-3 flex-shrink-0">
          <button
            type="button"
            data-popup-close
            class="btn btn-ghost btn-sm"
          >
            Close
          </button>
        </footer>

        <%!-- Resize Handle --%>
        <div
          data-popup-resize-handle
          class="absolute -bottom-2 -right-2 flex h-8 w-8 cursor-se-resize items-center justify-center rounded-full border border-base-200 bg-base-100/90 text-primary/70 shadow-md transition hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
          aria-hidden="true"
        >
          <svg class="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
            <circle cx="3" cy="3" r="1.5" />
            <circle cx="8" cy="3" r="1.5" />
            <circle cx="13" cy="3" r="1.5" />
            <circle cx="3" cy="8" r="1.5" />
            <circle cx="8" cy="8" r="1.5" />
            <circle cx="13" cy="8" r="1.5" />
            <circle cx="3" cy="13" r="1.5" />
            <circle cx="8" cy="13" r="1.5" />
            <circle cx="13" cy="13" r="1.5" />
          </svg>
        </div>
      </section>
    </div>
    """
  end

  @doc """
  Renders a button that toggles a persistent popup.

  The button text will automatically change between the slot content (when closed)
  and "Close Popup" (when open).

  ## Examples

      <.popup_button target_id="my-popup" class="btn btn-primary">
        Open Debug
      </.popup_button>

  This will show "Open Debug" when closed and "Close Popup" when open.
  """
  attr :target_id, :string, required: true, doc: "ID of the popup to control"
  attr :class, :string, default: "", doc: "CSS classes for the button"
  slot :inner_block, required: true, doc: "Button text (when closed)"

  def popup_button(assigns) do
    ~H"""
    <button
      id={"#{@target_id}-button"}
      type="button"
      aria-controls={@target_id}
      aria-expanded="false"
      data-popup-toggle={@target_id}
      class={@class}
    >
      <span data-popup-button-text>
        {render_slot(@inner_block)}
      </span>
    </button>
    """
  end

  @doc """
  Outputs the PersistentPopup JavaScript library.

  Include this once in your layout. This only needs to be included once,
  even if you have multiple popups.

  ## Usage

      <PhoenixKitWeb.Components.PersistentPopup.popup_script />
  """
  def popup_script(assigns) do
    ~H"""
    <script>
      // ======================================================================================
      // PersistentPopup Library
      // ======================================================================================
      // A clean, class-based architecture for managing multiple draggable, resizable popups
      // that persist their state across Phoenix LiveView navigation.
      //
      // ARCHITECTURE:
      //   - PopupManager: Singleton that manages all popup instances and handles global events
      //   - Popup: Individual popup instance with its own state, DOM elements, and event handlers
      //
      // USAGE:
      //   1. Include this script once in your layout (via popup_script/1 component)
      //   2. Create popup HTML with the persistent_popup/1 component
      //   3. Popups are automatically discovered and registered via data-popup-register attribute
      //   4. After LiveView navigation, popups are re-scanned and stale ones are cleaned up
      //
      // STATE PERSISTENCE:
      //   - Each popup's state is saved to sessionStorage independently
      //   - State includes: position, size, scroll offset, and open/closed status
      //   - State survives page refreshes and LiveView navigation
      //
      // LIVEVIEW INTEGRATION:
      //   - Listens to phx:page-loading-start to save scroll positions before navigation
      //   - Listens to phx:page-loading-stop to re-initialize popups after navigation
      //   - Uses requestAnimationFrame to restore state before browser paints (prevents flicker)
      // ======================================================================================

      (function() {
        'use strict';

        // SessionStorage key for storing all popup states
        const STORAGE_KEY = 'phoenix_kit_popups';

        // ======================================================================================
        // Popup Class
        // ======================================================================================
        // Represents a single popup instance. Each popup on the page gets its own instance
        // of this class, which manages its state, DOM elements, and user interactions.
        //
        // RESPONSIBILITIES:
        //   - Find and cache DOM elements (container, panel, buttons, etc.)
        //   - Attach and cleanup event listeners (drag, resize, keyboard, etc.)
        //   - Handle user interactions (open, close, drag, resize)
        //   - Save and restore state from sessionStorage
        //   - Coordinate with PopupManager for global events
        // ======================================================================================
        class Popup {
          // ====================================================================================
          // Constructor
          // ====================================================================================
          // Creates a new Popup instance. Called by PopupManager.register(id).
          //
          // Parameters:
          //   id: string - The unique ID of the popup element (e.g., "debug-popup")
          //   manager: PopupManager - Reference to the singleton manager
          // ====================================================================================
          constructor(id, manager) {
            this.id = id;
            this.manager = manager;

            // DOM element references (cached after init())
            // These are null until init() is called and successfully finds the elements
            this.container = null;     // The outer <div id="popup-id"> wrapper
            this.panel = null;          // The inner <section data-popup-panel> containing content
            this.handle = null;         // The <header data-popup-handle> drag handle
            this.content = null;        // The <div data-popup-content> scrollable area
            this.resizeHandle = null;   // The <div data-popup-resize-handle> resize grip
            this.openButton = null;     // The <button id="popup-id-button"> toggle button
            this.closeButtons = [];     // Array of <button data-popup-close> inside popup

            // Popup state flags
            this.isOpen = false;        // Is popup currently visible?
            this.isDragging = false;    // Is user actively dragging the popup?
            this.isResizing = false;    // Is user actively resizing the popup?
            this.isInitialized = false; // Has init() completed successfully?

            // Drag operation state
            // These track the drag operation from pointerdown to pointerup
            this.dragPointerId = null;  // Pointer ID for the active drag (for multi-touch)
            this.dragOffsetX = 0;       // Horizontal offset from mouse to panel's left edge
            this.dragOffsetY = 0;       // Vertical offset from mouse to panel's top edge

            // Resize operation state
            // These track the resize operation from pointerdown to pointerup
            this.resizePointerId = null;   // Pointer ID for the active resize
            this.resizeStartX = 0;         // Mouse X position when resize started
            this.resizeStartY = 0;         // Mouse Y position when resize started
            this.resizeStartWidth = 0;     // Panel width when resize started
            this.resizeStartHeight = 0;    // Panel height when resize started

            // Bound event handler functions
            // We store references to bound handlers so we can properly remove them later.
            // Without storing these, removeEventListener won't work because each bind()
            // creates a new function reference.
            this.handlers = {
              toggle: null,      // Bound version of this.toggle()
              close: null,       // Bound version of this.close()
              dragStart: null,   // Bound version of this.startDrag()
              dragMove: null,    // Bound version of this.handleDragMove()
              dragEnd: null,     // Bound version of this.endDrag()
              resizeStart: null, // Bound version of this.startResize()
              resizeMove: null,  // Bound version of this.handleResizeMove()
              resizeEnd: null,   // Bound version of this.endResize()
              keydown: null,     // Bound version of this.handleKeydown()
              scroll: null       // Bound version of this.saveScrollPosition()
            };
          }

          // ====================================================================================
          // Initialization
          // ====================================================================================
          // Finds DOM elements, creates event handlers, attaches listeners, and restores state.
          // Called by PopupManager when registering a popup, and again after LiveView navigation.
          //
          // Returns:
          //   boolean - true if initialization succeeded, false if required elements missing
          //
          // NOTE: This function is safe to call multiple times (e.g., after LiveView navigation).
          //       It will cleanup old listeners and create fresh ones with new DOM references.
          // ====================================================================================
          init() {
            console.log(`[Popup:${this.id}] Initializing`);

            // Find the main popup container and toggle button
            // These are the minimum required elements - without them we can't do anything
            this.container = document.getElementById(this.id);
            this.openButton = document.getElementById(`${this.id}-button`);

            if (!this.container || !this.openButton) {
              console.warn(`[Popup:${this.id}] Missing elements, skipping init`);
              return false;
            }

            // Find internal popup elements using data attributes
            // data-popup-* attributes make it easy to query elements regardless of styling
            this.panel = this.container.querySelector('[data-popup-panel]');
            this.handle = this.container.querySelector('[data-popup-handle]');
            this.content = this.container.querySelector('[data-popup-content]');
            this.resizeHandle = this.container.querySelector('[data-popup-resize-handle]');
            this.closeButtons = Array.from(this.container.querySelectorAll('[data-popup-close]'));

            // Verify we have the critical elements
            if (!this.panel || !this.handle || !this.content) {
              console.warn(`[Popup:${this.id}] Missing required elements`);
              return false;
            }

            // Create bound handler functions
            // This step is necessary so we can later remove these exact same function references
            this.createHandlers();

            // Attach all event listeners to DOM elements
            this.attachListeners();

            // Restore saved state from sessionStorage (position, size, scroll, open/closed)
            this.restore();

            this.isInitialized = true;
            console.log(`[Popup:${this.id}] Initialized successfully`);
            return true;
          }

          // ====================================================================================
          // Cleanup
          // ====================================================================================
          // Removes all event listeners and resets initialization state.
          // Called before re-initialization after LiveView navigation, or when destroying popup.
          //
          // NOTE: Does NOT clear saved state from sessionStorage - that persists across cleanup.
          // ====================================================================================
          cleanup() {
            console.log(`[Popup:${this.id}] Cleaning up`);
            this.detachListeners();
            this.isInitialized = false;
          }

          // ====================================================================================
          // Event Handler Creation
          // ====================================================================================
          // Creates bound versions of all event handler methods and stores them in this.handlers.
          //
          // WHY THIS IS NECESSARY:
          //   When you do: element.addEventListener('click', this.toggle.bind(this))
          //   Then later:  element.removeEventListener('click', this.toggle.bind(this))
          //   The removeEventListener FAILS because bind() creates a NEW function each time.
          //
          //   Solution: Create bound functions once, store them, and reuse the same references.
          // ====================================================================================
          createHandlers() {
            this.handlers.toggle = () => this.toggle();
            this.handlers.close = () => this.close();
            this.handlers.dragStart = (e) => this.startDrag(e);
            this.handlers.dragMove = (e) => this.handleDragMove(e);
            this.handlers.dragEnd = (e) => this.endDrag(e);
            this.handlers.resizeStart = (e) => this.startResize(e);
            this.handlers.resizeMove = (e) => this.handleResizeMove(e);
            this.handlers.resizeEnd = (e) => this.endResize(e);
            this.handlers.keydown = (e) => this.handleKeydown(e);
            this.handlers.scroll = () => this.saveScrollPosition();
          }

          // ====================================================================================
          // Attach Event Listeners
          // ====================================================================================
          // Attaches all event listeners to DOM elements using the bound handlers.
          // Called during init() after DOM elements have been found.
          //
          // EVENT LISTENERS ATTACHED:
          //   - Toggle button: click -> toggle open/closed
          //   - Close buttons: click -> close popup
          //   - Drag handle: pointerdown -> start dragging
          //   - Resize handle: pointerdown -> start resizing
          //   - Content area: scroll -> save scroll position
          //   - Document: keydown -> handle Escape key (attached when popup opens)
          //
          // NOTE: Drag/resize move/end handlers are attached to window during drag/resize,
          //       not here. This is because we need to track the mouse even outside the popup.
          // ====================================================================================
          attachListeners() {
            // Toggle button - clicking toggles popup open/closed
            this.openButton.addEventListener('click', this.handlers.toggle);

            // Close buttons - any button with data-popup-close closes the popup
            this.closeButtons.forEach(btn => {
              btn.addEventListener('click', this.handlers.close);
            });

            // Drag handle - clicking and dragging moves the popup
            this.handle.addEventListener('pointerdown', this.handlers.dragStart);

            // Resize handle - clicking and dragging resizes the popup
            if (this.resizeHandle) {
              this.resizeHandle.addEventListener('pointerdown', this.handlers.resizeStart);
            }

            // Content scroll - debounced save to sessionStorage
            if (this.content) {
              this.content.addEventListener('scroll', this.handlers.scroll);
            }

            // NOTE: Keyboard listener is attached/detached in open()/close()
            //       This way Escape only works when popup is actually open
          }

          // ====================================================================================
          // Detach Event Listeners
          // ====================================================================================
          // Removes all event listeners from DOM elements.
          // Called during cleanup() before re-initialization or when destroying popup.
          //
          // IMPORTANT: We must remove ALL listeners to prevent memory leaks, especially when
          //            re-initializing after LiveView navigation. Without proper cleanup, each
          //            navigation would add duplicate listeners to the NEW DOM elements while
          //            leaving orphaned listeners on the OLD (now removed) DOM elements.
          // ====================================================================================
          detachListeners() {
            // Remove toggle button listener
            if (this.openButton) {
              this.openButton.removeEventListener('click', this.handlers.toggle);
            }

            // Remove close button listeners
            this.closeButtons.forEach(btn => {
              btn.removeEventListener('click', this.handlers.close);
            });

            // Remove drag handle listener
            if (this.handle) {
              this.handle.removeEventListener('pointerdown', this.handlers.dragStart);
            }

            // Remove resize handle listener
            if (this.resizeHandle) {
              this.resizeHandle.removeEventListener('pointerdown', this.handlers.resizeStart);
            }

            // Remove scroll listener
            if (this.content) {
              this.content.removeEventListener('scroll', this.handlers.scroll);
            }

            // Remove keyboard listener (might be attached if popup was open)
            document.removeEventListener('keydown', this.handlers.keydown);

            // Remove window-level drag/resize listeners (might be attached during drag/resize)
            window.removeEventListener('pointermove', this.handlers.dragMove);
            window.removeEventListener('pointerup', this.handlers.dragEnd);
            window.removeEventListener('pointercancel', this.handlers.dragEnd);
            window.removeEventListener('pointermove', this.handlers.resizeMove);
            window.removeEventListener('pointerup', this.handlers.resizeEnd);
            window.removeEventListener('pointercancel', this.handlers.resizeEnd);
          }

          // ====================================================================================
          // Toggle Open/Closed
          // ====================================================================================
          // Toggles the popup between open and closed states.
          // Called when user clicks the toggle button.
          // ====================================================================================
          toggle() {
            if (this.isOpen) {
              this.close();
            } else {
              this.open();
            }
          }

          // ====================================================================================
          // Open Popup
          // ====================================================================================
          // Opens the popup, resetting it to default size and centered position.
          //
          // BEHAVIOR:
          //   - Clears any previous position/size from dragging/resizing
          //   - Centers the popup horizontally at 20% from top
          //   - Resets scroll position to 0,0
          //   - Updates button text to "Close Popup"
          //   - Attaches keyboard listener for Escape key
          //   - Saves the reset state to sessionStorage
          //
          // WHY RESET: When user manually opens the popup, they expect a fresh start.
          //            Restoring the previous dragged position could be confusing if they
          //            don't remember where they left it.
          // ====================================================================================
          open() {
            console.log(`[Popup:${this.id}] Opening`);

            // Clear any previous inline styles from dragging/resizing
            this.panel.style.removeProperty('left');
            this.panel.style.removeProperty('top');
            this.panel.style.removeProperty('width');
            this.panel.style.removeProperty('height');
            this.panel.style.removeProperty('transform');

            // Calculate centered position
            // Default size is 448x320 (from initial CSS)
            const width = 448;
            const height = 320;

            // Center horizontally: 50% - half width
            // Position vertically: 20% from top
            // Use window dimensions since container is fixed inset-0 (fullscreen)
            const containerWidth = window.innerWidth;
            const containerHeight = window.innerHeight;
            const left = Math.max(0, Math.round((containerWidth - width) / 2));
            const top = Math.max(0, Math.round(containerHeight * 0.2));

            // Apply centered position and default size
            this.panel.style.left = `${left}px`;
            this.panel.style.top = `${top}px`;
            this.panel.style.width = `${width}px`;
            this.panel.style.minHeight = `${height}px`;
            // Clear any fixed height from previous resize
            this.panel.style.removeProperty('height');

            // Show the popup
            this.container.style.display = 'block';
            this.container.setAttribute('aria-hidden', 'false');
            this.openButton.setAttribute('aria-expanded', 'true');
            this.panel.style.opacity = '1';

            // Focus the panel for keyboard accessibility (without scrolling page)
            this.panel.focus({ preventScroll: true });

            // Update button text to show popup is now open
            const buttonText = this.openButton.querySelector('[data-popup-button-text]');
            if (buttonText) {
              buttonText.textContent = 'Close Popup';
            }

            // Reset scroll position to top-left
            // setTimeout ensures this runs after any potential scroll restoration
            if (this.content) {
              setTimeout(() => {
                this.content.scrollTop = 0;
                this.content.scrollLeft = 0;
              }, 0);
            }

            // Attach keyboard listener for Escape key
            document.addEventListener('keydown', this.handlers.keydown);

            this.isOpen = true;

            // Save the reset state to sessionStorage
            // Use minHeight for size so content can expand naturally
            this.save({
              isOpen: true,
              position: { left, top },
              size: { width, minHeight: height },
              scroll: { scrollTop: 0, scrollLeft: 0 }
            });
          }

          // ====================================================================================
          // Close Popup
          // ====================================================================================
          // Closes the popup and updates UI state.
          //
          // BEHAVIOR:
          //   - Hides the popup container
          //   - Updates button text to "Open Popup"
          //   - Removes keyboard listener
          //   - Saves closed state to sessionStorage
          //
          // NOTE: Does NOT clear position/size - those persist for the next time popup opens
          //       via state restoration (unless user manually opens it, which resets them).
          // ====================================================================================
          close() {
            console.log(`[Popup:${this.id}] Closing`);

            // Hide the popup
            this.container.style.display = 'none';
            this.container.setAttribute('aria-hidden', 'true');
            this.openButton.setAttribute('aria-expanded', 'false');

            // Update button text to show popup is now closed
            const buttonText = this.openButton.querySelector('[data-popup-button-text]');
            if (buttonText) {
              buttonText.textContent = 'Open Popup';
            }

            // Remove keyboard listener - no need to listen when closed
            document.removeEventListener('keydown', this.handlers.keydown);

            this.isOpen = false;

            // Save closed state to sessionStorage
            this.save({ isOpen: false });
          }

          // ====================================================================================
          // Handle Keyboard Events
          // ====================================================================================
          // Handles keyboard input when popup is open.
          // Currently only implements Escape key to close popup.
          //
          // Parameters:
          //   e: KeyboardEvent - The keyboard event
          // ====================================================================================
          handleKeydown(e) {
            if (e.key === 'Escape' && this.isOpen) {
              e.preventDefault();
              this.close();
            }
          }

          // ====================================================================================
          // Start Drag Operation
          // ====================================================================================
          // Initiates a drag operation when user presses pointer on drag handle.
          //
          // DRAG MECHANICS:
          //   1. Calculate offset from mouse position to panel's top-left corner
          //   2. Store this offset (dragOffsetX, dragOffsetY)
          //   3. During drag, position = mouse - offset
          //   4. This keeps the panel from "jumping" when drag starts
          //
          // POINTER CAPTURE:
          //   We use setPointerCapture() to ensure we receive all pointer events even if
          //   the mouse moves outside the drag handle. This provides smooth dragging.
          //
          // Parameters:
          //   e: PointerEvent - The pointerdown event
          // ====================================================================================
          startDrag(e) {
            // Only respond to left mouse button (button 0)
            if (e.button !== undefined && e.button !== 0) return;

            console.log(`[Popup:${this.id}] Start drag`);
            e.preventDefault();

            // Get container and panel positions
            const containerRect = this.container.getBoundingClientRect();
            const panelRect = this.panel.getBoundingClientRect();

            // Calculate panel's current position relative to container
            const currentLeft = panelRect.left - containerRect.left;
            const currentTop = panelRect.top - containerRect.top;

            // Apply current position as inline styles (removing any transform)
            this.panel.style.left = `${currentLeft}px`;
            this.panel.style.top = `${currentTop}px`;
            this.panel.style.transform = '';

            // Mark as dragging and store pointer ID for multi-touch handling
            this.isDragging = true;
            this.dragPointerId = e.pointerId;

            // Calculate offset from mouse to panel's top-left corner
            // This is the "grip point" - we maintain this offset during the drag
            const mouseXInContainer = e.clientX - containerRect.left;
            const mouseYInContainer = e.clientY - containerRect.top;
            this.dragOffsetX = mouseXInContainer - currentLeft;
            this.dragOffsetY = mouseYInContainer - currentTop;

            // Capture pointer events to this element for smooth dragging
            if (this.handle.setPointerCapture) {
              try {
                this.handle.setPointerCapture(e.pointerId);
              } catch (_) {
                // setPointerCapture can fail in some edge cases, ignore
              }
            }

            // Attach window-level listeners for move and end events
            // We attach to window, not the handle, so we track mouse even outside handle
            window.addEventListener('pointermove', this.handlers.dragMove);
            window.addEventListener('pointerup', this.handlers.dragEnd);
            window.addEventListener('pointercancel', this.handlers.dragEnd);
          }

          // ====================================================================================
          // Handle Drag Movement
          // ====================================================================================
          // Updates popup position as user moves the pointer during drag.
          //
          // POSITION CALCULATION:
          //   newLeft = mouseX - dragOffsetX
          //   newTop = mouseY - dragOffsetY
          //
          // This maintains the same "grip point" throughout the drag, so the popup doesn't jump.
          //
          // Parameters:
          //   e: PointerEvent - The pointermove event
          // ====================================================================================
          handleDragMove(e) {
            // Ignore if not dragging or if this is a different pointer
            if (!this.isDragging || (this.dragPointerId !== null && e.pointerId !== this.dragPointerId)) {
              return;
            }

            // Calculate mouse position relative to container
            const containerRect = this.container.getBoundingClientRect();
            const mouseXInContainer = e.clientX - containerRect.left;
            const mouseYInContainer = e.clientY - containerRect.top;

            // Calculate new position by subtracting the offset
            const nextLeft = mouseXInContainer - this.dragOffsetX;
            const nextTop = mouseYInContainer - this.dragOffsetY;

            // Apply new position
            this.panel.style.left = `${nextLeft}px`;
            this.panel.style.top = `${nextTop}px`;
          }

          // ====================================================================================
          // End Drag Operation
          // ====================================================================================
          // Finalizes drag operation when user releases pointer.
          //
          // CLEANUP:
          //   - Releases pointer capture
          //   - Removes window-level move/end listeners
          //   - Saves final position to sessionStorage
          //
          // Parameters:
          //   e: PointerEvent - The pointerup or pointercancel event
          // ====================================================================================
          endDrag(e) {
            if (!this.isDragging) return;

            console.log(`[Popup:${this.id}] End drag`);

            // Release pointer capture
            if (this.handle.releasePointerCapture && this.dragPointerId !== null) {
              try {
                this.handle.releasePointerCapture(this.dragPointerId);
              } catch (_) {
                // releasePointerCapture can fail in some edge cases, ignore
              }
            }

            // Remove window-level listeners
            window.removeEventListener('pointermove', this.handlers.dragMove);
            window.removeEventListener('pointerup', this.handlers.dragEnd);
            window.removeEventListener('pointercancel', this.handlers.dragEnd);

            // Clear drag state
            this.isDragging = false;
            this.dragPointerId = null;

            // Save final position to sessionStorage
            const left = parseInt(this.panel.style.left) || 0;
            const top = parseInt(this.panel.style.top) || 0;
            this.save({ position: { left, top } });
          }

          // ====================================================================================
          // Start Resize Operation
          // ====================================================================================
          // Initiates a resize operation when user presses pointer on resize handle.
          //
          // RESIZE MECHANICS:
          //   1. Record starting mouse position and panel size
          //   2. During resize, calculate delta from start position
          //   3. Apply delta to starting size: newWidth = startWidth + deltaX
          //   4. Enforce minimum size constraints
          //
          // Parameters:
          //   e: PointerEvent - The pointerdown event
          // ====================================================================================
          startResize(e) {
            // Only respond to left mouse button and if resize handle exists
            if (!this.resizeHandle || (e.button !== undefined && e.button !== 0)) return;

            console.log(`[Popup:${this.id}] Start resize`);
            e.preventDefault();

            // Get current panel dimensions and position
            const panelRect = this.panel.getBoundingClientRect();
            const containerRect = this.container.getBoundingClientRect();

            // Remove transform and lock position during resize
            this.panel.style.transform = '';
            this.panel.style.left = `${panelRect.left - containerRect.left}px`;
            this.panel.style.top = `${panelRect.top - containerRect.top}px`;

            // Mark as resizing and store starting state
            this.isResizing = true;
            this.resizePointerId = e.pointerId;
            this.resizeStartX = e.clientX;
            this.resizeStartY = e.clientY;
            this.resizeStartWidth = panelRect.width;
            this.resizeStartHeight = panelRect.height;

            // Capture pointer events for smooth resizing
            if (this.resizeHandle.setPointerCapture) {
              try {
                this.resizeHandle.setPointerCapture(e.pointerId);
              } catch (_) {}
            }

            // Attach window-level listeners for move and end events
            window.addEventListener('pointermove', this.handlers.resizeMove);
            window.addEventListener('pointerup', this.handlers.resizeEnd);
            window.addEventListener('pointercancel', this.handlers.resizeEnd);
          }

          // ====================================================================================
          // Handle Resize Movement
          // ====================================================================================
          // Updates popup size as user moves the pointer during resize.
          //
          // SIZE CALCULATION:
          //   deltaX = currentX - startX
          //   deltaY = currentY - startY
          //   newWidth = startWidth + deltaX (minimum 200px)
          //   newHeight = startHeight + deltaY (minimum 150px)
          //
          // Parameters:
          //   e: PointerEvent - The pointermove event
          // ====================================================================================
          handleResizeMove(e) {
            // Ignore if not resizing or if this is a different pointer
            if (!this.isResizing || (this.resizePointerId !== null && e.pointerId !== this.resizePointerId)) {
              return;
            }

            // Calculate how far the mouse has moved from start position
            const deltaX = e.clientX - this.resizeStartX;
            const deltaY = e.clientY - this.resizeStartY;

            // Calculate new dimensions with minimum size constraints
            const newWidth = Math.max(200, this.resizeStartWidth + deltaX);
            const newHeight = Math.max(150, this.resizeStartHeight + deltaY);

            // Apply new size
            this.panel.style.width = `${newWidth}px`;
            this.panel.style.height = `${newHeight}px`;
          }

          // ====================================================================================
          // End Resize Operation
          // ====================================================================================
          // Finalizes resize operation when user releases pointer.
          //
          // CLEANUP:
          //   - Releases pointer capture
          //   - Removes window-level move/end listeners
          //   - Saves final size to sessionStorage
          //
          // Parameters:
          //   e: PointerEvent - The pointerup or pointercancel event
          // ====================================================================================
          endResize(e) {
            if (!this.isResizing) return;

            console.log(`[Popup:${this.id}] End resize`);

            // Release pointer capture
            if (this.resizeHandle && this.resizeHandle.releasePointerCapture && this.resizePointerId !== null) {
              try {
                this.resizeHandle.releasePointerCapture(this.resizePointerId);
              } catch (_) {}
            }

            // Remove window-level listeners
            window.removeEventListener('pointermove', this.handlers.resizeMove);
            window.removeEventListener('pointerup', this.handlers.resizeEnd);
            window.removeEventListener('pointercancel', this.handlers.resizeEnd);

            // Clear resize state
            this.isResizing = false;
            this.resizePointerId = null;

            // Save final size to sessionStorage
            const width = parseInt(this.panel.style.width) || this.panel.offsetWidth;
            const height = parseInt(this.panel.style.height) || this.panel.offsetHeight;
            this.save({ size: { width, height } });
          }

          // ====================================================================================
          // Save Scroll Position (Debounced)
          // ====================================================================================
          // Saves the current scroll position to sessionStorage after a 100ms delay.
          //
          // DEBOUNCING: We don't save on every scroll event (which fires many times per second).
          //             Instead, we wait for scrolling to pause for 100ms before saving.
          //             This reduces writes to sessionStorage and improves performance.
          // ====================================================================================
          saveScrollPosition() {
            // Clear any existing timeout
            if (this._scrollTimeout) {
              clearTimeout(this._scrollTimeout);
            }

            // Set new timeout to save after 100ms of no scrolling
            this._scrollTimeout = setTimeout(() => {
              if (this.content) {
                const scrollState = {
                  scrollTop: this.content.scrollTop || 0,
                  scrollLeft: this.content.scrollLeft || 0
                };
                this.save({ scroll: scrollState });
              }
            }, 100);
          }

          // ====================================================================================
          // Save State to SessionStorage
          // ====================================================================================
          // Saves partial state update to sessionStorage.
          //
          // STORAGE FORMAT:
          //   {
          //     "popup-id-1": { isOpen: true, position: {...}, size: {...}, scroll: {...} },
          //     "popup-id-2": { isOpen: false, position: {...}, size: {...}, scroll: {...} }
          //   }
          //
          // MERGING: This performs a shallow merge - partialState is merged into existing state.
          //          This allows updating just position without affecting size, etc.
          //
          // Parameters:
          //   partialState: object - Partial state update (e.g., { position: { left: 100, top: 50 } })
          // ====================================================================================
          save(partialState) {
            // Get all popup states from sessionStorage
            const allPopups = this.manager.getAllState();

            // Get current state for this popup
            const currentState = allPopups[this.id] || {};

            // Merge partial update into current state
            const newState = { ...currentState, ...partialState };

            // Update the state object
            allPopups[this.id] = newState;

            // Save back to sessionStorage
            try {
              sessionStorage.setItem(STORAGE_KEY, JSON.stringify(allPopups));
            } catch (e) {
              console.warn(`[Popup:${this.id}] Failed to save state:`, e);
            }
          }

          // ====================================================================================
          // Restore State from SessionStorage
          // ====================================================================================
          // Restores popup state from sessionStorage.
          // Called during init() to restore previous position, size, scroll, and open/closed state.
          //
          // STATE RESTORATION ORDER:
          //   1. Position (left, top)
          //   2. Size (width, height)
          //   3. Scroll (scrollTop, scrollLeft) - uses requestAnimationFrame for timing
          //   4. Open/closed state - if open, shows popup and attaches keyboard listener
          //
          // LIVEVIEW INTEGRATION:
          //   This function is called after LiveView navigation to restore popup state.
          //   Using requestAnimationFrame for scroll ensures it runs before browser paint,
          //   preventing visible flicker.
          // ====================================================================================
          restore() {
            // Get saved state for this popup
            const state = this.manager.getState(this.id);

            if (!state) {
              console.log(`[Popup:${this.id}] No saved state to restore`);
              return;
            }

            console.log(`[Popup:${this.id}] Restoring state:`, state);

            // Keep panel hidden while we apply styles
            this.panel.style.opacity = '0';

            // Restore position
            if (state.position) {
              this.panel.style.left = `${state.position.left}px`;
              this.panel.style.top = `${state.position.top}px`;
              // Remove any transform from default CSS to use absolute positioning
              this.panel.style.transform = '';
            }

            // Restore size
            if (state.size) {
              this.panel.style.width = `${state.size.width}px`;

              // Apply height or minHeight depending on what was saved
              if (state.size.height) {
                this.panel.style.height = `${state.size.height}px`;
              } else if (state.size.minHeight) {
                this.panel.style.minHeight = `${state.size.minHeight}px`;
                this.panel.style.removeProperty('height');
              }
            }

            // Restore scroll position
            // requestAnimationFrame ensures this runs before browser paints (prevents flicker)
            if (state.scroll && this.content) {
              requestAnimationFrame(() => {
                this.content.scrollTop = state.scroll.scrollTop || 0;
                this.content.scrollLeft = state.scroll.scrollLeft || 0;
              });
            }

            // Restore open/closed state
            if (state.isOpen) {
              this.container.style.display = 'block';
              this.container.setAttribute('aria-hidden', 'false');
              this.openButton.setAttribute('aria-expanded', 'true');

              // Update button text
              const buttonText = this.openButton.querySelector('[data-popup-button-text]');
              if (buttonText) {
                buttonText.textContent = 'Close Popup';
              }

              // Attach keyboard listener
              document.addEventListener('keydown', this.handlers.keydown);

              this.isOpen = true;

              // Make panel visible after state is restored (prevents flicker)
              requestAnimationFrame(() => {
                this.panel.style.opacity = '1';
              });
            } else {
              // If closed, ensure panel is visible for when it opens
              this.panel.style.opacity = '1';
            }
          }
        }

        // ======================================================================================
        // PopupManager Class
        // ======================================================================================
        // Singleton that manages all popup instances and coordinates global behavior.
        //
        // RESPONSIBILITIES:
        //   - Register and unregister popup instances
        //   - Handle LiveView navigation events
        //   - Coordinate state persistence across all popups
        //   - Provide API for accessing popup states
        //
        // LIVEVIEW INTEGRATION:
        //   - phx:page-loading-start: Save scroll positions before navigation
        //   - phx:page-loading-stop: Re-initialize all popups after navigation
        // ======================================================================================
        class PopupManager {
          // ====================================================================================
          // Constructor
          // ====================================================================================
          // Creates the PopupManager singleton.
          // ====================================================================================
          constructor() {
            // Map of popup ID -> Popup instance
            // This stores all registered popups
            this.popups = new Map();

            // Has the manager been initialized?
            this.isInitialized = false;
          }

          // ====================================================================================
          // Initialize Manager
          // ====================================================================================
          // Sets up the PopupManager and attaches global event listeners.
          // Called once when the library loads.
          //
          // IDEMPOTENCY: Safe to call multiple times - will only initialize once.
          // ====================================================================================
          init() {
            if (this.isInitialized) {
              return;
            }

            console.log('[PopupManager] Initializing');

            // Attach LiveView navigation listeners
            this.attachNavigationListeners();

            this.isInitialized = true;
            console.log('[PopupManager] Initialized');
          }

          // ====================================================================================
          // Attach Navigation Listeners
          // ====================================================================================
          // Attaches global listeners for Phoenix LiveView navigation events.
          //
          // EVENT FLOW:
          //   1. phx:page-loading-start fires -> save all scroll positions
          //   2. LiveView replaces DOM with new content
          //   3. phx:page-loading-stop fires -> re-initialize all popups
          //   4. requestAnimationFrame runs -> restore state before browser paints
          //
          // WHY requestAnimationFrame:
          //   Ensures state restoration happens before the browser paints the frame.
          //   This prevents visible flicker when popups restore their position/size.
          // ====================================================================================
          attachNavigationListeners() {
            // Track whether we're in the middle of a navigation cycle and which stop kinds
            // have already been processed. This prevents double re-initialization when LiveView
            // emits multiple stop events (redirect + initial).
            let navigationInProgress = false;
            let handledStopKinds = new Set();

            // Save scroll positions BEFORE LiveView navigation
            window.addEventListener('phx:page-loading-start', (e) => {
              const kind = e?.detail?.kind || 'unknown';

              // Skip saving scroll when LiveView reports an error
              if (kind === 'error') {
                console.log('[PopupManager] Navigation error detected; skipping scroll save');
                return;
              }

              // Only reset tracking if we're starting a NEW navigation cycle
              // Don't reset if we're already in progress (multiple start events can occur)
              if (!navigationInProgress) {
                navigationInProgress = true;
                handledStopKinds = new Set();
                console.log('[PopupManager] Starting new navigation cycle (kind:', kind + ')');
              } else {
                console.log('[PopupManager] Already in navigation cycle, additional start event (kind:', kind + ')');
              }

              // Save scroll position for all open popups
              this.popups.forEach(popup => {
                if (popup.content && popup.isOpen) {
                  popup.saveScrollPosition();
                }
              });
            });

            // Re-initialize popups AFTER LiveView navigation
            window.addEventListener('phx:page-loading-stop', (e) => {
              const kind = e?.detail?.kind || 'unknown';

              if (!navigationInProgress) {
                console.log('[PopupManager] Ignoring stop event with no active navigation (kind:', kind + ')');
                return;
              }

              if (handledStopKinds.has(kind)) {
                console.log('[PopupManager] Already handled stop event for kind:', kind);
                return;
              }

              handledStopKinds.add(kind);

              // For full redirects, LiveView emits an intermediate stop event with kind "redirect"
              // followed by a second one with kind "initial" once the new view mounts.
              // Defer re-initialization until we receive the follow-up event.
              if (kind === 'redirect') {
                console.log('[PopupManager] Deferring popup re-init until follow-up stop event (kind: redirect)');
                return;
              }

              navigationInProgress = false;
              console.log('[PopupManager] Navigation complete, re-scanning for popups (kind:', kind + ')');

              // Use requestAnimationFrame to restore state before next paint
              // This prevents visible flicker during state restoration
              requestAnimationFrame(() => {
                // Re-scan DOM for all popup markers and register/re-initialize them
                // This handles both existing popups (re-init) and new popups (register)
                if (window.PersistentPopup && window.PersistentPopup.registerAll) {
                  window.PersistentPopup.registerAll();
                }
              });
            });
          }

          // ====================================================================================
          // Register Popup
          // ====================================================================================
          // Registers a new popup instance or re-initializes an existing one.
          //
          // Parameters:
          //   id: string - The unique ID of the popup element
          //
          // IDEMPOTENCY: Safe to call multiple times with the same ID.
          //              If popup already exists, it will be cleaned up and re-initialized.
          // ====================================================================================
          register(id) {
            // If popup already registered, clean up and re-initialize
            if (this.popups.has(id)) {
              console.log(`[PopupManager] Popup ${id} already registered, re-initializing`);
              const popup = this.popups.get(id);
              popup.cleanup();
              popup.init();
              return;
            }

            // Create new popup instance
            console.log(`[PopupManager] Registering popup: ${id}`);
            const popup = new Popup(id, this);
            this.popups.set(id, popup);
            popup.init();
          }

          // ====================================================================================
          // Unregister Popup
          // ====================================================================================
          // Unregisters a popup instance and cleans up its resources.
          //
          // Parameters:
          //   id: string - The unique ID of the popup to unregister
          //
          // USE CASE: Call this when permanently removing a popup from the page.
          // ====================================================================================
          unregister(id) {
            const popup = this.popups.get(id);
            if (popup) {
              console.log(`[PopupManager] Unregistering popup: ${id}`);
              popup.cleanup();
              this.popups.delete(id);
            }
          }

          // ====================================================================================
          // Get All States
          // ====================================================================================
          // Retrieves all popup states from sessionStorage.
          //
          // Returns:
          //   object - Map of popup ID to state object
          //            Example: { "debug-popup": { isOpen: true, position: {...} }, ... }
          //
          // ERROR HANDLING: If sessionStorage read fails, returns empty object.
          // ====================================================================================
          getAllState() {
            try {
              const data = sessionStorage.getItem(STORAGE_KEY);
              return data ? JSON.parse(data) : {};
            } catch (e) {
              console.warn('[PopupManager] Failed to load state:', e);
              return {};
            }
          }

          // ====================================================================================
          // Get State for Specific Popup
          // ====================================================================================
          // Retrieves saved state for a specific popup.
          //
          // Parameters:
          //   id: string - The popup ID
          //
          // Returns:
          //   object|null - State object if found, null if no state saved
          // ====================================================================================
          getState(id) {
            const allState = this.getAllState();
            return allState[id] || null;
          }
        }

        // ======================================================================================
        // Global API Initialization
        // ======================================================================================

        // Create singleton manager instance
        const manager = new PopupManager();
        manager.init();

        // Expose public API on window object
        window.PersistentPopup = {
          // Initialize a popup by ID
          init: (id) => manager.register(id),

          // Destroy a popup by ID
          destroy: (id) => manager.unregister(id),

          // Scan DOM and register all popups marked with data-popup-register
          // Also unregisters any popups that are no longer in the DOM
          registerAll: () => {
            const markers = document.querySelectorAll('[data-popup-register]');
            const currentIds = new Set(Array.from(markers).map(m => m.getAttribute('data-popup-register')));

            // Unregister popups that are no longer in the DOM
            const registeredIds = Array.from(manager.popups.keys());
            registeredIds.forEach(id => {
              if (!currentIds.has(id)) {
                console.log('[PersistentPopup] Unregistering stale popup:', id);
                manager.unregister(id);
              }
            });

            // Pre-apply open state from sessionStorage to prevent flash
            // This ensures the popup stays visible while we re-attach listeners
            currentIds.forEach(id => {
              const state = manager.getState(id);
              if (state && state.isOpen) {
                const container = document.getElementById(id);
                const openButton = document.getElementById(`${id}-button`);

                if (container && openButton) {
                  // Apply open state immediately before registering
                  container.style.display = 'block';
                  container.setAttribute('aria-hidden', 'false');
                  openButton.setAttribute('aria-expanded', 'true');

                  // Update button text
                  const buttonText = openButton.querySelector('[data-popup-button-text]');
                  if (buttonText) {
                    buttonText.textContent = 'Close Popup';
                  }
                }
              }
            });

            // Register/re-initialize popups that are in the DOM
            if (currentIds.size > 0) {
              console.log('[PersistentPopup] Registering', currentIds.size, 'popup(s):', Array.from(currentIds).join(', '));
              currentIds.forEach(id => manager.register(id));
            }
          }
        };

        // Auto-register all popups when DOM is ready
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', () => {
            window.PersistentPopup.registerAll();
          });
        } else {
          // DOM already loaded, register immediately
          window.PersistentPopup.registerAll();
        }

        console.log('[PersistentPopup] Library loaded and ready');

      })();
    </script>
    """
  end
end
