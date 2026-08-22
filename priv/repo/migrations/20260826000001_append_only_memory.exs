defmodule AgenticStories.Repo.Migrations.AppendOnlyMemory do
  use Ecto.Migration

  def change do
    create table(:character_memories) do
      add :character_id, references(:characters, on_delete: :delete_all), null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:character_memories, [:character_id])

    # carry existing single-blob memories over as each character's first block
    execute(
      """
      INSERT INTO character_memories (character_id, content, inserted_at)
      SELECT id, memory, NOW() FROM characters WHERE memory IS NOT NULL
      """,
      "SELECT 1"
    )

    alter table(:characters) do
      remove :memory, :text
    end
  end
end
