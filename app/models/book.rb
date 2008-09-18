class Book < ActiveRecord::Base
  has_many :reviews, :dependent => :delete_all, :order => "created_on"
  has_many :holder_change_histories, :dependent => :delete_all, :order => "created_on"

  validates_presence_of :title, :author, :publisher, :published_on, :isbn, :pages, :content
  validates_length_of :title, :original_title, :author, :translator, :publisher, :isbn, :intro_url, :maximum => 200
  
  def holder
    holder_id ? User.find(:first, :conditions => "users.id = #{holder_id}") : nil
  end

  def before_save
    
  end

  def after_save

  end

end
