defmodule AgenticStories.Repo.Migrations.AddDirectorEra do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      # the hidden want the player never sees
      add :agenda, :text
    end

    alter table(:messages) do
      # chapter illustrations: the plate lives on the beat itself
      add :image, :binary
      add :image_type, :string
    end

    create table(:llm_calls) do
      # plain integer on purpose: telemetry, not domain data
      add :story_id, :integer
      add :purpose, :string, null: false
      add :model, :string
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cached_tokens, :integer, null: false, default: 0

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:llm_calls, [:story_id])
  end
end
