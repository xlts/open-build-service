class CreateSavedReplies < ActiveRecord::Migration[6.0]
  def change
    create_table :saved_replies, id: :integer do |t|
      t.string :name, null: false
      t.text :body, null: false
      t.belongs_to :user, type: :integer, null: false, index: true, foreign_key: true

      t.timestamps
    end
  end
end
