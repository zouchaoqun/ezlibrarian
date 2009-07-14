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
  description 'This is a simple book shelf and device room management plugin for Redmine'
  version '0.1.5'
  url 'http://ezwork.techcon.thtf.com.cn/projects/ezwork'
  author_url 'mailto:zouchaoqun@gmail.com'
  
  project_module :ezlibrarian do
    permission :view_treasures, {:treasures => [:index, :index_of_devices,:send_statement, :show_statement,:show_book, :show_device, :add_review, :show_holder_change_histories]}, :require => :member
    permission :manage_treasures, {:treasures => [:new_book, :show_statement, :send_statement, :new_device, :edit_book, :edit_device, :destroy_book, :destroy_device]}, :require => :member
  end

  menu :project_menu, :treasures, {:controller => 'treasures', :action => 'index'}, :caption => :label_booty_bay, :param => :project_id
end
