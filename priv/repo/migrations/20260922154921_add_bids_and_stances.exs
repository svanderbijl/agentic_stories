defmodule AgenticStories.Repo.Migrations.AddBidsAndStances do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # A player line that reaches into someone else. Not yet true — the
      # targeted character's next beat is the outcome.
      add :attempt, :boolean, null: false, default: false
      add :attempt_character_ids, {:array, :integer}, null: false, default: []
    end

    create table(:character_stances) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:character_stances, [:character_id])
  end
end
