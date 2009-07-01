# ezLibrarian plugin migration
# Use rake db:migrate_plugins to migrate installed plugins

class AddUpdater < ActiveRecord::Migration
  def self.up
    add_column :devices, :updater_id, :integer, :default => 0, :null => false
    add_column :books, :updater_id, :integer, :default => 0, :null => false
    add_column :holder_change_histories, :updater_id, :integer, :null => true
   end
  
  def self.down
    remove_column :devices, :updater_id, :integer
    remove_column :books, :updater_id, :integer
    remove_column :holder_change_histories, :updater_id, :integer
  end
end
