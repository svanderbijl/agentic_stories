defmodule AgenticStories.Imagery.GrokImagine do
  @moduledoc """
  xAI (Grok Imagine) driver for `AgenticStories.Imagery`, speaking raw HTTP
  (via Req) against `POST /v1/images/generations`. Images come back base64
  so nothing depends on xAI's short-lived URLs.

  Configuration under `config :agentic_stories, AgenticStories.Imagery.GrokImagine`:

    * `:api_key` — set from `XAI_API_KEY` in `config/runtime.exs`
    * `:model` — defaults to `grok-imagine-image-2.0`
      (per https://docs.x.ai/developers/model-capabilities/imagine)
    * `:base_url` — defaults to the public API
    * `:plug` — used by the driver tests to route requests to `Req.Test`
  """

  @behaviour AgenticStories.Imagery

  @default_base_url "https://api.x.ai"
  @default_model "grok-imagine-image-2.0"

  @impl true
  def generate(prompt) do
    request(%{prompt: prompt})
  end

  @impl true
  def compose(prompt, []), do: generate(prompt)

  def compose(prompt, references) when is_list(references) do
    image =
      case Enum.map(references, &%{type: "image_url", url: data_uri(&1)}) do
        [single] -> single
        several -> several
      end

    request(%{prompt: prompt, image: image})
  end

  defp request(fields) do
    config = Application.get_env(:agentic_stories, __MODULE__, [])

    body =
      Map.merge(fields, %{
        model: Keyword.get(config, :model, @default_model),
        response_format: "b64_json"
      })

    case Req.post(client(config), url: "/v1/images/generations", json: body) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp data_uri(%{binary: binary, content_type: content_type}) do
    "data:#{content_type};base64," <> Base.encode64(binary)
  end

  defp decode(%{"data" => [%{"b64_json" => b64} | _rest]}) do
    case Base.decode64(b64) do
      # xAI serves JPEGs; there is no mime field in the response
      {:ok, binary} -> {:ok, %{binary: binary, content_type: "image/jpeg"}}
      :error -> {:error, :invalid_image_payload}
    end
  end

  defp decode(body), do: {:error, {:unexpected_response, body}}

  defp client(config) do
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
