defmodule AgenticStoriesWeb.StoryLive do
  @moduledoc """
  A story's page. While the Weaver works it shows the loom; once live it is
  a reading pane of typeset beats with the player's composer beneath, kept
  fresh over PubSub as the cast speaks and acts.
  """

  use AgenticStoriesWeb, :live_view

  alias AgenticStories.Engine
  alias AgenticStories.Engine.Narrator
  alias AgenticStories.Imagery
  alias AgenticStories.LLM.Ledger
  alias AgenticStories.Stories
  alias AgenticStories.Stories.{Character, Location, Message, Story}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    story = Stories.get_story!(id)

    if connected?(socket) do
      Stories.subscribe(story.id)
      Engine.ensure_running(story)
    end

    beats = Stories.player_messages(story.id)

    socket =
      socket
      |> assign_story(story)
      |> assign(
        max_energy: Engine.config(:max_energy),
        thinking: MapSet.new(),
        recap: nil,
        painting: false,
        can_paint?: Imagery.enabled?()
      )
      |> stream(:beats, beats)

    socket = if connected?(socket), do: maybe_start_recap(socket, story, beats), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("send", %{"content" => content}, socket) do
    with %Story{status: :live} = story <- socket.assigns.story,
         {:ok, %Message{}} <- Engine.player_message(story, content) do
      {:noreply, push_event(socket, "composer:clear", %{})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("picture", _params, socket) do
    with %Story{status: :live} = story <- socket.assigns.story do
      Engine.request_plate(story)
    end

    # cleared when the plate lands (or when the story moves on without one)
    {:noreply, assign(socket, painting: true)}
  end

  # Keystrokes hold the floor: while there is a draft in the composer the
  # cast waits instead of talking over the player. Emptying it lets them go.
  def handle_event("typing", %{"content" => content}, socket) do
    with %Story{} = story <- socket.assigns.story do
      if String.trim(content) == "",
        do: Engine.player_stopped_typing(story),
        else: Engine.player_typing(story)
    end

    {:noreply, socket}
  end

  def handle_event("go", %{"id" => id}, socket) do
    with %Story{status: :live} = story <- socket.assigns.story,
         {id, ""} <- Integer.parse(id),
         {:ok, %Story{}} <- Engine.player_move(story, id) do
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("end_story", _params, socket) do
    {:ok, _story} = Engine.end_story(socket.assigns.story)
    {:noreply, socket}
  end

  # navigation happens in the story_deleted broadcast handler — one path
  # for this tab and any other tab reading the same story
  def handle_event("delete_story", _params, socket) do
    {:ok, _story} = Engine.delete_story(socket.assigns.story)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:story_updated, %Story{} = story}, socket) do
    came_alive? = story.status == :live and socket.assigns.story.status == :weaving

    socket = assign_story(socket, story)

    if came_alive? do
      Engine.ensure_running(story)
      {:noreply, stream(socket, :beats, Stories.player_messages(story.id), reset: true)}
    else
      {:noreply, socket}
    end
  end

  # The reading pane holds only what the player was there for; beats from
  # elsewhere in the world stay unseen.
  def handle_info({:message_created, %Message{witnessed_by_player: false}}, socket) do
    {:noreply, socket}
  end

  def handle_info({:message_created, %Message{kind: :illustration} = message}, socket) do
    {:noreply, socket |> assign(painting: false) |> stream_insert(:beats, message)}
  end

  def handle_info({:message_created, %Message{} = message}, socket) do
    {:noreply, stream_insert(socket, :beats, message)}
  end

  def handle_info({:character_updated, %Character{} = character}, socket) do
    characters =
      Enum.map(socket.assigns.characters, fn existing ->
        if existing.id == character.id, do: character, else: existing
      end)

    {:noreply, assign(socket, characters: characters)}
  end

  def handle_info({:character_thinking, character_id, thinking?}, socket) do
    thinking =
      if thinking?,
        do: MapSet.put(socket.assigns.thinking, character_id),
        else: MapSet.delete(socket.assigns.thinking, character_id)

    {:noreply, assign(socket, thinking: thinking)}
  end

  def handle_info({:location_created, %Location{}}, socket) do
    {:noreply, assign(socket, locations: Stories.list_locations(socket.assigns.story.id))}
  end

  def handle_info({:story_deleted, %Story{}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "The story is gone.")
     |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_async(:recap, {:ok, {:ok, recap}}, socket) do
    {:noreply, assign(socket, recap: recap)}
  end

  def handle_async(:recap, _result, socket), do: {:noreply, socket}

  # "Previously…" greets a player who has been away a while.
  defp maybe_start_recap(socket, %Story{status: :live} = story, beats) do
    away_ms =
      case List.last(beats) do
        nil -> 0
        last -> DateTime.diff(DateTime.utc_now(), last.inserted_at, :millisecond)
      end

    if length(beats) >= 8 and away_ms > Engine.config(:recap_after_ms) do
      start_async(socket, :recap, fn -> Narrator.recap(story, beats) end)
    else
      socket
    end
  end

  defp maybe_start_recap(socket, _story, _beats), do: socket

  defp assign_story(socket, %Story{} = story) do
    assign(socket,
      story: story,
      characters: Stories.list_characters(story.id),
      locations: Stories.list_locations(story.id),
      tokens: Ledger.story_totals(story.id),
      page_title: story.title || "Weaving…"
    )
  end

  defp here?(%Character{location_id: where}, %Story{player_location_id: player}) do
    is_nil(where) or is_nil(player) or where == player
  end

  defp format_tokens(count) when count >= 1_000, do: "#{Float.round(count / 1_000, 1)}k"
  defp format_tokens(count), do: "#{count}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.loom :if={@story.status == :weaving} story={@story} />
      <.frayed :if={@story.status == :failed} story={@story} />
      <.scene
        :if={@story.status in [:live, :finished]}
        story={@story}
        characters={@characters}
        locations={@locations}
        max_energy={@max_energy}
        streams={@streams}
        thinking={@thinking}
        recap={@recap}
        tokens={@tokens}
        painting={@painting}
        can_paint?={@can_paint?}
      />
    </Layouts.app>
    """
  end

  attr :story, Story, required: true
  attr :characters, :list, required: true
  attr :locations, :list, required: true
  attr :max_energy, :integer, required: true
  attr :streams, :any, required: true
  attr :thinking, :any, required: true
  attr :recap, :string, default: nil
  attr :tokens, :map, default: nil
  attr :painting, :boolean, default: false
  attr :can_paint?, :boolean, default: false

  defp scene(assigns) do
    ~H"""
    <div class="flex h-full">
      <div class="flex h-full min-w-0 flex-1 flex-col">
        <header class="shrink-0 border-b border-edge/60 px-5 py-4 sm:px-8">
          <div class="mx-auto max-w-2xl">
            <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
              <h1 class="font-display text-2xl font-semibold tracking-tight text-ink">
                {@story.title}
              </h1>
              <span class="flex items-baseline gap-4">
                <p class="font-mono text-[10px] tracking-[0.2em] text-ink-faint lowercase">
                  {@story.tone}
                </p>
                <.link
                  href={~p"/stories/#{@story}/read"}
                  class="font-mono text-[10px] tracking-[0.2em] text-ink-faint uppercase transition-colors hover:text-ember"
                  title="Read as a book"
                >
                  read
                </.link>
              </span>
            </div>
            <details class="mt-2 lg:hidden">
              <summary class="flex cursor-pointer list-none items-center gap-3 [&::-webkit-details-marker]:hidden">
                <span class="flex flex-wrap gap-x-4 gap-y-1">
                  <.cast_chip
                    :for={character <- @characters}
                    character={character}
                    here={here?(character, @story)}
                    thinking={MapSet.member?(@thinking, character.id)}
                    max_energy={@max_energy}
                  />
                </span>
                <.icon name="hero-chevron-down-micro" class="size-3 text-ink-faint" />
              </summary>
              <div class="mt-3 grid gap-2 sm:grid-cols-2">
                <.cast_card
                  :for={character <- @characters}
                  character={character}
                  here={here?(character, @story)}
                  thinking={MapSet.member?(@thinking, character.id)}
                  max_energy={@max_energy}
                />
                <.location_card
                  :for={location <- @locations}
                  location={location}
                  here={location.id == @story.player_location_id}
                  movable={@story.status == :live}
                />
                <div class="sm:col-span-2">
                  <.dangers story={@story} />
                </div>
              </div>
            </details>
          </div>
        </header>

        <div id="beats-pane" phx-hook=".AutoScroll" class="min-h-0 flex-1 overflow-y-auto">
          <div :if={@recap} class="mx-auto max-w-2xl px-5 pt-8 sm:px-8">
            <div class="rounded-xl border border-edge bg-paper-raised p-4">
              <p class="font-mono text-[10px] tracking-[0.28em] text-ink-faint uppercase">
                Previously
              </p>
              <p class="mt-2 font-serif text-[15px] leading-relaxed text-ink-soft italic">
                {@recap}
              </p>
            </div>
          </div>
          <div
            id="beats"
            phx-update="stream"
            class="mx-auto max-w-2xl space-y-7 px-5 py-8 sm:px-8"
          >
            <div :for={{dom_id, message} <- @streams.beats} id={dom_id}>
              <.beat message={message} />
            </div>
          </div>
          <div :if={@story.status == :finished} class="mx-auto max-w-2xl px-5 pb-10 sm:px-8">
            <div class="flex items-center gap-4">
              <div class="h-px w-full bg-edge"></div>
              <span class="shrink-0 font-mono text-[10px] tracking-[0.3em] text-ember uppercase">
                The end
              </span>
              <div class="h-px w-full bg-edge"></div>
            </div>
            <p class="mt-4 text-center font-serif text-sm text-ink-soft italic">
              This story has resolved.
              <.link
                href={~p"/stories/#{@story}/read"}
                class="text-ember underline-offset-2 hover:underline"
              >
                Read it as a book
              </.link>
              — or bring
              <.link navigate={~p"/"} class="text-ember underline-offset-2 hover:underline">
                a new seed
              </.link>
              to the Weaver.
            </p>
          </div>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoScroll">
          export default {
            mounted() {
              this.el.scrollTop = this.el.scrollHeight
            },
            beforeUpdate() {
              const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
              this.stick = gap < 160
            },
            updated() {
              if (this.stick) this.el.scrollTo({top: this.el.scrollHeight, behavior: "smooth"})
            },
          }
        </script>

        <footer :if={@story.status == :live} class="shrink-0 px-5 pt-1 pb-4 sm:px-8">
          <form
            id="composer-form"
            phx-submit="send"
            phx-change="typing"
            phx-throttle="1000"
            class="mx-auto max-w-2xl"
          >
            <div class={[
              "rounded-2xl border border-edge bg-paper-raised shadow-sm transition-all",
              "focus-within:border-ember/50 focus-within:shadow-[0_0_0_3px_var(--as-ember-soft)]"
            ]}>
              <.multiline_input
                id="composer-input"
                name="content"
                rows="1"
                placeholder="Say something, or do something…"
                class="block max-h-56 w-full resize-none bg-transparent px-4 pt-3 pb-1 font-serif text-[1.05rem] leading-relaxed text-ink placeholder:text-ink-faint/70 focus:outline-none"
              />
              <div class="flex items-center justify-between gap-3 px-3 pb-2">
                <span class="font-mono text-[10px] tracking-wide text-ink-faint/80 select-none">
                  Enter to send &middot; Shift+Enter for a new line &middot; *asterisks* to act
                </span>
                <div class="flex items-center gap-2">
                  <button
                    :if={@can_paint?}
                    type="button"
                    phx-click="picture"
                    disabled={@painting}
                    title="Read the scene back and paint what is here"
                    class={[
                      "flex cursor-pointer items-center gap-1.5 rounded-full border border-edge px-2.5 py-1",
                      "font-mono text-[10px] tracking-wide text-ink-faint transition",
                      "hover:border-ember/50 hover:text-ink",
                      "disabled:cursor-wait disabled:opacity-60"
                    ]}
                  >
                    <.icon
                      name={if @painting, do: "hero-sparkles-micro", else: "hero-camera-micro"}
                      class={["size-3.5", @painting && "animate-pulse"]}
                    />
                    {if @painting, do: "Painting…", else: "Picture this"}
                  </button>
                  <button
                    type="submit"
                    aria-label="Send"
                    class="grid size-8 cursor-pointer place-items-center rounded-full bg-ember text-paper transition hover:brightness-110 active:scale-95"
                  >
                    <.icon name="hero-arrow-up-micro" class="size-4" />
                  </button>
                </div>
              </div>
            </div>
          </form>
        </footer>
      </div>

      <aside class="hidden w-80 shrink-0 flex-col border-l border-edge/60 lg:flex">
        <div class="min-h-0 flex-1 overflow-y-auto px-5 py-6">
          <div class="flex items-baseline gap-4">
            <h2 class="shrink-0 font-mono text-[11px] tracking-[0.28em] text-ink-faint uppercase">
              The cast
            </h2>
            <div class="h-px w-full bg-edge/80"></div>
          </div>
          <div class="mt-4 space-y-3">
            <.cast_card
              :for={character <- @characters}
              character={character}
              here={here?(character, @story)}
              thinking={MapSet.member?(@thinking, character.id)}
              max_energy={@max_energy}
            />
          </div>

          <div :if={@locations != []} class="mt-8 flex items-baseline gap-4">
            <h2 class="shrink-0 font-mono text-[11px] tracking-[0.28em] text-ink-faint uppercase">
              The world
            </h2>
            <div class="h-px w-full bg-edge/80"></div>
          </div>
          <div :if={@locations != []} class="mt-4 space-y-2">
            <.location_card
              :for={location <- @locations}
              location={location}
              here={location.id == @story.player_location_id}
              movable={@story.status == :live}
            />
          </div>

          <p
            :if={@tokens && @tokens.calls > 0}
            class="mt-8 font-mono text-[9px] tracking-wide text-ink-faint/70"
          >
            this story has thought for {format_tokens(@tokens.input_tokens + @tokens.output_tokens)} tokens
            ({format_tokens(@tokens.cached_tokens)} remembered from cache)
          </p>

          <div class="mt-6 border-t border-edge/60 pt-4">
            <.dangers story={@story} />
          </div>
        </div>
      </aside>
    </div>
    """
  end

  attr :story, Story, required: true

  defp dangers(assigns) do
    ~H"""
    <div class="flex items-center gap-5">
      <button
        :if={@story.status == :live}
        phx-click="end_story"
        data-confirm="End this story? The book closes here, for good."
        class="cursor-pointer font-mono text-[9px] tracking-[0.18em] text-ink-faint uppercase transition-colors hover:text-ink"
      >
        end story
      </button>
      <button
        phx-click="delete_story"
        data-confirm="Delete this story forever? Nothing will remain."
        class="cursor-pointer font-mono text-[9px] tracking-[0.18em] text-ink-faint uppercase transition-colors hover:text-ember"
      >
        delete story
      </button>
    </div>
    """
  end

  attr :story, Story, required: true

  defp loom(assigns) do
    ~H"""
    <div class="grid h-full place-items-center px-6">
      <div class="w-full max-w-md -translate-y-8 text-center">
        <p class="font-mono text-[10px] tracking-[0.3em] text-ink-faint uppercase">
          The Weaver is at work
        </p>
        <blockquote class="mt-6 font-serif text-lg leading-relaxed text-ink-soft italic">
          “{@story.seed}”
        </blockquote>
        <div class="loom-thread mt-10"></div>
        <div class="relative mt-6 h-6 font-serif text-sm text-ink-faint italic">
          <span class="loom-phrase">Listening to the seed…</span>
          <span class="loom-phrase" style="animation-delay: 3s">Finding its tone…</span>
          <span class="loom-phrase" style="animation-delay: 6s">Casting the characters…</span>
          <span class="loom-phrase" style="animation-delay: 9s">Setting the opening scene…</span>
        </div>
        <p class="mt-8 font-mono text-[9px] tracking-[0.2em] text-ink-faint/60 uppercase">
          a good weave takes a minute or two
        </p>
        <div class="mt-6 flex justify-center">
          <.dangers story={@story} />
        </div>
      </div>
    </div>
    """
  end

  attr :story, Story, required: true

  defp frayed(assigns) do
    ~H"""
    <div class="grid h-full place-items-center px-6">
      <div class="w-full max-w-md -translate-y-8 text-center">
        <p class="font-mono text-[10px] tracking-[0.3em] text-ink-faint uppercase">
          The weave came apart
        </p>
        <p :if={@story.failure_reason} class="mt-4 font-serif text-ink-soft italic">
          {@story.failure_reason}
        </p>
        <blockquote class="mt-6 border-l-2 border-edge pl-4 text-left font-serif text-sm leading-relaxed text-ink-faint italic">
          “{@story.seed}”
        </blockquote>
        <.link
          navigate={~p"/"}
          class="mt-8 inline-flex items-center gap-2 font-mono text-[11px] tracking-[0.18em] text-ember uppercase transition hover:brightness-110"
        >
          Bring a new seed <.icon name="hero-arrow-right-micro" class="size-3.5" />
        </.link>
        <div class="mt-6 flex justify-center">
          <.dangers story={@story} />
        </div>
      </div>
    </div>
    """
  end
end
