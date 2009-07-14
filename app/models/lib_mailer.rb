# ezFAQ plugin for redMine
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

class LibMailer < Mailer

  def lib_update(hch, last_id)
  #当持有人改变时 发送邮件
    if hch.treasure_type=='Book'
		name=Book.find(hch.treasure_id).title
	elsif hch.treasure_type=='Device'
		name=Device.find(hch.treasure_id).name
	else
	    name="error"
	end
    redmine_headers 'Type' => hch.treasure_type,
                    'Name' => name

    mail_addresses = [ User.find(last_id).mail ]
    mail_addresses << User.find(hch.updater_id).mail
	mail_addresses << User.find(hch.holder_id).mail

    recipients mail_addresses.compact.uniq
	sent_on Time.now

    if hch.treasure_type=='Book'
	  subject "#{l(:text_book_holder_change_subject, :name=>name)}"
	elsif hch.treasure_type=='Device'
	  subject "#{l(:text_device_holder_change_subject, :name=>name)}"
	end

    body   :hch => hch,
         	:last_id => last_id,
			:name => name


    content_type "multipart/alternative"
   part :content_type => "text/plain",
        :body => render_message("lib_update.text.plain.rhtml", :hch => hch)
   part :content_type => "text/html",
        :body => render_message("lib_update.text.html.rhtml", :hch => hch)


  end
#新创建时直接指定持有人时的邮件
  def lib_new(hch)

    if hch.treasure_type=='Book'
		name=Book.find(hch.treasure_id).title
	elsif hch.treasure_type=='Device'
		name=Device.find(hch.treasure_id).name
	else
	    name="error"
	end
    redmine_headers 'Type' => hch.treasure_type,
                    'Name' => name

    mail_addresses = [ User.find(hch.holder_id).mail ]
    mail_addresses << User.find(hch.updater_id).mail

    recipients mail_addresses.compact.uniq
	sent_on Time.now

  if hch.treasure_type=='Book'
	  subject "#{l(:text_book_created_subject,:name=>name)}"
	elsif hch.treasure_type=='Device'
	  subject "#{l(:text_device_created_subject,:name=>name)}"
	end
    body   :hch => hch,
		   :name => name

    content_type "multipart/alternative"
   part :content_type => "text/plain",
        :body => render_message("lib_new.text.plain.rhtml", :hch => hch)
   part :content_type => "text/html",
        :body => render_message("lib_new.text.html.rhtml", :hch => hch)
  end
  #发送对账单功能：向所有设备或图书的持有人发送一封对账单邮件，邮件内容是该用户持有的图书和设备的列表（含设备名称、编号、访问url、入手时间等）
  def send_statement
    bk_list=Book.find_by_sql("SELECT distinct holder_id FROM books ")
    de_list=Device.find_by_sql("SELECT distinct holder_id FROM devices")
    list=Array.new()
    (bk_list+de_list).each{ |bd|
    list << bd.holder_id
    }
    list.uniq!
    list.each{ |l|
    send_statement_each(l)
    }
  end

  def send_statement_each(id)
    user=User.find(id)
    redmine_headers 'Type' => "notice",
                    'Name' => user.name

    mail_addresses = [ user.mail ]
    recipients mail_addresses.compact.uniq
    sent_on Time.now
    subject "#{l(:text_statment_subject)}"
        content_type "multipart/alternative"
   part :content_type => "text/plain",
        :body => render_message("send_statement.text.plain.rhtml", :id => id)
   part :content_type => "text/html",
        :body => render_message("send_statement.text.html.rhtml", :id => id)

  end
end
