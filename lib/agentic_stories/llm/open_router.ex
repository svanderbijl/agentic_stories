defmodule AgenticStories.LLM.OpenRouter do
  @moduledoc """
  OpenRouter driver for `AgenticStories.LLM`, speaking the OpenAI-compatible
  `POST /v1/chat/completions` (via Req). One key, any model — model names use
  OpenRouter slugs (`"x-ai/grok-4.6"`, `"anthropic/claude-opus-5"`, …).

  Block-level `cache:` flags become Anthropic-style `cache_control`
  breakpoints, which OpenRouter forwards to providers that cache explicitly
  and which providers with automatic caching ignore. Cache reads come back
  OpenAI-style in `prompt_tokens_details.cached_tokens` (requested via
  `usage: {include: true}`), which the ledger already reads.

  Configuration under `config :agentic_stories, AgenticStories.LLM.OpenRouter`:

    * `:api_key` — set from `OPENROUTER_API_KEY` in `config/runtime.exs`
    * `:base_url` — defaults to the public API
    * `:plug` — used by the driver tests to route requests to `Req.Test`
  """

  @behaviour AgenticStories.LLM

  alias AgenticStories.LLM.{Request, Response}

  @default_base_url "https://openrouter.ai/api"

  @impl true
  def chat(%Request{} = request) do
    case Req.post(client(), url: "/v1/chat/completions", json: body(request)) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, to_response(body)}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp body(%Request{} = request) do
    system =
      case request.system do
        nil -> []
        system -> [%{role: "system", content: [cached_block(system)]}]
      end

    %{
      model: request.model,
      max_tokens: request.max_tokens,
      messages: system ++ merge_messages(request.messages),
      usage: %{include: true}
    }
    |> put_temperature(request.temperature)
  end

  # The engine sends one user message per story beat; on the wire a run of
  # same-role messages folds into ONE turn with the blocks in order — the
  # downstream model's chat template wraps every message in turn markers,
  # and a small model handed hundreds of one-line user turns comes apart.
  defp merge_messages(messages) do
    messages
    |> Enum.chunk_by(& &1.role)
    |> Enum.map(fn
      [message] ->
        %{role: to_string(message.role), content: content(message.content)}

      [%{role: role} | _] = run ->
        %{role: to_string(role), content: Enum.flat_map(run, &blocks(&1.content))}
    end)
  end

  defp blocks(text) when is_binary(text), do: [%{type: "text", text: text}]
  defp blocks(list) when is_list(list), do: content(list)

  defp put_temperature(body, nil), do: body
  defp put_temperature(body, temperature), do: Map.put(body, :temperature, temperature)

  defp content(text) when is_binary(text), do: text

  defp content(blocks) when is_list(blocks) do
    Enum.map(blocks, fn
      %{text: text, cache: true} -> cached_block(text)
      %{text: text} -> %{type: "text", text: text}
    end)
  end

  defp cached_block(text), do: %{type: "text", text: text, cache_control: %{type: "ephemeral"}}

  defp to_response(body) do
    choice = body |> Map.get("choices", []) |> List.first() || %{}

    %Response{
      text: get_in(choice, ["message", "content"]) || "",
      model: body["model"],
      stop_reason: choice["finish_reason"],
      usage: Map.get(body, "usage", %{})
    }
  end

  defp client do
    config = Application.get_env(:agentic_stories, __MODULE__, [])

    options = [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      auth: {:bearer, api_key!(config)},
      receive_timeout: 120_000
    ]

    options =
      case Keyword.fetch(config, :plug) do
        {:ok, plug} -> Keyword.put(options, :plug, plug)
        :error -> options
      end

    Req.new(options)
  end

  defp api_key!(config) do
    Keyword.get(config, :api_key) ||
      raise "OPENROUTER_API_KEY is not set; export it before starting the app " <>
              "(or configure :api_key for #{inspect(__MODULE__)})"
  end
end
