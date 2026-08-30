defmodule AgenticStories.Repo.Migrations.AddCharacterBoards do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      # Full character-design sheet, composed from the portrait. The binary
      # never rides along on normal queries; fetch with Stories.get_board/1.
      add :board, :binary
      add :board_type, :string
    end

    alter table(:stories) do
      add :player_board, :binary
      add :player_board_type, :string
    end
  end
end
