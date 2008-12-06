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

require 'redmine'

Redmine::Plugin.register :redmine_ezlibrarian do
  name 'Redmine ezLibrarian plugin'
  author 'Zou Chaoqun'
  description 'This is a book shelf management plugin for Redmine'
  version '0.0.2'
  
  project_module :ezlibrarian do
    permission :view_books, {:books => [:index, :show, :add_review, :show_holder_change_histories]}, :require => :member
    permission :manage_books, {:books => [:new, :edit, :destroy]}, :require => :member
  end

  menu :project_menu, :books, {:controller => 'books', :action => 'index'}, :caption => :label_library, :param => :project_id  
end
