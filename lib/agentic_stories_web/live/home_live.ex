defmodule AgenticStoriesWeb.HomeLive do
  @moduledoc """
  The front page: seed a new story, and the shelf of stories already woven.
  """

  use AgenticStoriesWeb, :live_view

  alias AgenticStories.Engine
  alias AgenticStories.Stories
  alias AgenticStories.Stories.Story

  @example_seeds [
    "A lighthouse keeper finds a door at the bottom of the sea.",
    "The last coffee house on Mars, the night the water ration is cut.",
    "A retired thief is invited to appraise the painting she once stole."
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Stories.subscribe()

    {:ok,
     assign(socket,
       stories: Stories.list_stories(),
       seed: "",
       seed_error: nil,
       example_seeds: @example_seeds,
       page_title: "Agentic Stories"
     )}
  end

  @impl true
  def handle_event("seed", %{"seed" => seed}, socket) do
    case Engine.seed_story(seed) do
      {:ok, story} ->
        {:noreply, push_navigate(socket, to: ~p"/stories/#{story}")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket,
           seed: seed,
           seed_error: "Give the Weaver at least a few words to work with."
         )}
    end
  end

  def handle_event("use_example", %{"seed" => seed}, socket) do
    {:noreply, assign(socket, seed: seed, seed_error: nil)}
  end

  @impl true
  def handle_info({:story_updated, %Story{}}, socket) do
    {:noreply, assign(socket, stories: Stories.list_stories())}
  end

  def handle_info({:story_deleted, %Story{}}, socket) do
    {:noreply, assign(socket, stories: Stories.list_stories())}
  end

  def handle_info(_event, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-full overflow-y-auto">
        <div class="mx-auto max-w-2xl px-5 pt-14 pb-20 sm:px-8 sm:pt-20">
          <section>
            <h1 class="font-display text-[2.6rem] leading-[1.05] font-semibold tracking-tight text-ink sm:text-6xl">
              Stories that <em class="font-light text-ember italic">talk&nbsp;back.</em>
            </h1>
            <p class="mt-5 max-w-lg text-lg leading-relaxed text-ink-soft">
              Plant a seed — a premise, a vibe, half a dream. The Weaver spins it into a
              world, casts its characters, and leaves the next line to you.
            </p>
          </section>

          <section class="mt-10">
            <form id="seed-form" phx-submit="seed">
              <div class={[
                "rounded-2xl border bg-paper-raised shadow-sm transition-all",
                "focus-within:border-ember/50 focus-within:shadow-[0_0_0_3px_var(--as-ember-soft)]",
                (@seed_error && "border-ember/70") || "border-edge"
              ]}>
                <.multiline_input
                  id="seed-input"
                  name="seed"
                  rows="4"
                  value={@seed}
                  placeholder="Once, in a place that doesn't quite exist…"
                  class="block w-full resize-none bg-transparent px-5 pt-4 pb-2 font-serif text-lg leading-relaxed text-ink placeholder:text-ink-faint/70 focus:outline-none"
                />
                <div class="flex items-center justify-between gap-3 px-4 pb-3">
                  <span class="font-mono text-[10px] tracking-wide text-ink-faint/80 select-none">
                    Enter to weave &middot; Shift+Enter for a new line
                  </span>
                  <button
                    type="submit"
                    class="group flex cursor-pointer items-center gap-2 rounded-full bg-ember px-4 py-1.5 font-mono text-[11px] tracking-[0.18em] text-paper uppercase transition hover:brightness-110 active:scale-[0.98]"
                  >
                    Weave this story
                    <.icon
                      name="hero-arrow-right-micro"
                      class="size-3.5 transition-transform group-hover:translate-x-0.5"
                    />
                  </button>
                </div>
              </div>
              <p :if={@seed_error} class="mt-2 pl-1 font-serif text-sm text-ember italic">
                {@seed_error}
              </p>
            </form>

            <div class="mt-4 flex flex-wrap gap-2">
              <button
                :for={example <- @example_seeds}
                type="button"
                phx-click="use_example"
                phx-value-seed={example}
                class="cursor-pointer rounded-full border border-edge px-3 py-1 font-serif text-[13px] text-ink-soft italic transition-colors hover:border-ember/50 hover:text-ember"
              >
                {example}
              </button>
            </div>
          </section>

          <section :if={@stories != []} class="mt-16">
            <div class="flex items-baseline gap-4">
              <h2 class="shrink-0 font-mono text-[11px] tracking-[0.28em] text-ink-faint uppercase">
                The shelf
              </h2>
              <div class="h-px w-full bg-edge/80"></div>
            </div>

            <div class="mt-6 grid gap-3 sm:grid-cols-2">
              <.story_card :for={story <- @stories} story={story} />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :story, Story, required: true

  defp story_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/stories/#{@story}"}
      class="group flex flex-col rounded-xl border border-edge bg-paper-raised p-4 transition-all hover:-translate-y-0.5 hover:border-ember/40 hover:shadow-md"
    >
      <div class="flex items-center justify-between gap-2">
        <.status_mark status={@story.status} />
        <.time_ago id={"story-#{@story.id}-at"} at={@story.updated_at} />
      </div>
      <h3 class="mt-2 font-display text-xl leading-snug font-semibold text-ink transition-colors group-hover:text-ember">
        {@story.title || "Untitled, for now"}
      </h3>
      <p
        :if={@story.tone}
        class="mt-1 font-mono text-[10px] tracking-[0.14em] text-ink-faint lowercase"
      >
        {@story.tone}
      </p>
      <p class="mt-3 line-clamp-2 font-serif text-sm leading-relaxed text-ink-soft italic">
        “{@story.seed}”
      </p>
    </.link>
    """
  end

  attr :status, :atom, required: true

  defp status_mark(%{status: :live} = assigns) do
    ~H"""
    <span class="flex items-center gap-1.5 font-mono text-[10px] tracking-[0.2em] text-ember uppercase">
      <span class="size-1.5 rounded-full bg-ember"></span> open
    </span>
    """
  end

  defp status_mark(%{status: :weaving} = assigns) do
    ~H"""
    <span class="flex items-center gap-1.5 font-mono text-[10px] tracking-[0.2em] text-thread uppercase">
      <span class="size-1.5 animate-pulse rounded-full bg-thread"></span> weaving
    </span>
    """
  end

  defp status_mark(%{status: :finished} = assigns) do
    ~H"""
    <span class="flex items-center gap-1.5 font-mono text-[10px] tracking-[0.2em] text-ink-soft uppercase">
      <span class="size-1.5 rounded-full border border-ink-soft"></span> finished
    </span>
    """
  end

  defp status_mark(%{status: :failed} = assigns) do
    ~H"""
    <span class="flex items-center gap-1.5 font-mono text-[10px] tracking-[0.2em] text-ink-faint uppercase">
      <span class="size-1.5 rounded-full bg-ink-faint"></span> frayed
    </span>
    """
  end
end
