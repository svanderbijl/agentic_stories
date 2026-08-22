defmodule AgenticStoriesWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AgenticStoriesWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col">
      <header class="flex shrink-0 items-center justify-between border-b border-edge/70 px-5 py-3 sm:px-8">
        <.link navigate={~p"/"} class="group flex items-baseline gap-3">
          <span class="font-display text-lg font-semibold tracking-tight text-ink">
            Agentic&nbsp;Stories
          </span>
          <span class="hidden font-mono text-[10px] tracking-[0.22em] text-ink-faint uppercase transition-colors group-hover:text-ember sm:inline">
            a living fiction engine
          </span>
        </.link>
        <.theme_toggle />
      </header>

      <main class="min-h-0 flex-1">
        {render_slot(@inner_block)}
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center gap-0.5 rounded-full border border-edge p-0.5">
      <button
        class="cursor-pointer rounded-full p-1.5 text-ink-faint transition-colors hover:text-ink [[data-theme-source=system]_&]:bg-ember-soft [[data-theme-source=system]_&]:text-ember"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        title="Follow the system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5" />
      </button>

      <button
        class="cursor-pointer rounded-full p-1.5 text-ink-faint transition-colors hover:text-ink [[data-theme-source=user][data-theme=light]_&]:bg-ember-soft [[data-theme-source=user][data-theme=light]_&]:text-ember"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        title="Daylight"
      >
        <.icon name="hero-sun-micro" class="size-3.5" />
      </button>

      <button
        class="cursor-pointer rounded-full p-1.5 text-ink-faint transition-colors hover:text-ink [[data-theme-source=user][data-theme=dark]_&]:bg-ember-soft [[data-theme-source=user][data-theme=dark]_&]:text-ember"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        title="Lamplight"
      >
        <.icon name="hero-moon-micro" class="size-3.5" />
      </button>
    </div>
    """
  end
end
