defmodule AgenticStories.Repo.Migrations.AddWitnessing do
  use Ecto.Migration

  def change do
    create table(:locations) do
      add :story_id, references(:stories, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create index(:locations, [:story_id])

    alter table(:stories) do
      add :player_location_id, references(:locations, on_delete: :nilify_all)
    end

    alter table(:characters) do
      add :location_id, references(:locations, on_delete: :nilify_all)
      add :memory, :text
      add :memory_beats, :integer, null: false, default: 0
    end

    alter table(:messages) do
      add :location_id, references(:locations, on_delete: :nilify_all)
      # legacy rows (pre-witnessing) stay visible to the player
      add :witnessed_by_player, :boolean, null: false, default: true
    end

    create index(:messages, [:story_id, :witnessed_by_player, :id])

    create table(:message_witnesses, primary_key: false) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :character_id, references(:characters, on_delete: :delete_all), null: false
    end

    create unique_index(:message_witnesses, [:message_id, :character_id])
    create index(:message_witnesses, [:character_id])
  end
end
