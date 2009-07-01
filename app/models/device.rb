class Device < ActiveRecord::Base
  has_many :reviews, :as => :treasure, :dependent => :delete_all, :order => "created_on"
  has_many :holder_change_histories, :as => :treasure, :dependent => :delete_all, :order => "created_on"

  validates_presence_of :name, :model, :vendor, :manufactured_on, :value, :description, :holder
  validates_length_of :name, :model, :vendor, :intro_url, :maximum => 200
  
  def holder
    holder_id ? User.find(:first, :conditions => "users.id = #{holder_id}") : nil
  end

  def after_save
    last_hch = HolderChangeHistory.find(:first, :conditions => "treasure_id = #{self.id} and treasure_type='Device'", :order => 'created_on desc')
    if !last_hch || (last_hch.holder_id != self.holder_id)
      hch = HolderChangeHistory.new
      hch.treasure = self
      hch.holder_id = self.holder_id
	  hch.updater_id = self.updater_id
      hch.save
	  @hch=HolderChangeHistory.find(:first,:order=>'id desc')	
	  unless last_hch.nil?	  
	    LibMailer.deliver_lib_update(@hch,last_hch.holder_id)
      else
        LibMailer.deliver_lib_new(@hch)
      end	
    end
  end

end
