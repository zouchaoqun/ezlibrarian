# ezLibrarian plugin for redMine
# Copyright (C) 2008-2009  Zou Chaoqun
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

class BooksController < ApplicationController
  unloadable

  helper :sort
  include SortHelper
  
  layout 'base'  
  before_filter :find_project, :authorize
  before_filter :find_book, :only => [:show, :edit, :destroy, :show_holder_change_histories]
  
  def index
    sort_init "title", "asc"
    sort_update

    @book_count = Book.count
    @book_pages = Paginator.new self, @book_count, per_page_option, params['page']
    @books = Book.find(:all, :order => sort_clause, 
                       :limit  =>  @book_pages.items_per_page,
                       :offset =>  @book_pages.current.offset)

    render :template => 'books/index.html.erb', :layout => !request.xhr?
  end
  
  def new
    @book = Book.new(params[:book])
    if request.post? && @book.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to :action => 'show', :id => @book, :project_id => @project
    end    
  end

  def edit
    if request.post?
      @book.attributes = params[:book]
      if @book.save
        flash[:notice] = l(:notice_successful_update)
        redirect_to :action => 'show', :id => @book, :project_id => @project
      end      
    end
  rescue ActiveRecord::StaleObjectError
    # Optimistic locking exception
    flash.now[:error] = l(:notice_locking_conflict)    
  end

  def show
    @reviews = @book.reviews
  end

  def destroy
    @book.destroy
    redirect_to :action => 'index', :project_id => @project    
  end

  def add_review
  end

  def show_holder_change_histories
    @hchs = @book.holder_change_histories
    
  end

private
  def find_project
    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
  
  def find_book
    @book = Book.find(params[:id])
    render_404 unless @book
  rescue ActiveRecord::RecordNotFound
    render_404
  end  
end
