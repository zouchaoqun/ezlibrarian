class HolderChangeHistory < ActiveRecord::Base
  belongs_to :treasure, :polymorphic => true, :counter_cache => true
  
  validates_presence_of :treasure_id, :holder_id
  
  def holder
    holder_id ? User.find(:first, :conditions => "users.id = #{holder_id}") : nil
  end  
  def updater
    updater_id ? User.find(:first, :conditions => "users.id = #{updater_id}") : nil
  end 
end
