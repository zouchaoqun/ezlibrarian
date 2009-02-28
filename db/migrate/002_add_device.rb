# ezLibrarian plugin migration
# Use rake db:migrate_plugins to migrate installed plugins

class AddDevice < ActiveRecord::Migration
  def self.up
    rename_column :reviews, :book_id, :treasure_id
    add_column :reviews, :treasure_type, :string, :default => 'book'

    rename_column :holder_change_histories, :book_id, :treasure_id
    add_column :holder_change_histories, :treasure_type, :string, :default => 'book'
  
    add_column :books, :value, :decimal, :precision => 8, :scale => 2, :default => 0, :null => false

    create_table :devices, :force => true do |t|
      t.column :name, :string, :null => false
      t.column :model, :string, :null => false
      t.column :vendor, :string, :null => false
      t.column :manufactured_on, :date, :null => false
      t.column :value, :decimal, :precision => 8, :scale => 2, :default => 0, :null => false
      t.column :description, :text, :null => false
      t.column :intro_url, :string
      t.column :holder_id, :integer, :default => 0, :null => false
      t.column :reviews_count, :integer, :default => 0, :null => false
      t.column :holder_change_histories_count, :integer, :default => 0, :null => false
      t.column :created_on, :datetime, :null => false
      t.column :lock_version, :integer, :default => 0
    end

   end
  
  def self.down
    drop_table :devices

    remove_column :books, :value
    
    remove_column :holder_change_histories, :treasure_type
    rename_column :holder_change_histories, :treasure_id, :book_id

    remove_column :reviews, :treasure_type
    rename_column :reviews, :treasure_id, :book_id
  end
end
