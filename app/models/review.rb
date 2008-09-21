class Review < ActiveRecord::Base
  belongs_to :book, :counter_cache => true
  
  validates_presence_of :author_id, :book_id, :review
  
  def author
    author_id ? User.find(:first, :conditions => "users.id = #{author_id}") : nil
  end  
end
