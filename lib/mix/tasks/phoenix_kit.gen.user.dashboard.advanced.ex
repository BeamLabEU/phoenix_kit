defmodule Mix.Tasks.PhoenixKit.Gen.User.Dashboard.Advanced do
  use Mix.Task
  # Fixme:: Mix task phoenix_kit.gen.user.dashboard.advanced is fragile
  @shortdoc "Generates full advanced dashboard system"

  @impl true
  def run(_args) do
    app = Mix.Project.config()[:app]
    web_module = Macro.camelize("#{app}_web")

    Mix.shell().info("🚀 Generating Advanced Dashboard...")

    ensure_dirs()
    write_hooks()
    patch_app_js()
    install_npm()

    generate_dashboard_live(web_module)
    inject_route(web_module)

    Mix.shell().info("✅ Dashboard system ready")
  end

  # ---------------- DIRS ----------------
  defp ensure_dirs do
    File.mkdir_p!("assets/js/hooks")
    File.mkdir_p!("lib/#{Mix.Project.config()[:app]}_web/live")
    File.mkdir_p!("lib/#{Mix.Project.config()[:app]}/plugin")
  end

  # ---------------- HOOKS ----------------
  defp write_hooks do
    File.write!("assets/js/hooks/grid.js", grid())
    File.write!("assets/js/hooks/context_menu.js", context())
  end

  defp grid do
    """
    import { GridStack } from "gridstack"
    import "gridstack/dist/gridstack.min.css"

    export const Grid = {
      mounted() {
        this.grid = GridStack.init({ float: true, cellHeight: 80 }, this.el)

        this.grid.on("change", () => {
          const items = this.grid.engine.nodes.map(n => ({
            id: n.el.dataset.id,
            x: n.x,
            y: n.y,
            w: n.w,
            h: n.h
          }))
          this.pushEvent("save_grid", { items })
        })
      }
    }
    """
  end

  defp context do
    """
    export const ContextMenu = {
      mounted() {
        this.el.addEventListener("contextmenu", (e) => {
          e.preventDefault()
          const id = this.el.dataset.id
          if (confirm("Remove widget?")) {
            this.pushEvent("remove_widget", { id })
          }
        })
      }
    }
    """
  end

  # ---------------- APP.JS PATCH ----------------
  defp patch_app_js do
    path = "assets/js/app.js"
    content = File.read!(path)

    unless String.contains?(content, "Hooks.Grid") do
      injection = """

      import { Grid } from "./hooks/grid"
      import { ContextMenu } from "./hooks/context_menu"

      let Hooks = window.Hooks || {}
      Hooks.Grid = Grid
      Hooks.ContextMenu = ContextMenu
      """

      File.write!(path, content <> injection)
    end
  end

  # ---------------- NPM ----------------
  defp install_npm do
    File.cd!("assets", fn ->
      unless File.exists?("package.json") do
        System.cmd("npm", ["init", "-y"])
      end

      System.cmd("npm", ["install", "gridstack"])
    end)
  end

  # ---------------- DASHBOARD LIVE ----------------
  defp generate_dashboard_live(web_module) do
    path = "lib/#{Macro.underscore(web_module)}/live/dashboard_live.ex"

    unless File.exists?(path) do
      File.write!(path, dashboard_live_template(web_module))
    end
  end

  defp dashboard_live_template(web_module) do
    """
    defmodule #{web_module}.DashboardLive do
      use #{web_module}, :live_view
      use PhoenixKitWeb, :live_view

       alias PhoenixKit.Widgets.Layout


      def mount(_, _, socket) do
        user = socket.assigns.current_user

        {:ok,
         assign(socket,
           widgets: Layout.widgets_for(user),
           available: Layout.available_widgets(user),
           show_modal: false,
           selected: MapSet.new()
         )}
      end

      def handle_event("remove_widget", %{"id" => id}, socket) do
        Layout.remove_widget(socket.assigns.current_user, id)

        {:noreply,
         assign(socket,
           widgets: Layout.widgets_for(socket.assigns.current_user)
         )}
      end

      def handle_event("save_grid", %{"items" => items}, socket) do
        Layout.save_grid(socket.assigns.current_user, items)
        {:noreply, socket}
      end

      def render(assigns) do
        ~H\"\"\"
       <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="p-6">

    <!-- BUTTON -->
        <div class="flex flex-row-reverse">
          <button
            phx-click="open_widget_modal"
            class="px-3 py-2 bg-blue-600 text-white rounded w-1/3"
          >
            Add Widgets
          </button>
        </div>
        <%= if @show_modal do %>
          <div class="fixed inset-0 bg-black/40 flex items-center justify-center">
            <div class="bg-white w-[600px] p-4 rounded">
              <h2 class="font-bold mb-4">Select Widgets</h2>

              <div class="space-y-2 max-h-[400px] overflow-auto">
                <%= for w <- @available do %>
                  <label class="flex justify-between border p-2 rounded">
                    <span>{w.title}</span>

                    <input
                      type="checkbox"
                      phx-click="toggle_widget"
                      phx-value-id={w.id}
                      checked={MapSet.member?(@selected, w.id)}
                    />
                  </label>
                <% end %>
              </div>

              <div class="flex justify-end gap-2 mt-4">
                <button phx-click="close_widget_modal" class="px-3 py-1 border">
                  Cancel
                </button>

                <button phx-click="add_widgets" class="px-3 py-1 bg-green-600 text-white">
                  OK
                </button>
              </div>
            </div>
          </div>
        <% end %>

    <!-- GRID -->
        <div id="grid_container" class="grid-stack mt-4" phx-hook="Grid">
          <%= for w <- @widgets do %>
            <div
              id={w.id}
              class="grid-stack-item"
              data-id={w.id}
              phx-hook="ContextMenu"
              gs-x={w.layout.x}
              gs-y={w.layout.y}
              gs-w={w.layout.w}
              gs-h={w.layout.h}
              phx-hook="ContextMenu"
            >
              <div class="grid-stack-item-content">
                <.dashboard_card item={w} />
              </div>
            </div>
          <% end %>
        </div>

    <!-- MODAL -->
        <%= if @show_modal do %>
          <div class="fixed inset-0 bg-black/40 flex items-center justify-center">
            <div class="bg-white w-[600px] p-4 rounded">
              <h2 class="font-bold mb-3">Widgets</h2>

              <div class="space-y-2 max-h-[400px] overflow-auto">
                <%= for w <- @available do %>
                  <label class="flex justify-between border p-2 rounded">
                    <span>{w.title}</span>

                    <input
                      type="checkbox"
                      phx-click="toggle"
                      phx-value-id={w.id}
                      checked={w.id in @selected}
                    />
                  </label>
                <% end %>
              </div>

              <div class="flex justify-end gap-2 mt-4">
                <button phx-click="close_modal" class="px-3 py-1 border">Cancel</button>
                <button phx-click="add_selected" class="px-3 py-1 bg-green-600 text-white">
                  Add
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
        \"\"\"
      end
    end
    """
  end

  # ---------------- ROUTER INJECTION ----------------
  defp inject_route(web_module) do
    router_path = "lib/#{Macro.underscore(web_module)}/router.ex"

    content = File.read!(router_path)

    # already injected?
    if String.contains?(content, "DashboardLive") do
      Mix.shell().info("✔ Dashboard route already exists")
      :ok
    else
      Mix.shell().info("🔧 Injecting dashboard into live_session...")

      updated =
        inject_into_live_session(content, web_module)

      File.write!(router_path, updated)
    end
  end

  defp inject_into_live_session(content, web_module) do
    lines = String.split(content, "\n")

    {new_lines, _inserted?} =
      Enum.map_reduce(lines, false, fn line, inserted? ->
        cond do
          # find start of authenticated live_session
          String.contains?(line, "live_session") and
              String.contains?(line, ":phoenix_kit_admin") ->
            {line, :found}

          # first `live` after session start → inject before it
          inserted? == :found and String.trim(line) =~ ~r/^live\s+"/ ->
            {
              [
                "      live \"/dashboard\", #{web_module}.DashboardLive",
                line
              ],
              true
            }

          true ->
            {line, inserted?}
        end
      end)

    new_lines
    |> List.flatten()
    |> Enum.join("\n")
  end
end
