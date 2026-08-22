defmodule AgenticStories.LLM.Claude do
  @moduledoc """
  Anthropic driver for `AgenticStories.LLM`, speaking raw HTTP (via Req)
  against `POST /v1/messages`.

  Configuration under `config :agentic_stories, AgenticStories.LLM.Claude`:

    * `:api_key` — set from `ANTHROPIC_API_KEY` in `config/runtime.exs`
    * `:base_url` — defaults to the public API
    * `:plug` — used by the driver tests to route requests to `Req.Test`
  """

  @behaviour AgenticStories.LLM

  alias AgenticStories.LLM.{Request, Response}

  @api_version "2023-06-01"
  @default_base_url "https://api.anthropic.com"

  @impl true
  def chat(%Request{} = request) do
    case Req.post(client(), url: "/v1/messages", json: body(request)) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, to_response(body)}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp client do
    config = Application.get_env(:agentic_stories, __MODULE__, [])

    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      headers: [{"x-api-key", api_key!(config)}, {"anthropic-version", @api_version}],
      receive_timeout: 120_000
    ]
    |> put_plug(config)
    |> Req.new()
  end

  defp put_plug(options, config) do
    case Keyword.fetch(config, :plug) do
      {:ok, plug} -> Keyword.put(options, :plug, plug)
      :error -> options
    end
  end

  defp api_key!(config) do
    Keyword.get(config, :api_key) ||
      raise "ANTHROPIC_API_KEY is not set; export it before starting the app " <>
              "(or configure :api_key for #{inspect(__MODULE__)})"
  end

  defp body(%Request{} = request) do
    %{
      model: request.model,
      max_tokens: request.max_tokens,
      messages: Enum.map(request.messages, &%{role: &1.role, content: content(&1.content)})
    }
    |> put_system(request.system)
  end

  defp content(text) when is_binary(text), do: text

  defp content(blocks) when is_list(blocks) do
    Enum.map(blocks, fn
      %{text: text, cache: true} ->
        %{type: "text", text: text, cache_control: %{type: "ephemeral"}}

      %{text: text} ->
        %{type: "text", text: text}
    end)
  end

  defp put_system(body, nil), do: body

  defp put_system(body, system) do
    # cache_control lets Anthropic reuse the stable prefix across a
    # character's ticks (silently skipped below the minimum cacheable size).
    Map.put(body, :system, [%{type: "text", text: system, cache_control: %{type: "ephemeral"}}])
  end

  defp to_response(body) do
    text =
      body
      |> Map.get("content", [])
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    %Response{
      text: text,
      model: body["model"],
      stop_reason: body["stop_reason"],
      usage: Map.get(body, "usage", %{})
    }
  end
end
