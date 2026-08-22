defmodule AgenticStories.LLM.Ledger do
  @moduledoc """
  The cost ledger: records every LLM call's token usage per story and
  purpose, normalizing the different provider usage vocabularies (Anthropic's
  `input_tokens`, OpenAI-compatible `prompt_tokens`, and both cache-read
  shapes). Recording is best-effort — telemetry never crashes a story.
  """

  import Ecto.Query, warn: false

  require Logger

  alias AgenticStories.LLM.{Call, Request, Response}
  alias AgenticStories.Repo

  @spec record(Request.t(), Response.t(), keyword()) :: :ok
  def record(%Request{} = request, %Response{usage: usage}, meta) do
    Repo.insert!(%Call{
      story_id: meta[:story_id],
      purpose: to_string(meta[:purpose] || "unknown"),
      model: request.model,
      input_tokens: usage_value(usage, ["input_tokens", "prompt_tokens"]),
      output_tokens: usage_value(usage, ["output_tokens", "completion_tokens"]),
      cached_tokens: cached_tokens(usage)
    })

    :ok
  rescue
    # bookkeeping must never take a story down with it
    exception ->
      Logger.debug("ledger record failed: #{Exception.message(exception)}")
      :ok
  end

  @doc "Token totals for one story, across all purposes."
  def story_totals(story_id) do
    from(c in Call,
      where: c.story_id == ^story_id,
      select: %{
        calls: count(c.id),
        input_tokens: coalesce(sum(c.input_tokens), 0),
        output_tokens: coalesce(sum(c.output_tokens), 0),
        cached_tokens: coalesce(sum(c.cached_tokens), 0)
      }
    )
    |> Repo.one()
  end

  @doc "Drops a deleted story's rows — no FK ties the ledger to stories."
  def forget(story_id) do
    Repo.delete_all(from c in Call, where: c.story_id == ^story_id)
    :ok
  end

  defp usage_value(usage, keys) when is_map(usage) do
    Enum.find_value(keys, 0, fn key ->
      case usage[key] do
        value when is_integer(value) -> value
        _other -> nil
      end
    end)
  end

  defp usage_value(_usage, _keys), do: 0

  defp cached_tokens(usage) when is_map(usage) do
    case usage["cache_read_input_tokens"] do
      value when is_integer(value) -> value
      _other -> get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    end
  end

  defp cached_tokens(_usage), do: 0
end
