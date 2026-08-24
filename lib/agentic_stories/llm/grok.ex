defmodule AgenticStories.LLM.Grok do
  @moduledoc """
  xAI (Grok) driver for `AgenticStories.LLM`, speaking the OpenAI-compatible
  `POST /v1/chat/completions` (via Req).

  xAI's prompt caching is automatic on stable prefixes, so the block-level
  `cache:` flags in requests are ignored here — the byte-stable transcript
  prefixes the engine builds for explicit caching benefit it all the same.

  Configuration under `config :agentic_stories, AgenticStories.LLM.Grok`:

    * `:api_key` — set from `XAI_API_KEY` in `config/runtime.exs`
    * `:base_url` — defaults to the public API
    * `:plug` — used by the driver tests to route requests to `Req.Test`
  """

  @behaviour AgenticStories.LLM

  alias AgenticStories.LLM.{Request, Response}

  @default_base_url "https://api.x.ai"

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
        system -> [%{role: "system", content: system}]
      end

    %{
      model: request.model,
      max_tokens: request.max_tokens,
      messages: system ++ merge_messages(request.messages)
    }
    |> put_temperature(request.temperature)
  end

  # The engine sends one user message per story beat; on the wire a run of
  # same-role messages folds into ONE turn, flattened in order — a small
  # model handed hundreds of one-line user turns comes apart.
  defp merge_messages(messages) do
    messages
    |> Enum.chunk_by(& &1.role)
    |> Enum.map(fn [%{role: role} | _] = run ->
      %{role: to_string(role), content: Enum.map_join(run, "", &flatten(&1.content))}
    end)
  end

  defp put_temperature(body, nil), do: body
  defp put_temperature(body, temperature), do: Map.put(body, :temperature, temperature)

  defp flatten(text) when is_binary(text), do: text
  defp flatten(blocks) when is_list(blocks), do: Enum.map_join(blocks, "", & &1.text)

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
      raise "XAI_API_KEY is not set; export it before starting the app " <>
              "(or configure :api_key for #{inspect(__MODULE__)})"
  end
end
