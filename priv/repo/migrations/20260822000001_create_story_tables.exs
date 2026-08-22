defmodule AgenticStories.Repo.Migrations.CreateStoryTables do
  use Ecto.Migration

  def change do
    create table(:stories) do
      add :title, :string
      add :seed, :text, null: false
      add :premise, :text
      add :arc, :text
      add :tone, :string
      add :style, :text
      add :status, :string, null: false, default: "weaving"
      add :failure_reason, :text

      timestamps(type: :utc_datetime)
    end

    create table(:characters) do
      add :story_id, references(:stories, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :persona, :text, null: false
      add :voice, :text
      add :energy, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:characters, [:story_id])

    create table(:messages) do
      add :story_id, references(:stories, on_delete: :delete_all), null: false
      add :character_id, references(:characters, on_delete: :delete_all)
      add :kind, :string, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:story_id, :id])
    create index(:messages, [:character_id])
  end
end
