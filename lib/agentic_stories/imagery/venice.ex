defmodule AgenticStories.Imagery.Venice do
  @moduledoc """
  Venice.ai driver for `AgenticStories.Imagery`: photorealistic, uncensored
  image generation. Plain renders go through `POST /v1/image/generate`
  (base64 JSON response); compositions with character references go through
  `POST /v1/image/multi-edit` (raw image response), which takes up to three
  input images — the same cap `Imagery.compose/2` already enforces.

  `safe_mode` is forced off on BOTH endpoints (Venice's default blurs adult
  output) and the Venice watermark is hidden on the render path. Note the
  edit endpoint takes only the parameters listed in Venice's multi-edit
  reference — it rejects extras, so do not copy `hide_watermark` over.

  Configuration under `config :agentic_stories, AgenticStories.Imagery.Venice`:

    * `:api_key` — set from `VENICE_API_KEY` in `config/runtime.exs`
    * `:model` — defaults to `lustify-v8` (photorealistic, Venice's
      `most_uncensored` trait; `qwen-image` is their `highest_quality`
      alternative)
    * `:params` — extra body parameters for the render, merged under the
      ones this driver sets. Sizing lives here because it is model-specific:
      `%{width: 1024, height: 1024}` for a pixel model, `%{aspect_ratio:
      "16:9"}` for an aspect-ratio model, plus `:resolution` for a
      resolution-tier one. Wrong pair, rejected request — check `/models`
    * `:edit_model` — defaults to `qwen-edit-uncensored` for compositions
    * `:base_url` — defaults to the public API
    * `:plug` — used by the driver tests to route requests to `Req.Test`
  """

  @behaviour AgenticStories.Imagery

  @default_base_url "https://api.venice.ai/api"
  @default_model "lustify-v8"
  @default_edit_model "qwen-edit-uncensored"

  @impl true
  def generate(prompt) do
    config = config()

    # Sizing is NOT universal on this endpoint: pixel models take width and
    # height, aspect-ratio models take aspect_ratio, resolution-tier models
    # take both aspect_ratio and resolution — and a model handed the wrong
    # pair rejects the whole request. So send none of it by default (Venice
    # applies the model's own default) and let :params carry whatever a
    # particular model wants. Check /models before adding any.
    body =
      config
      |> Keyword.get(:params, %{})
      |> Map.merge(%{
        model: Keyword.get(config, :model, @default_model),
        prompt: prompt,
        format: "jpeg",
        safe_mode: false,
        hide_watermark: true
      })

    case Req.post(client(config), url: "/v1/image/generate", json: body) do
      {:ok, %Req.Response{status: 200, body: body}} -> decode(body)
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @impl true
  def compose(prompt, []), do: generate(prompt)

  def compose(prompt, references) when is_list(references) do
    config = config()

    # safe_mode defaults to TRUE on this endpoint (unlike /image/generate,
    # where we pass it too) — leaving it out blurs anything Venice reads as
    # adult, which is the whole reason this project is on Venice.
    body = %{
      modelId: Keyword.get(config, :edit_model, @default_edit_model),
      prompt: prompt,
      images: Enum.map(references, &data_uri/1),
      output_format: "jpeg",
      safe_mode: false
    }

    case Req.post(client(config), url: "/v1/image/multi-edit", json: body) do
      {:ok, %Req.Response{status: 200, body: binary} = response} when is_binary(binary) ->
        {:ok, %{binary: binary, content_type: content_type(response)}}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:error, {:unexpected_response, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp data_uri(%{binary: binary, content_type: content_type}) do
    "data:#{content_type};base64," <> Base.encode64(binary)
  end

  defp decode(%{"images" => [b64 | _rest]}) do
    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, %{binary: binary, content_type: "image/jpeg"}}
      :error -> {:error, :invalid_image_payload}
    end
  end

  defp decode(body), do: {:error, {:unexpected_response, body}}

  defp content_type(%Req.Response{} = response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _rest] -> value |> String.split(";") |> hd() |> String.trim()
      [] -> "image/jpeg"
    end
  end

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

  defp config, do: Application.get_env(:agentic_stories, __MODULE__, [])

  defp api_key!(config) do
    Keyword.get(config, :api_key) ||
      raise "VENICE_API_KEY is not set; export it before starting the app " <>
              "(or configure :api_key for #{inspect(__MODULE__)})"
  end
end
