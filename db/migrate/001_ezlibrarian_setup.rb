# ezLibrarian plugin migration
# Use rake db:migrate_plugins to migrate installed plugins

class EzlibrarianSetup < ActiveRecord::Migration
  def self.up
    create_table :books, :force => true do |t|
      t.column :title, :string, :null => false
      t.column :original_title, :string
      t.column :author, :string, :null => false
      t.column :translator, :string
      t.column :publisher, :string, :null => false
      t.column :published_on, :date, :null => false
      t.column :isbn, :string, :null => false
      t.column :pages, :integer, :null => false
      t.column :content, :text, :null => false
      t.column :intro_url, :string
      t.column :holder_id, :integer, :default => 0, :null => false
      t.column :reviews_count, :integer, :default => 0, :null => false
      t.column :holder_change_histories_count, :integer, :default => 0, :null => false
      t.column :created_on, :datetime, :null => false
      t.column :lock_version, :integer, :default => 0
    end

    create_table :reviews, :force => true do |t|
      t.column :author_id, :integer, :default => 0, :null => false
      t.column :book_id, :integer, :default => 0, :null => false
      t.column :review, :text
      t.column :created_on, :datetime, :null => false
    end
    
    create_table :holder_change_histories, :force => true do |t|
      t.column :book_id, :integer, :default => 0, :null => false
      t.column :holder_id, :integer, :default => 0, :null => false
      t.column :created_on, :datetime, :null => false
    end

   end
  
  def self.down
    drop_table :books
    drop_table :reviews
    drop_table :holder_change_history

  end
end
