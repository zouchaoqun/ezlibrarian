#!/usr/bin/env ruby

$:.push(File.expand_path(File.dirname(__FILE__))+"/../../vendor/sunrise/lib")
require File.dirname(__FILE__) + "/../../config/environment"
require 'common'
require 'config_files'
require 'utils'
require 'webrick/httprequest'
require 'webrick/httpresponse'
require 'webrick/config'
require 'instr_utils'
include ImageFunctions

$modulations = {
  "0" => {:str=> "QPSK" ,:qam=>false, :analog=>false, :dcp=>true },
  "1" =>{:str=> "QAM64" ,:qam=>true, :analog=>false, :dcp=>true },
  "2" => {:str => "QAM128" ,:qam=>false, :analog=>false, :dcp=>true },
  "3" => {:str => "QAM256" ,:qam=>true, :analog=>false, :dcp=>true },
  "4" => {:str => "QAM16" ,:qam=>false, :analog=>false, :dcp=>true },
  "5" => {:str => "QAM32" ,:qam=>false, :analog=>false, :dcp=>true },
  "6" => {:str => "QPR" ,:qam=>false, :analog=>false, :dcp=>true },
  "7" => {:str => "FSK" ,:qam=>false, :analog=>false, :dcp=>true },
  "8" => {:str => "BPSK" ,:qam=>false, :analog=>false, :dcp=>true },
  "9" => {:str => "CW" ,:qam=>false, :analog=>false, :dcp=>true },
  "10" => {:str => "VSB_AM" ,:qam=>false, :analog=>false, :dcp=>true },
  "11" => {:str => "FM" ,:qam=>false, :analog=>false, :dcp=>true },
  "12" => {:str => "CDMA" ,:qam=>false, :analog=>false, :dcp=>true },
  "100" => {:str => "NTSC" ,:qam=>false, :analog=>true, :dcp=>false },
  "101" => {:str => "PAL_B" ,:qam=>false, :analog=>true, :dcp=>false },
  "102" => {:str => "PAL_G" ,:qam=>false, :analog=>true, :dcp=>false },
  "103" => {:str => "PAL_I" ,:qam=>false, :analog=>true, :dcp=>false },
  "104" => {:str => "PAL_M" ,:qam=>false, :analog=>true, :dcp=>false },
  "105" => {:str => "PAL_N" ,:qam=>false, :analog=>true, :dcp=>false },
  "106" => {:str => "SECAM_B" ,:qam=>false, :analog=>true, :dcp=>false },
  "107" => {:str => "SECAM_G" ,:qam=>false, :analog=>true, :dcp=>false },
  "108" => {:str => "SECAM_K" ,:qam=>false, :analog=>true, :dcp=>false },
  "200" => {:str => "OFDM" ,:qam=>false, :analog=>true, :dcp=>false }
}


class TestPlanError < StandardError
end
class NoConnectionError < StandardError
end

#Main Routine
$monitor_obj    = nil
instrument_id   = ARGV[0].to_i || raise("Instrument ID required")
cmd_port        = ARGV[1].to_i || raise("Command port required")
$logger=Logger.new(File.join(File.dirname(__FILE__),'../../log/monitor_'+ instrument_id.to_s + '.out'))

class Instrument
  attr_accessor :ip, :session, :prev_mode, :port_list,
    :port_settings, :command_io, :cmd_port, :dlsession,
    :dl_ts , :datalog_flag, :hmid
  CFG_LOC='/tmp/ORIG2'
  DL_PERIOD=60
  DB_CONST=70.0/1024.0
  MAP_COUNT=500
  def initialize(ip,cmd_port, hmid)
    @session=nil
    @ip=ip
    @prev_mode=0
    @port_list=[]
    @port_settings={}
    @build_files= {
      :trace_ref  => {:build=>true, :ext=>'ref'},
      :switch     => {:build=>true, :ext=>'swt'},
      :schedule   => {:build=>true, :ext=>'sch'},
      :signal     => {:build=>true, :ext=>'sig'}
    }
    @hmid=hmid
    @cmd_port=cmd_port
    @current_rptp=0
    @switch_delay=2
    @kill_flag = false
  end
  def set_command_io()
    #Now Let's build Web Based socket to receive commands
    begin
      @command_io = TCPServer::new(@cmd_port.to_i)
      if defined?(Fcntl::FD_CLOEXEC)
        @command_io.fcntl(Fcntl::FD_CLOEXEC,1)
      end
    rescue => ex
      analyzer=Analyzer.find_by_ip(@ip)
      SystemLog.log(ex.message,ex.message + "\n"+ex.backtrace().inspect(),SystemLog::ERROR,analyzer.id)
      $logger.warn("TCPServer Error: #{ex}") if $logger
      $logger.debug ex.inspect()
      $logger.debug ex.backtrace()
      raise NoConnectionError.new()
    end
    @command_io.listen(5)
    $logger.debug "Setting Command IO"
  end
  def configure_instr(analyzer,piddir)
    file_path = piddir + "/hardware.cfg"
    $logger.debug "Building hardware.cfg for #{analyzer.id}"
    ConfigFiles::HWFile.save(analyzer.id, file_path)
    crc32=Common.gen_hsh(file_path)
    result=@session.get_file_crc32("e:\\hardware.cfg")
    svr_crc32=result.msg_object()['crc32'].to_i
    if (crc32!=svr_crc32)
      msg="Hardware.cfg #{crc32} != #{svr_crc32}"
      SystemLog.log(msg,msg,SystemLog::MESSAGE,analyzer.id)
      @session.upload_file(file_path,"e:\\hardware.cfg"){|pos,total|
        update_status("Hardware Config Transfer ", pos,total,analyzer.id)
      }
    end
  end
  def initialize_instr()
    #set_command_io()
    analyzer=Analyzer.find_by_ip(@ip)
    if (analyzer.nil?)
      raise SunriseError.new("Unable to find analyzer with ip #{@ip}")
    end
    cfg_info=ConfigInfo.instance()
    if (cfg_info.get_mode(@ip) != ConfigInfo::MAINT)
      $logger.debug "Initializing #{@ip}"
      @session=InstrumentSession.new(@ip,analyzer.monitoring_port,'10',$logger, @hmid)
      cfg_info=ConfigInfo.instance()
      @prev_mode=cfg_info.get_mode(@ip)
      begin
        msg="Initializing Second Phase#{@ip}"
        SystemLog.log(msg,msg,SystemLog::MESSAGE,analyzer.id)
        @session.initialize_socket()
      rescue Errno::ECONNREFUSED=> ex
        $logger.error("Connection Refused, analyzer may need to be rebooted") if $logger
        $logger.debug "Connection Refused, reboot analyzer?"
        msg="Connection Refused, reboot analyzer#{@ip}"
        analyzer=Analyzer.find_by_ip(@ip)
        SystemLog.log(msg,msg,SystemLog::EXCEPTION,analyzer.id)
        raise
      rescue SunriseError=> ex
        analyzer.update_attributes({:status=>Analyzer::DISCONNECTED, :processing=>nil})
        $logger.debug "Disconnecting analyzer"
        raise
      end
      begin
        @session.login()
      rescue ProtocolError => protocol_err
        error="Reason not known"
        if !@session.nack_error.nil?
          error=@session.nack_error
        end
        $logger.error("unable to login to : #{error}") if $logger
        analyzer.update_attribute(:exception_msg,error)
      rescue => ex
        $logger.error("Maybe we should reboot instrument: #{ex}") if $logger
        large_msg="Maybe we should reboot Instrument #{ex}"
        analyzer=Analyzer.find_by_ip(@ip)
        SystemLog.log("Maybe we should reboot Instrument #{ex}",large_msg,SystemLog::EXCEPTION,analyzer.id)
        raise
      end
      @session.command_io=@command_io
      @session.command_process=lambda { |sock| queue_command(sock)}
      $logger.debug "We have Logged into the instrument"
      analyzer=Analyzer.find_by_ip(@ip)
      SystemLog.log("We have Logged into the instrument",nil,SystemLog::MESSAGE,analyzer.id)
      if !File.exist?(get_piddir())
        Dir.mkdir(get_piddir())
      end
      configure_instr(analyzer,get_piddir())
    end
  end
  def get_piddir
    pid=Process.pid
    analyzer_id=Analyzer.find_by_ip(@ip).id
    return "/tmp/X"+analyzer_id.to_s
  end
  def upload_monitoring_file(file_type,piddir)
    piddir=get_piddir() if piddir.nil?
    Analyzer.connection.reconnect!()
    $logger.debug file_type.to_s
    analyzer_id=Analyzer.find_by_ip(@ip).id
    file_name="monitor."+@build_files[file_type][:ext]
    $logger.debug "Filename => #{file_name} for #{file_type.to_s}"
    file_path=CFG_LOC+"/"+file_name
    if @build_files[file_type][:build]
      monitor_file=MonitorFiles::MonitoringFile::new()
      if (file_type == :trace_ref)
        monitor_file.obj_list=
          MonitorFiles::TraceReferenceFO::build(analyzer_id)
      elsif (file_type == :switch)
        monitor_file.obj_list=
          MonitorFiles::SwitchesFO::build(analyzer_id)
      elsif (file_type == :schedule)
        monitor_file.obj_list=
          MonitorFiles::ScheduleFO::build(analyzer_id)
        if monitor_file.obj_list.nil?
          raise ConfigurationError.new("Problem with Port Schedule. Please Reinitialize")
        end
      elsif (file_type == :signal)
        monitor_file.obj_list=
          MonitorFiles::SignalsFO::build(analyzer_id)
      end
      ext=@build_files[file_type][:ext]
      file_path="#{piddir}/#{file_name}"
      monitor_file.write(file_path)
    end
    crc32=Common.gen_hsh(file_path)
    dest_path="e:\\"+file_name
    result=@session.get_file_crc32(dest_path)
    svr_crc32=result.msg_object()['crc32'].to_i
    if (crc32!=svr_crc32)
      $logger.debug "#{file_path} #{crc32} != #{svr_crc32}"
      begin
        @session.upload_file(file_path,dest_path)
      rescue ProtocolError => err
        if err.message =~ /Block size is zero/
          raise ProtocolError.new("Failure to upload to Analyzer. Hard Disk maybe full.")
        else
          raise
        end
      end
    else
      $logger.debug "#{crc32} == #{svr_crc32}, no need to upload"
    end
  end
  def upload_stored_files(dpath)
    filelist=Dir.entries(dpath)
    filelist.each { |entry|
      if entry.length > 4
        fpath=dpath+"/"+entry
        @session.upload_file(fpath, "e:\\"+entry)
      else
        $logger.debug fpath
      end
    }

  end
  def upload_monitoring_files(piddir, ingress_monitor=true)
    analyzer=Analyzer.find_by_ip(@ip)
    if ingress_monitor
      upload_monitoring_file(:trace_ref,piddir){|pos,total|
        update_status("Monitor.ref transfer", pos, total, analyzer.id)
      }
    end
    upload_monitoring_file(:switch,piddir){|pos,total| update_status("Monitor.swt transfer ", pos,total,analyzer.id)}
    upload_monitoring_file(:schedule,piddir){|pos,total| update_status("Monitor.sch transfer ", pos,total,analyzer.id)}
    upload_monitoring_file(:signal,piddir){|pos,total| update_status("Monitor.sig transfer ", pos,total,analyzer.id)}
    #upload_stored_files("/tmp/demofiles")
    Analyzer.connection.reconnect!()
  end
  def get_settings()
    Analyzer.connection.reconnect!()
    analyzer=Analyzer.find_by_ip(@ip)
    @session.set_mode(0)
    @session.set_mode(13)
    analyzer.switches.find(:all).each { |switch|
      switch.switch_ports.find(:all).each { |switch_port|
        calc_port=switch_port.get_calculated_port
        if !calc_port.nil?
          @port_list.push(calc_port)
          $logger.debug("Getting SOURCE Settings#{calc_port} for port #{switch_port.id}")
          port_settings=@session.get_source_settings(calc_port).msg_obj()
          @port_settings[calc_port.to_s]=port_settings
        end
      }
    }

  end
  def init_monitoring()
    @session.flush_alarms()
    @session.flush_stats()
    @session.flood_config(ConfigParam.get_value(ConfigParam::CYCLE_COUNT), ConfigParam.get_value(ConfigParam::ALARM_FLOOD_THRESHOLD), ConfigParam.get_value(ConfigParam::FLOOD_RESTORE_CYCLE))
    $logger.debug "start monitoring"
    @session.start_monitoring()
    puts "GET MODE #{@session.get_mode()}"
    $logger.debug "do throttle"
    @session.throttle(50,10)
    puts "GET MODE #{@session.get_mode()}"
    $logger.debug "do working mode"
    @session.set_working_mode(0)
    Analyzer.connection.reconnect!()
    analyzer=Analyzer.find_by_ip(@ip)
    analyzer_id=analyzer.id
    puts "HMID=#{@hmid}"
    $logger.debug "HMID=#{@hmid}"
    @dlsession=InstrumentSession.new(@ip,analyzer.datalog_port,'10',$logger,nil,analyzer_id)
    @dlsession.command_io=@command_io
    @dlsession.command_process=lambda { |sock| queue_command(sock)}
    @dlsession.dl_process=lambda{|analyzer_id| flag_datalog(analyzer_id)}
    @dlsession.dir_prefix=get_piddir()
    $logger.debug "Initialize socket"
    @dlsession.initialize_socket(false)
    $logger.debug "login"
    @dlsession.login()
    $logger.debug "get rptp count"
    @dlsession.get_rptp_count()
  end
  def stop_monitoring()
    $logger.debug "Stop Monitoring, including Datalogging"
    $logger.debug("Stop Monitoring")
    $logger.debug("Nullified dl_process")
    #@dlsession.logout()
    #@dlsession.dl_process=nil
    #$logger.debug("Logged out of dlsession")
    @dlsession.close_session()
    $logger.debug("Closed dlsession")
    @session.stop_monitoring()
  end
  def dl_monitor()
    msg_obj=@dlsession.poll_status_monitoring()
    $logger.debug "Poll Datalog"
    while @datalog_flag
      @datalog_flag=false
      $logger.debug "Doing Datalog Transaction"
      @dlsession.datalogging_transaction()
      datalog_filename="#{get_piddir()}/data.logging.buffer"
      if File.file? datalog_filename
        bf=BlockFile::BlockFileParser.new()
        block_list=bf.load(datalog_filename)
        $logger.debug block_list.first.inspect()
        Analyzer.connection.reconnect!()
        analyzer_id=Analyzer.find_by_ip(@ip).id
        dbload(block_list, analyzer_id)
      else
        $logger.debug "#{datalog_filename} is not found"
      end
      $logger.debug "End Doing Datalog Transaction"
    end
    $logger.debug "Poll Datalog Complete"
  end
  def dbload(block_list,analyzer_id)
    dlobj={}
    $logger.debug "Loading for #{analyzer_id}"
    test_count=0
    expected_test_count=0
    analyzer=Analyzer.find(analyzer_id)
    swport=nil
    block_list.each { |block|
      block_type=block[:block_type]
      if block_type == 1
      elsif block_type==2
        #:keys=>[:time_of_meas,:sig_src_nbr,:sig_src_ver,:measure_count,:test_count]
        #We put the time adjustment for the instrument here.
        dlobj[:ts]=block[:time_of_meas]
        dlobj[:rptp]=block[:sig_src_nbr]
        expected_test_count=block[:test_count]
      elsif block_type==3
        $logger.debug "Block Type 3 IGNORED."
      elsif block_type==4
        attenuator=analyzer.attenuator.to_f
        image=block[:trace].collect { |val|
          if val.nil?
            nil
          else
            (val-1023)*DB_CONST+attenuator
          end
        }
        #Map Data
        start_freq=analyzer.start_freq
        stop_freq=analyzer.stop_freq
        mapped_image=ImageFunctions.map_data(start_freq,stop_freq,
          start_freq,stop_freq,image,MAP_COUNT)
        mapped_span=(stop_freq-start_freq)/2.0
        mapped_center_freq=(stop_freq-start_freq)/2.0+start_freq

        if block[:test_number]==0 #MIN
          dlobj[:min_image]=mapped_image
        elsif block[:test_number]==1 #MAX
          dlobj[:max_image]=mapped_image
        elsif block[:test_number]==2 #AVG
          dlobj[:image]=mapped_image
        end
        test_count+=1

        if (expected_test_count == test_count)
          tried_count = 0
          dl=Datalog.new()
          #dl.image=dlobj[:image]
          #dl.min_image=dlobj[:min_image]
          #dl.max_image=dlobj[:max_image]
          #adjust_date_time(dlobj[:ts])
          dl.ts=Time.at(dlobj[:ts] - Time.now.gmt_offset)
          #dl.rptp=dlobj[:rptp]
          dl.ts = adust_dl_time(dl)
          dl.attenuation=attenuator
          #dl.center_frequency=mapped_center_freq
          #dl.span=mapped_span
          dl.start_freq=start_freq
          dl.stop_freq=stop_freq
          analyzer=Analyzer.find(analyzer_id)
          default_site=Site.find(:first)
          site_id=nil
          switch_port_id=analyzer.get_switch_port(dlobj[:rptp])
          $logger.debug("SWITCH PORT: #{dlobj[:rptp]}")
          if (!switch_port_id.nil?)
            swp=SwitchPort.find(switch_port_id)
            if (!swp.nil?)
              site_id=swp.site_id
            end
          end
          dl.site_id=site_id
          dl.noise_floor=Datalog.cal_noise_floor(dlobj[:image],analyzer_id)
          sum=0
          dlobj[:image].each {|val|
            sum+=val
          }
          dl.val=sum/dlobj[:image].length
          dl.max_val=dlobj[:max_image].max
          dl.min_val=dlobj[:min_image].max
          begin
            dl.save()
            $logger.debug "Saving Attempt #{tried_count}"
            save_success=true
          rescue Exception => err
            tried_count += 1
            if (tried_count <3)
              sleep_it 2
              Datalog.connection.reconnect!()
              sleep_it 2
              retry
            else
              dl.destroy
              raise(err.message())
            end
          end
          dl.store_images(dlobj[:min_image],dlobj[:image],dlobj[:max_image])
          test_count=0
        end
      else
      end
    }
  end
  def adust_dl_time(dl)
    $logger.debug("++-Begin to adjust datalog date")
    @realworx_ts=Time.now()
    @ts=@session.get_date_time()
    $logger.debug("----Before adjust datalog time #{dl.ts}")
    @ana_ts=Time.local(@ts['year'],@ts['month'],@ts['day'],@ts['hours'],@ts['minutes'],@ts['seconds'])
    dl.ts+=@realworx_ts - @ana_ts
    return dl.ts
  end
  def monitor()
    $logger.debug "Monitor"
    msg_obj=@session.poll_status_monitoring()
    if (msg_obj.nil?)
      raise(SunriseError.new("Poll Status Monitoring returned nil.This should never happen."))
    end
    stat_count=msg_obj['statistic_count']
    alarm_count=msg_obj['alarm_count']
    $logger.debug "#{ip} Alarm Count #{msg_obj['alarm_count']}, Stat Count#{msg_obj['statistic_count']},"+
      "Integral Count #{msg_obj['integral_count']},Monitoring Status:#{msg_obj['monitoring_status']}"
    if msg_obj['monitoring_status'] == 69
      $logger.debug "ERROR: #{Analyzer.errcode_lookup(msg_obj['error_nbr'])}"
      $logger.debug "This is probably a real error"
      raise "ERROR: #{Analyzer.errcode_lookup(msg_obj['error_nbr'])}"
      #@session.clear_monitoring_error()
    end
    alarmed_ports=[]
    if @dl_ts.nil?
      @dl_ts=Time.now()
      $logger.debug "Initializing time buffer"
      #elsif ((Time.now()>(@dl_ts+DL_PERIOD)))
    else
      Analyzer.connection.reconnect!()
      analyzer_id=Analyzer.find_by_ip(@ip).id
      begin
        dl_monitor()
      rescue
        e=$!
        $logger.debug "Datalogging ERROR #{e.inspect}"
        SystemLog.log("Unable to Get Datalog",
          e.backtrace(),SystemLog::EXCEPTION,analyzer_id)
      end
      @dl_ts=Time.now()

    end
    while ( stat_count > 0 )
      $logger.debug "Getting Stats"
      response=@session.next_stat()
      #TODO do something with the msg_obj
      msg_obj=response.msg_obj()
      stat_count=msg_obj{numb_of_xmit_stastics}.to_i
    end
    if ( alarm_count > 0 )#Should be a WHILE TODO
      $logger.debug "Getting Alarms #{alarm_count}"
      alarm_count-=1
      alarm_response=@session.next_alarm()
      #TODO do something with the msg_obj
      msg_obj=alarm_response.msg_obj()
      $logger.debug "ALARM LEVEL #{msg_obj['alarm_level']}"
      step_nbr=msg_obj['step_nbr']
      schedule=Schedule.find(msg_obj['sn_schedule'].to_i)
      #if (schedule.return_port_schedule[step_nbr].switch_port.purpose != SwitchPort::RETURN_PATH)
      #puts "skipping  Port #{schedule.return_port_schedule[step_nbr].switch_port.id}"
      #next
      #end
      site_id=schedule.return_port_schedule[step_nbr].switch_port.site_id
      $logger.debug msg_obj.inspect()
      if (msg_obj['alarm_level'] < 254)
        rescue_count=0
        begin
          rescue_count += 1
        rescue Mysql::Error => ex
          $logger.debug "Mysql Rescue Count #{rescue_count}"
          if (rescue_count < 3)
            Schedule.connection.reconnect!()
            retry
          end
        rescue Exception => ex
          $logger.debug ex.inspect()
          if (rescue_count < 3)
            Schedule.connection.reconnect!()
            retry
          end
        end
        raise ConfigurationError.new("Cannot find schedule #{msg_obj['sn_schedule']} in database") if (schedule.nil?)
        if (schedule.return_port_schedule[step_nbr].nil?)
          raise ConfigurationError.new("Nothing scheduled for step: #{step_nbr}")
        end
        port_id=schedule.return_port_schedule[step_nbr].switch_port_id
        alarmed_ports.push(port_id)
        $logger.debug "Port ID: #{port_id}"
        port_nbr=schedule.return_port_schedule[step_nbr].switch_port.get_calculated_port()
        site_id=schedule.return_port_schedule[step_nbr].switch_port.site_id
        profile_id=schedule.return_port_schedule[step_nbr].switch_port.profile_id
        if profile_id.nil?
          profile_id=Analyzer.find_by_ip(@ip).profile_id
        end
        site=Site.find(site_id)
        profile=Profile.find(profile_id)
        $logger.debug @port_settings.inspect()
        $logger.debug "PORT NUMBER:#{port_nbr}"
        raise ConfigurationError.new("Cannot find Port  in database")if (port_id.nil?)
        trace=nil
        #Build Alarm Record
        adjust_date_time(msg_obj)
        alarm=Alarm.generate(
          :profile_id             => profile_id,
          :site_id                => site_id,
          :sched_sn_nbr           => msg_obj['sn_schedule'],
          :step_nbr               => msg_obj['step_nbr'],
          :monitoring_mode        => msg_obj['monitoring_mode'],
          :calibration_status     => msg_obj['calibration_status'],
          :event_time             => DateTime.civil( msg_obj['event_year'],
            msg_obj['event_month'],   msg_obj['event_day'],     msg_obj['event_hour'],
            msg_obj['event_minute'],  msg_obj['event_second']),
          :event_time_hundreths   => msg_obj['sec_hundreths'],
          :alarm_level            => msg_obj['alarm_level'],
          #:alarm_deviation        => msg_obj['alarm_deviation'],
          :external_temp          => msg_obj['event_extern_temp'],
          :center_frequency       => @port_settings[port_nbr.to_s]['cen_freq'] ,
          :span                   => @port_settings[port_nbr.to_s]['span'] ,
          :email                  => site.analyzer.email,
          :alarm_type             => Alarm.lvl_at2500_to_rwx(msg_obj['alarm_level'] )
        )
        #Get Trace for Alarm
        packed_image_arr=alarm_response.msg_obj()['trace'].unpack('C*')
        raw_image=Common.parse_image(packed_image_arr)
        db_constant=70.0/1024.0
        tst_val=(raw_image[0]-1023.0).to_f * db_constant
        processed_image=raw_image.collect {|val| (val-1023.0).to_f *
          db_constant +
            port_settings[port_nbr.to_s]['attenuator_value'].to_f }
        alarm.image=processed_image
        alarm.save()
        $logger.debug "ALARM Profile trace AGAIN#{alarm.trace.inspect}"
        $logger.debug("Response-> Msg Type:#{alarm_response.msg_type} Step Nbr:#{msg_obj['step_nbr']} ")
      elsif (msg_obj['alarm_level'] ==255)#FIXME modified alarm level temporarily
        #Clean Alarms
        $logger.debug("Reset with #{msg_obj['alarm_level']} forsite #{site_id} ")
        Alarm.deactivate(site_id)
      else
      end
    end
  end
  def adjust_date_time(msg_obj)
    $logger.debug("Begin to adjust date")
    @realworx_ts=Time.now()
    @ts=@session.get_date_time()
    #$logger.debug("----#{@realworx_ts.hour}")
    @ana_ts=Time.local(@ts['year'],@ts['month'],@ts['day'],@ts['hours'],@ts['minutes'],@ts['seconds'])
    @msg_ts=Time.local(msg_obj['event_year'],msg_obj['event_month'],msg_obj['event_day'],msg_obj['event_hour'],msg_obj['event_minute'],msg_obj['event_second'])
    @msg_ts+=@realworx_ts - @ana_ts
    $logger.debug("msg_ts is #{@msg_ts}-++ event_hour before adjust #{msg_obj['event_hour']}")
    msg_obj['event_year'] =@msg_ts.year
    msg_obj['event_month'] =@msg_ts.month
    msg_obj['event_day'] =@msg_ts.day
    msg_obj['event_hour'] =@msg_ts.hour
    msg_obj['event_minute'] =@msg_ts.min
    msg_obj['event_second'] =@msg_ts.sec
    $logger.debug("-++ event_hour after adjust #{msg_obj['event_hour']}")
  end

  def measure_analog(video_freq,  audio_offset, attenuator=nil, va2sep=nil)
    @session.set_mode(0)# FIXME WORKAROUND Go into SA mode just to change frequencies
    settings={"central_freq"=>video_freq}
    if (!attenuator.nil?)
      settings['attenuator']=attenuator
    end
    @session.set_settings(settings)
    @session.set_mode(4)
    video_response=@session.analog_trigger(1)
    audio_freq=audio_offset + video_freq
    @session.set_mode(0)# FIXME WORKAROUND Go into SA mode just to change frequencies
    @session.set_settings({"central_freq"=>audio_freq})
    @session.set_mode(4)
    audio_response=@session.analog_trigger(1)
    audio_lvl=audio_response["meas_amp"].to_f/10.0
    video_lvl=video_response["meas_amp"].to_f/10.0
    varatio= audio_lvl - video_lvl
    results={"measured_video_freq"=>video_response["meas_freq"],
      "video_lvl"=>video_lvl, "audio_lvl"=>audio_lvl,
      "measured_audio_freq"=>audio_response["meas_freq"],"varatio"=>varatio}
  end
  def measure_dcp(freq,bandwidth, attenuator)
    puts @session.inspect()
    @session.set_mode(3)#Go into DCP mode
    settings={"central_freq"=>freq, "bw"=>bandwidth}
    if (!attenuator.nil?)
      settings['attenuator']=attenuator

    end
    @session.set_settings(settings)
    dcp_response=@session.do_dcp()

    result={:dcp => format("%.4f",dcp_response["meas_result"])}
    #//result=dcp_response

  end

  def measure_qam(freq, modulation_type, annex,symb_rate, polarity)
    @session.set_mode(15)#Go into QAM mode
    avantron_modulation_type=MonitorUtils.sf_to_avantron_QAM_modulation(modulation_type);
    avantron_annex=MonitorUtils.sf_to_avantron_annex(annex);
    settings=@session.set_settings({"central_freq"=>freq, "modulation_type"=>avantron_modulation_type, "standard_type" => avantron_annex, "ideal_symbol_rates"=>symb_rate, "polarity" => polarity})
    $logger.debug("Settings: " + settings.inspect)
	  cou=0
	  begin
      digital_response=@session.digital_trigger(5)
    rescue
	    sleep_it cou.to_i
	    cou+=1
	    if cou<5
	      retry
      end
	  end
    if (digital_response.nil? || digital_response[:symb_lock]!=1 || digital_response[:fwd_err_lock]!=1)
      sleep_it 5
      $logger.debug "Locks are not settled. Try again."
      cou=0
      begin
        digital_response=@session.digital_trigger(5)
      rescue
        sleep_it cou.to_i
        cou+=1
        if cou<5
          retry
        end
      end
      $logger.debug $digital_response.inspect()
      if !digital_response.nil? && (digital_response[:fwd_err_lock] != 1)
        digital_response[:stream_lock] =0
      end
    end
    if (!digital_response.nil? && digital_response[:fwd_err_lock] == 1) #If we Got Locks then lets try to get some really good measurements
      sleep_it 20 # Wait 20 seconds this allows us to get a Good time sample for BER measurements
      #    digital_response=@session.digital_trigger(5) #Do a trigger and accept the response.
      cou=0
      begin
        digital_response=@session.digital_trigger(5)
      rescue
        sleep_it cou.to_i
        cou+=1
        if cou<5
          retry
        end
      end
    end
    $logger.debug("Digital response #{digital_response.inspect}")
    if !digital_response.nil?
      collected_measurements=digital_response
      if (collected_measurements[:symb_lock].to_i==1)
        if ( avantron_modulation_type ==5) #256 QAM
          collected_measurements[:mer_256]=collected_measurements[:mer]
          if collected_measurements[:fwd_err_lock].to_i==1 && collected_measurements[:stream_lock]==1
            collected_measurements[:ber_post_256]=collected_measurements[:ber_post]
            collected_measurements[:ber_pre_256]=collected_measurements[:ber_pre]
          else
            $logger.debug("For 256 QAM fwd err lock or stream lock did not click")
            collected_measurements[:ber_post_256]=nil
            collected_measurements[:ber_pre_256]=nil
            if (collected_measurements.has_key?(:enm))
              collected_measurements.delete(:enm)
            end
            if (collected_measurements.has_key?(:evm))
              collected_measurements.delete(:evm)
            end
          end
        else
          collected_measurements[:mer_64]=collected_measurements[:mer]
          if collected_measurements[:fwd_err_lock].to_i==1 && collected_measurements[:stream_lock]==1
            collected_measurements[:ber_post_64]=collected_measurements[:ber_post]
            collected_measurements[:ber_pre_64]=collected_measurements[:ber_pre]
          else
            $logger.debug("For 64 QAM fwd err lock or stream lock did not click")
            collected_measurements[:ber_post_64]=nil
            collected_measurements[:ber_pre_64]=nil
            if (collected_measurements.has_key?(:enm))
              collected_measurements.delete(:enm)
            end
            if (collected_measurements.has_key?(:evm))
              collected_measurements.delete(:evm)
            end
          end
        end
      else
        if (collected_measurements.has_key?(:enm))
          collected_measurements.delete(:enm)
        end
        if (collected_measurements.has_key?(:evm))
          collected_measurements.delete(:evm)
        end
        $logger.debug("Never got a Symbol Lock")
      end
    else
      $logger.debug("Never got a digital response")
    end
    return collected_measurements
  end
  def round_to(val, decimals)
    if (val.nil?)
      return nil
    end
    if (decimals.nil?)
      decimals=1
    end
    factor=10**decimals
    return (val*factor).round*1.0/factor
  end
  def store_measurements(collected_measurements,step, site_id)
    #TODO
    #Get these values from instrument settings
    ##################################
    calibration_status=1
    external_temp=35
    ##################################
    $logger.debug step.inspect
    freq=step.cfg_channel.freq
    channel_type_nbr= (step.cfg_channel.get_channel_type() == 'Analog' ? 0 : 1)
    channel_id=Channel.get_chan_id(site_id,freq,channel_type_nbr, step.cfg_channel.modulation,step.cfg_channel.channel)
    chan=Channel.find(channel_id)
    $logger.debug "ATTEMPTING TO STORE: "
    $logger.debug "#{collected_measurements.inspect()}"
    channel_type=(collected_measurements.key?(:symb_lock) | collected_measurements.key?(:dcp)) ? "Digital" : "Analog"
    collected_measurements.each_key() { |ky|
      next if collected_measurements[ky].nil?
      meas_rec=Measure.get_id(ky)
      puts "Looking for ${ky} and found ${meas_rec.inspect()}"
      if (!meas_rec.nil?)
        #STEP 1 ADJUST THE VALUES.  MAYBE WE SHOULD DO THIS IN THE MEASURE MODEL
        pre_div_val=collected_measurements[ky].to_f
        if pre_div_val.nil?
          next
        end
        val=pre_div_val/meas_rec.divisor
        val=round_to(val,meas_rec.dec_places.to_i)
        val=meas_rec.sanity_max if !meas_rec.sanity_max.nil? && val > meas_rec.sanity_max
        val=meas_rec.sanity_min if !meas_rec.sanity_min.nil? && val < meas_rec.sanity_min
        analyzer=Analyzer.find_by_ip(@ip)
        #STEP 2 GET THE SITES
        site=Site.find(site_id)
        #STEP 3 SET THE LIMITS
        if (step.do_test(meas_rec.sf_meas_ident)) #PUT Check Flag in
          alarm_occurred=false
          $logger.debug meas_rec.inspect
          (min_major_val,min_minor_val,max_minor_val, max_major_val)=step.get_limits(meas_rec.sf_meas_ident)
          #STEP 4 COMPARE VALUE TO LIMITS
          if (!min_major_val.nil?)
            if  (min_major_val > val.to_f)
              $logger.debug "MINALARM"
              alarm_occurred=true
              DownAlarm.generate(site_id,
                external_temp,chan.id,    meas_rec.id,val,DownAlarm.error(),
                min_major_val,channel_type)
              alarm_occurred=true
            elsif (min_minor_val > val.to_f)
              alarm_occurred=true
              DownAlarm.generate(site_id,
                external_temp,chan.id,    meas_rec.id,val,DownAlarm.warn(),
                min_minor_val ,
                channel_type)
              alarm_occurred=true
            end #min major comparison
          end #is min_major nil
          if !max_major_val.nil?
            if (max_major_val < val.to_f)
              $logger.debug "MAXALARM"
              alarm_occurred=true
              DownAlarm.generate(site_id,
                external_temp,chan.id,    meas_rec.id,val,DownAlarm.error(),
                max_major_val,channel_type)
            elsif (max_minor_val  < val.to_f)
              alarm_occurred=true
              DownAlarm.generate(site_id,
                external_temp,chan.id,    meas_rec.id,val,DownAlarm.warn(),
                max_minor_val,channel_type)
            end #major comparison
          end   #IS max_major nil
          if !alarm_occurred
            $logger.debug "Deactivating Alarm for #{site_id}, #{meas_rec.id},#{chan.id}"
            DownAlarm.deactivate(site_id,meas_rec.id, chan.id, channel_type)
          end #Did alarm occur
        else
          if (meas_rec.measure_name =~ /_lock$/)
            if (val.to_f < 1.0)
              $logger.debug meas_rec.inspect()
              $logger.debug chan.inspect()
              DownAlarm.generate(site_id, external_temp, chan.id,
                meas_rec.id, val, DownAlarm::Major, 1, channel_type)
            end #If lock fail
          end # If measurement a lock
        end #Should I do a test
        $logger.debug "#{ky}(#{meas_rec.id})=>#{val.to_f}"

        # If I am testing measurement or measurement is a lock then store
        if (step.do_test(meas_rec.sf_meas_ident) ||
              (meas_rec.measure_name =~ /_lock$/))
          iter=Measurement.maximum(:iteration,
            :conditions=>["site_id=?",site.id])||0
          iter +=1
          measurement=Measurement.new(:site_id=>site_id,
            :measure_id=>meas_rec.id,
            :channel_id=>channel_id, :value=>val.to_f,
            :dt=>DateTime.now(),:iteration=>iter,
            :min_limit=>min_major_val, :max_limit=>max_major_val)
          measurement.save()
        end
      end
    }
  end
  def shutdown_instrument
    $logger.debug "Closing Session"
    @session.logout()
    @session.close_session()
  end
end #End Class Instrument

class Monitor
  attr_reader :instr_sessions,:prev_mode, :instr_obj, :instr_ip, :state, :cmd_port,:instr_id,:iter,:default_att
  attr_accessor :cmd_queue, :channel_list

  #COMMANDS
  NOMON         = 0 #Connected but No Monitoring
  INGRESS       = 1 #Ingress Monitoring
  DOWNSTREAM    = 2 #Performance monitoring
  RELOAD_CONFIG = 3
  HEARTBEAT     = 4
  MAINT         = 5 #Disconnect from instrument.
  SHUTDOWN      = 6 #Disconnect from instrument.
  FIRMWARE      = 7 #Upgrade firmware on instrument.
  TSWITCH       = 8 #send Switch Test to instrument.
  AUTOCO        = 9 #start Auto Connect check
  #AUTOTEST
  TARGET_TEST_TYPE = 100
  #CHANNEL TYPES
  ANALOG        = 0
  DIGITAL       = 1

  def initialize(id, cmd_port)
    @cmd_queue=[]
    @channel_list=[]
    @tmout=10 #TODO Need to set this in a global param
    @cfg_info=ConfigInfo.instance()
    @instr_id=id
    instr=Analyzer.find(@instr_id)
    @default_att=instr.attenuator
    instr.clear_exceptions()
    instr.clear_progress()
    @instr_ip=instr.ip
    @instr_obj=Instrument.new(@instr_ip, cmd_port,instr.hmid)
    @cmd_port=cmd_port
    @state=Analyzer::DISCONNECTED
  end
  def reload_instrument()
    instr=Analyzer.find(@instr_id)
    instr.clear_exceptions()
    instr.clear_progress()
    @instr_ip=instr.ip
    @instr_obj=Instrument.new(@instr_ip, cmd_port,instr.hmid)
  end
  def initialize_instruments
    systemlog_msg="Initializing Instruments"
    #reload_instrument()
    SystemLog.log(systemlog_msg,SystemLog::MESSAGE,instr_id)
    @instr_obj.initialize_instr()
    instr=Analyzer.find(@instr_id)
    @default_att=instr.attenuator
    systemlog_msg="Initialization of instruments complete."
    SystemLog.log(systemlog_msg,SystemLog::MESSAGE,instr_id)
  end
  def upgrade_firmware
    instr=Analyzer.find(instr_id)
    if instr.nil?
      SystemLog.log("Unable to find instrument",SystemLog::MESSAGE,instr_id)
      return nil
    end
    if instr.firmware_ref.nil?
      SystemLog.log("No Firmware set",SystemLog::MESSAGE,instr_id)
      return nil
    end
    firmware_list=Firmware.find(instr.firmware_ref)
    if !firmware_list.nil? && firmware_list.length ==1
      firmware=firmware_list[0]
      @instr_obj.session.upload_file(firmware.get_full_path(),'/usr/local/bin/at2000/at2500linux.run') {|pos,total| update_status("Firmware transfer ",pos,total,instr_id)}
      SystemLog.log("Rebooting Analyzer ","",SystemLog::PROGRESS,instr_id)
      @instr_obj.session.reboot()
      SystemLog.log("Rebooting Analyzer","",SystemLog::PROGRESS,instr_id)
    else
      $logger.debug("Do not recognize firmware #{instr.firmware_ref}")
      SystemLog.log("Do not recognize firmware #{instr.firmware_ref}",SystemLog::WARNING,instr_id)
      return nil
    end
  end
  def start_ingress()
    instr=Analyzer.find(@instr_id)
    @start_freq=ConfigParam.find(23)
    @stop_freq=ConfigParam.find(24)
    if instr.switches.nil?
      SystemLog.log("Switches are required for Ingress Monitoring","Switches not properly defined for analyzer #{instr.name}.",SystemLog::ERROR,instr_id)
      @state=Analyzer::CONNECTED
    elsif instr[:start_freq].to_i<(@start_freq[:val].to_i*10e5) || instr[:stop_freq].to_i>(@stop_freq[:val].to_i*10e5)
      SystemLog.log("Global start Freq and stop Freq are #{@start_freq[:val].to_i*10e5} hz #{@stop_freq[:val].to_i*10e5} hz","Freq range not properly defined for analyzer #{instr.name}.",SystemLog::ERROR,instr_id)
      SystemLog.log("individual start Freq and stop Freq are #{instr[:start_freq]} hz #{instr[:stop_freq]} hz","Freq range not properly defined for analyzer #{instr.name}.",SystemLog::ERROR,instr_id)
      SystemLog.log("Individual Analyzer's freq range can't larger than global freq range.","Freq range not properly defined for analyzer #{instr.name}.",SystemLog::ERROR,instr_id)
      @state=Analyzer::DISCONNECTED
    else
      #instr.update_attributes({:att_count=> -1})
      #$logger.debug("1111111111")
      @instr_obj.upload_monitoring_files(@instr_obj.get_piddir())
      #$logger.debug("2222222222")
      @instr_obj.get_settings()
      @instr_obj.init_monitoring()
      #$logger.debug("3333333333333")
      @state=Analyzer::INGRESS
    end
  end
  def refresh_live_trace()
    #SOAP UPDATE realview to check analyzer
    retry_count = 0
    begin
      sleep 3
      url="http://localhost:8008/REFRESH_FROM_SOAP_SERVER"
      response=Net::HTTP.get(URI(url))
      $logger.debug("start refress livetrace. #{reponse}")
    rescue
      if (retry_count < 3)
        retry_count+=1
        retry
      else
      end
    end
  end
  def stop_ingress()
    @state=Analyzer::CONNECTED
    instr=Analyzer.find(@instr_id)
    #    instr.update_attributes({:status=>@state, :att_count=> instr.att_count+10})
    @instr_obj.stop_monitoring()

  end
  def addto_queue(cmd)
    if (cmd != HEARTBEAT)
      $logger.debug("Adding Command #{cmd}")
      @cmd_queue.push(cmd)
    end
  end
  def build_port_list(analyzer_id, forward_path=true)
    analyzer=Analyzer.find(analyzer_id)
    schedule=analyzer.schedule.nil? ? nil : analyzer.schedule
    port_list=[]
    if !schedule.nil?
      if forward_path
        port_list=schedule.switch_ports.find(:all, {:order =>:order_nbr}).select {|swp|swp.is_forward_path?}
      else
        port_list=schedule.switch_ports.find(:all, {:order =>:order_nbr}).select {|swp|swp.is_return_path?}
      end
    else
      port_list=[nil]#Return a single port in an array.
    end
    $logger.debug "PORT LIST:"
    $logger.debug port_list.inspect()
    return port_list
  end
  def state_machine_iteration()
    if (@state == Analyzer::INGRESS)
      @instr_obj.monitor()
    elsif (@state == Analyzer::DOWNSTREAM)
      analyzer=Analyzer.find_by_ip(@instr_ip)
      if (analyzer.nil?)
        $logger.debug "Analyzer for #{@instr_ip} not found."
      end
      if @channel_list.length == 0
        @channel_list=analyzer.cfg_channels
      end
      ch=@channel_list.shift
      $logger.debug ("#{@channel_list.length} channels remain")
      ch.cfg_channel_tests.each { |step|
        if (step.switch_port_id.nil?)
          #Do nothing I assume we have a 'no switch' situation here.
          site=analyzer.site()
        else
          #Change the switch to the step's port.
          port=SwitchPort.find(step.switch_port_id)
          @instr_obj.session.set_switch(port.get_calculated_port())
          site=port.get_site()

        end
        modulation=ch.modulation
        freq=ch.freq
        measurements={}
        modulation_reqs=$modulations[modulation.to_s]
        if modulation_reqs[:analog] && step.test_requires(:analog) #TODO Put flag check for video and audio level here
          $logger.debug ch.freq.inspect()
          $logger.debug ch.audio_offset1.inspect()
          tmpmeas=$monitor_obj.instr_obj.measure_analog(ch.freq,  ch.audio_offset1,default_att)
	        $logger.debug tmpmeas.inspect
          if (!tmpmeas.nil?)
            measurements.merge!(tmpmeas)#use tempmeans Hash to merge and cover measurements.
          end
        end
        if modulation_reqs[:dcp] && step.test_requires(:dcp)#If this channel is a digital channel then lets just do the tests
          tmpmeas=$monitor_obj.instr_obj.measure_dcp(ch.freq, ch.bandwidth, default_att)
          measurements.merge!(tmpmeas) #TODO I dont know what the dcp goes int put but in "dcp" measurement
          if modulation_reqs[:qam] && step.test_requires(:qam)   #Put flag check for qam measurments here
            $logger.debug measurements.inspect()
            if (measurements["dcp"].to_f < -15)
              measurements[:stream_lock]=0
              measurements[:symb_lock]=0
              measurements[:fwd_err_lock]=0
            else
              #TODO I think I need to pass bandwidth to measure_qam
              tmpmeas=$monitor_obj.instr_obj.measure_qam(ch.freq, ch.modulation, ch.annex,ch.symbol_rate, ch.polarity)
              if (!tmpmeas.nil? && tmpmeas[:symb_lock]==1 )
                measurements.merge!(tmpmeas)
                ct=Constellation.new(:dt=>Time.now,:site_id=>site.id,:image_data=>tmpmeas[:points],:freq=>ch.freq)
                ct.save()
              end
            end
          end
        end
        $monitor_obj.instr_obj.store_measurements(measurements,step,site.id)
      } #Looping through tests |step|

    else # State is not ingress or downstream
      $logger.debug "In STATE #{@state}"
    end # if @state == ?
  end
  def start_performance()
    @state=Analyzer::DOWNSTREAM
    instr=Analyzer.find(@instr_id)
    if instr.nil?
      raise ConfigurationError.new("Unable to find analyzer #{@instr_id}")
      SystemLog.log("Analyzer not found",
        "Analyzer with id #{@instr_id} not found",
        SystemLog::ERROR,@instr_id)
    end
    if instr.cfg_channels.length ==0
      $logger.debug "FOR CFG CHANNELS NOT found"
      SystemLog.log("Test Plan not configured",
        "Analyzer with id #{@instr_id} has no test plan",
        SystemLog::ERROR,@instr_id)
      @state=Analyzer::CONNECTED
      instr.update_attributes({:status=>@state, :processing=>nil, :exception_msg=>"Test Plan not configured"})
      return
    end

    instr.update_attributes({:status=>@state, :processing=>nil})
    if instr.switches.length>0  && !instr.schedule.nil?
      #transfer monitoring files. Go into monitoring mode and then pop out of monitoring mode
      $logger.debug "SWITCH LIST:"+instr.switches.inspect()
      @instr_obj.upload_monitoring_files(@instr_obj.get_piddir(), false)
      #HACK HACK HACK
      #We do this to get the monitoring files to take affect on the analyzer
      #This will likely fail because no profiles are defined.  But this should get the analyzer reconfigured.
      @instr_obj.session.start_monitoring(:no_exception)
      @instr_obj.session.stop_monitoring(:no_exception)
      #TODO Need to add validation here to see if the number of ports on the switch are OK.
    end
    site=instr.site
  end
  def stop_performance()
    $logger.debug "Stop Performance"
    @state=Analyzer::CONNECTED
    instr=Analyzer.find(@instr_id)
    instr.update_attributes({:status=>@state, :processing=>nil})
    deactivate_analyzer_alarms(instr)
  end
  def conn_instr()
    instr=Analyzer.find(@instr_id)
    deactivate_analyzer_alarms(instr)
    @state=Analyzer::CONNECTED
    $monitor_obj.initialize_instruments()
    if instr.att_count <9 and instr.auto_mode !=3
      auto_connect()
    end
  end
  def disconn_instr()
    $logger.debug "Disconnecting instrument"
    begin
      @instr_obj.shutdown_instrument()
    rescue
    ensure
      @state=Analyzer::DISCONNECTED
      instr=Analyzer.find(@instr_id)
      instr.update_attributes({:status=>@state, :processing=>nil})
      deactivate_analyzer_alarms(instr)
    end
    if instr.att_count <9 and instr.auto_mode !=3
    	auto_connect()
    end
  end
  def auto_connect()
    instr=Analyzer.find(@instr_id)
    if instr.att_count <9
      if instr.auto_mode !=3
        $logger.debug "Start Auto Connect Check."
        SystemLog.log("Auto connect is runing at #{instr.att_count + 1} times","This is the #{instr.att_count + 1} times connect.",SystemLog::RECONNECT,@instr_id)
      end
      if instr.att_count ==2 || instr.att_count ==5
        begin
          $logger.debug "Restart analyzer"
          SystemLog.log("Restart analyzer,while Auto connect is runing at #{instr.att_count + 1} times","This is the #{instr.att_count + 1} times connect.",SystemLog::RECONNECT,@instr_id)
          reset_analyzer()
          #$logger.debug "no Mysql Error"
        rescue
          #$logger.debug "Mysql Error #{ex.message}"
        end
      end
      #$logger.debug "Start Auto Connect 111"
      if instr.auto_mode == 1#auto start ingress
        $logger.debug "Start Auto Connect #{@state}"
        if(@state == Analyzer::CONNECTED)
          $logger.debug("Start Auto Connectcccc")
          unless SwitchPort.count(:all,
              :conditions => ["switch_id in (?) and purpose = ?",
                instr.switches.collect {|sw| sw.id}, SwitchPort::RETURN_PATH]) > 0
            instr.update_attributes({:att_count=> -1,:auto_mode=> 3})
            SystemLog.log("Unable to auto start Ingress Monitoring. You have no Return Path Switch Ports.","Unable to auto start Ingress Monitoring. You have no Return Path Switch Ports.",SystemLog::RECONNECT,instr.id)
            raise(SunriseError.new("Unable to auto start Ingress Monitoring. You have no Return Path Switch Ports."))
            return
          end
          start_ingress()
        elsif(@state == Analyzer::DISCONNECTED)
          conn_instr()
        else
        end
      elsif instr.auto_mode == 2#auto start performance
        if(@state == Analyzer::CONNECTED)
          if Switch.count(:all,:conditions=>["analyzer_id=?",instr.id]) > 0
            unless SwitchPort.count(:all,
                :conditions => ["switch_id in (?) and purpose = ?",
                  instr.switches.collect {|sw| sw.id},  SwitchPort::FORWARD_PATH]) > 0
              instr.update_attributes({:att_count=> -1,:auto_mode=> 3})
              SystemLog.log("Unable to auto start Performance Monitoring. You have no Forward Path Switch Ports.","Unable to auto start Performance Monitoring. You have no Forward Path Switch Ports.",SystemLog::RECONNECT,instr.id)
						  raise(SunriseError.new("Unable to auto start Performance Monitoring. You have no Forward Path Switch Ports."))
              return
            end
          end
          start_performance()
        elsif(@state == Analyzer::DISCONNECTED)
          conn_instr()
          #start_performance()
        else
        end
      else
      end
    else
      instr.update_attributes({:att_count=> -1,:auto_mode=> 3})
      SystemLog.log("Auto connect Mode shut down as auto connect failed.","Auto Connect have already try 9 times. But Failed, then give up Auto Connect.",SystemLog::RECONNECT,instr.id)
    end
  end

  def reset_analyzer()
    #$logger.debug "Start Auto Connect 222"
    anl=Analyzer.find(@instr_id)
    anl.cmd_port=nil
    anl.clear_exceptions()
    anl.clear_progress()
    anl.status=Analyzer::DISCONNECTED
    anl.save
    #flash[:notice]='Please wait 30 seconds before connecting the analyzer so it can finish rebooting.'
    begin
      #$logger.debug "Start Auto Connect 333"
      Avantron::InstrumentUtils.reset(anl.ip)
    rescue Errno::EHOSTUNREACH
      #flash[:notice]='Unable to reboot analyzer. Analyzer must be on network and Mips Based (have USB Port)'
    rescue Timeout::Error
      #flash[:notice]='Unable to reboot analyzer. Analyzer must be on network and Mips Based (have USB Port)'
    end

    if !anl.pid.nil? && (anl.pid.to_i > 0)
      begin
        #$logger.debug "Start Auto Connect gggg"
        #Process.kill("SIGKILL",anl.pid)
        #`kill -s 9 #{anl.pid}`
        @kill_flag = true
        #$logger.debug "Start Auto Connect 555"
      rescue Errno::ESRCH
        #$logger.debug "Start Auto Connect errrr"
      end
      #$logger.debug "Start Auto Connect gffhff"
      #anl.status=Analyzer::PROCESSING
      anl.pid=nil
      anl.save
    end
    #$logger.debug "Start Auto Connect dfff"
  end

  def test_switch()
    SystemLog.log("testswitch","testswitch",SystemLog::MESSAGE,@instr_id)
    instr=Analyzer.find(@instr_id)
	  if(instr.status == Analyzer::CONNECTED)
	    instr.update_attribute(:status,Analyzer::SWITCHING)
      begin
        @count_rptp=@instr_obj.session.get_rptp_count
        if @count_rptp == 1
          raise ("SWITCH TEST FAILED, There is no switch.")
        elsif @count_rptp == 0
          raise ("SWITCH TEST FAILED.")
        end
        1.upto(@count_rptp.to_i){ |port|
          @instr_obj.session.set_switch(port)
          sleep @switch_delay.to_i
          current_rptp=@instr_obj.session.get_rptp_list(false)
          if current_rptp.nil? || current_rptp.first.nil?
            raise ("Unknow Error. CANNOT swtich to next port.")
          end
          instr.update_attribute(:current_nbr,current_rptp.first)
          $logger.debug "newtestswitch: #{current_rptp}"
        }
        instr.update_attribute(:current_nbr,'-99')
        instr.update_attribute(:status,Analyzer::CONNECTED)
      rescue=> ex
        SystemLog.log("UNKNOWN ERROR #{ex.message}",ex.backtrace(),SystemLog::EXCEPTION,@instr_id)
        current_rptp=@instr_obj.session.get_rptp_list(false)
        msg=ex.message+' Error port is: '+(current_rptp.first.nil? ? 'unknown': current_rptp.first.to_s)
        instr.update_attributes({:exception_msg=>msg,:current_nbr=>'-11'})
        $logger.debug "Unknown Error #{ex.message}"
        $logger.debug ex.backtrace()
        disconn_instr()
      end
	  else
	    instr.update_attribute(:current_nbr,'-10')
    end
    sleep_it 19
    instr.update_attribute(:current_nbr,'-999')
  end
  def shutdown()
    systemlog_msg="Shutting Down"
    SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::MESSAGE,instr_id)
    disconn_instr()
  end
  #######
  # process_cmd
  # Process the command. Set the daemon to the appropriate process
  ########
  def process_cmd(cmd)
    try_again=true #initialize Try_again
    begin
      $logger.debug "process_cmd #{@state} => #{cmd}"

      if (cmd == NOMON)
        systemlog_msg="Stopping Monitoring, still connected to instrument"
        SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::MESSAGE,instr_id)
        if (@state == Analyzer::INGRESS)
          stop_ingress()
        elsif (@state == Analyzer::DOWNSTREAM)
          stop_performance()
        elsif (@state == Analyzer::DISCONNECTED)
          conn_instr()
        elsif (@state == Analyzer::CONNECTED)
          #Do Nothing
        end
      elsif (cmd == TSWITCH)
        test_switch()
      elsif(cmd == AUTOCO)
        auto_connect()
      elsif (cmd == FIRMWARE)
        $logger.debug "UPGRADING FIRMWARE"
        systemlog_msg="Upgrading Firmware"
        SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::MESSAGE,instr_id)
        if (@state == Analyzer::INGRESS)
          #Do Nothing
        elsif (@state == Analyzer::CONNECTED)
          upgrade_firmware()
        elsif (@state == Analyzer::DISCONNECTED)
          conn_instr()
          upgrade_firmware()
        elsif (@state == Analyzer::DOWNSTREAM)
          #Do Nothing
        end
      elsif (cmd == INGRESS)
        systemlog_msg="Switching to Ingress Mode"
        SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::MESSAGE,instr_id)
        if (@state == Analyzer::CONNECTED)
          start_ingress()
        elsif (@state == Analyzer::DOWNSTREAM)
          stop_performance()
          start_ingress()
        elsif (@state == Analyzer::DISCONNECTED)
          conn_instr()
          start_ingress()
        elsif (@state == Analyzer::INGRESS)
          #Do Nothing
        end
      elsif (cmd == DOWNSTREAM)
        systemlog_msg="Switching to Downstream Mode"
        SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::MESSAGE,instr_id)
        if (@state == Analyzer::INGRESS)
          stop_ingress()
          start_performance()
        elsif (@state == Analyzer::CONNECTED)
          start_performance()
        elsif (@state == Analyzer::DISCONNECTED)
          conn_instr()
          start_performance()
        elsif (@state == Analyzer::DOWNSTREAM)
          #Do Nothing
        end
      elsif (cmd == HEARTBEAT)
      elsif (cmd == MAINT)
        systemlog_msg="Switching to Maintenance Mode. Disconnecting from instrument."
        SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::MESSAGE,instr_id)
        if (@state == Analyzer::DISCONNECTED)
          $logger.debug "#Do Nothing"
          #Do Nothing
        elsif (@state == Analyzer::CONNECTED)
          disconn_instr()
        elsif (@state == Analyzer::INGRESS)
          stop_ingress()
          disconn_instr()
        elsif (@state == Analyzer::DOWNSTREAM)
          stop_performance()
          disconn_instr()
        else
          systemlog_msg="Unrecognized State: #{@state}"
          SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::WARNING,instr_id)
        end
      elsif (cmd == SHUTDOWN)
        shutdown()
      else
        systemlog_msg= "command #{cmd} are not handled."
        SystemLog.log(systemlog_msg,systemlog_msg,SystemLog::WARNING,instr_id)
      end
    rescue Mysql::Error => ex
      $logger.debug "Mysql Error #{ex.message}"
      retry
    end
  end
  #####
  # process_command_queue
  # Get latest command from queue and process it
  #####
  def process_command_queue
    $logger.debug "process_cmd_queue: #{@cmd_queue.inspect()}"
    while (@cmd_queue.length > 0)
      cmd=@cmd_queue.shift()
      if (!cmd.nil?) #Command Recieved
        Analyzer.connection.reconnect!()
        process_cmd(cmd)
      end
    end
  end
  def run
    @instr_obj.set_command_io()
    Analyzer.connection.reconnect!()
    process_command_queue()
    instr=Analyzer.find(@instr_id)
    instr.update_attributes({:status=>@state, :processing=>nil})
    if @state==Analyzer::INGRESS
      refresh_live_trace()
    end
    agg_time=Time.now()
    try_again=true
    while(1) #Main Loop
      $logger.debug "My STATE is #{@state}"
      #TODO skip this if there is a command already in the queue.
      cmd=command_driver(@instr_obj.command_io,@cmd_port,@state)
      if(!cmd.nil?)
        $logger.debug "Adding to queue"
        addto_queue(cmd)
        #To improve responsiveness let's just skip this get command.  We already have a command in the queue.
        #cmd=command_driver(@instr_obj.command_io,@cmd_port,@state,1)
        #$logger.debug "getting next command"
      end
      process_command_queue()
      begin
        state_machine_iteration()
      rescue NoConnectionError => err
        $logger.debug "No Connection Error #{ex.message}"
        System.log(err.message, err.message+"\n"+err.backtrace().to_s, SystemLog::EXCEPTION, instrument_id)
        $logger.debug ex.backtrace()
        disconn_instr()
      rescue SunriseError => ex
        $logger.debug "Sunrise Error -- #{ex.message}"
        SystemLog.log(ex.message,ex.backtrace(),SystemLog::EXCEPTION,instr_id)
        $logger.debug ex.backtrace()
        disconn_instr()
      rescue Exception => ex
        SystemLog.log(ex.message,ex.backtrace(),SystemLog::EXCEPTION,instr_id)
        $logger.debug "Exception Error #{ex.message}"
        $logger.debug ex.backtrace()
        disconn_instr()
      rescue => ex
        SystemLog.log("UNKNOWN ERROR #{ex.message}",exbacktrace(),SystemLog::EXCEPTION,instr_id)
        $logger.debug "Unknown Error #{ex.message}"
        $logger.debug ex.backtrace()
        disconn_instr()
      end
      $logger.debug "Instrument check."
      instr=Analyzer.find(@instr_id)
      if instr.nil?
        $logger.debug "Instrument has been deleted."
        return
      end
      if (instr.status != @state)
        instr.update_attributes({:status=>@state, :processing=>nil})
        if @state==Analyzer::INGRESS
          refresh_live_trace()
        end
      end
      #if agg_time < Time.now()
      #   agg_time=Time.now()+900
      #   now=Time.now()
      #   target=now-(now % 900)
      #end
    end
  end
end #End Class Monitor

trap('INT') {
  $monitor_obj.shutdown
  exit
}
trap('TERM') {
  $logger.debug("Ignoring TERM")
}

def queue_command(selected_sock)
  if (selected_sock.nil?)
    return
  end
  result=command_parser(selected_sock,4)
  if result != Monitor::HEARTBEAT
    $logger.debug "QUEUEing Command #{result}"
    $monitor_obj.addto_queue(result)
  else
    res_config  = WEBrick::Config::HTTP.dup
    res_config[:Logger]=$logger
    request     = WEBrick::HTTPRequest.new(res_config)
    request.parse(selected_sock.accept)
    $logger.debug "uu:#{request.path}"
    $logger.debug "Not QUEUEing Command #{result}"
  end
end

def command_driver(svr, tgt_cmd_port,state, timeout=5)
  puts svr.inspect()
  $logger.debug "IN Command Driver waiting for select"
  selected_socket_list=select([svr],nil,nil,timeout)
  $logger.debug "IN Command Driver completion for select"
  if (selected_socket_list.nil?)
    return nil
  end
  $logger.debug "A"
  selected_socket=selected_socket_list[0].first()
  $logger.debug "B"
  if (selected_socket.addr[1].to_i == tgt_cmd_port)
    $logger.debug "testswitch2: \r\n"
    result= command_parser(svr, state)
    #$logger.debug "testswitch1: #{result}"
    return result
  end
  $logger.debug "C"
  return nil
end

def command_parser(selected_socket,state)
  STDOUT.flush()
  begin
    res_config  = WEBrick::Config::HTTP.dup
    res_config[:Logger]=$logger
    request     = WEBrick::HTTPRequest.new(res_config)
    response    = WEBrick::HTTPResponse.new(res_config)
    sock        = selected_socket.accept
    sock.sync   = true
    WEBrick::Utils::set_non_blocking(sock)
    WEBrick::Utils::set_close_on_exec(sock)
    request.parse(sock)
    #$logger.debug request.inspect()
    args=request.path.split('/')
    response.request_method=request.request_method
    response.request_uri=request.request_uri
    response.request_http_version=request.http_version
    response.keep_alive=false
    if (args.last == 'MEASURE')
      $logger.debug "Recved a Measure Command"
      #TODO MUSTBE IN CONNECTED MODE TO DO THIS
      #"0" => {:str=> "QPSK" ,:qam=>false, :analog=>false, :dcp=>true }
      #def measure_dcp(freq,bandwidth, attenuator)
      #def measure_analog(video_freq,  audio_offset, attenuator=nil, va2sep=nil)
      #def measure_qam(freq, modulation_type, annex,symb_rate)
      response.body=nil
      query=request.query
      #Verify both modulation, frequency and bandwidth exist.
      if (state!=Analyzer::CONNECTED)
        response.body="FAIL:Not Connected please place instrument in connected mode  #{state}."
      elsif (!query.key?("idx"))
        response.body="FAIL:Need Data Index"
      elsif (!query.key?("modulation"))
        response.body="FAIL:No modulation"
      elsif (!query.key?("freq"))
        response.body="FAIL:No frequency"
      elsif (!query.key?("bandwidth"))
        response.body="FAIL:No bandwidth"
      else
        if (query.key?("switch_port_id"))
          #Do nothing I assume we have a 'no switch' situation here.
          swp_id=query["switch_port_id"].to_i
          port=SwitchPort.find(swp_id)
          @instr_obj.session.set_switch(port.get_calculated_port())
          site=port.get_site()
        end #End switch port key
        modulation=query["modulation"]
        modulation_reqs=$modulations[modulation.to_s]
        reqs_failed=false

        #Verify modulation dependent parameters.
        if (modulation_reqs[:analog] && !query.key?("audio_offset"))
          response.body="FAIL| Audio Offset needed for Analog Measurements"
          reqs_failed=true
        else
          audio_offset=query["audio_offset"].to_i
        end #End audio_offset setting
        #if (!reqs_failed && modulation_reqs[:qam] && !query.key?("annex"))
        #response.body="FAIL| Annex needed for QAM Measurements"
        #reqs_failed=true
        #else
        #annex=query["annex"]
        #end
        #if (!reqs_failed && modulation_reqs[:qam] && !query.key?("symb_rate"))
        #response.body="FAIL| Symbol Rate needed for QAM Measurements"
        #reqs_failed=true
        #else
        #symb_rate=query["symb_rate"]
        #end
        freq=query["freq"].to_i
        bandwidth=query["bandwidth"].to_i
        measurements={}
        if (!reqs_failed)
          if modulation_reqs[:analog]
            $logger.debug query.inspect()
            $logger.debug freq.inspect()
            $logger.debug audio_offset.inspect()
            tmpmeas=$monitor_obj.instr_obj.measure_analog(freq,  audio_offset,$monitor_obj.default_att)
            $logger.debug tmpmeas.inspect
            measurements.merge!(tmpmeas)
          end #Measuring analog
          if modulation_reqs[:dcp]
            tmpmeas=$monitor_obj.instr_obj.measure_dcp(freq, bandwidth, $monitor_obj.default_att)
            measurements.merge!(tmpmeas)
          end #Measuring DCP
          #if modulation_reqs[:qam]
          #   #TODO I think I need to pass bandwidth to measure_qam
          #   tmpmeas=$monitor_obj.instr_obj.measure_qam(freq, modulation_type, annex,symb_rate)
          #   measurements.merge!(tmpmeas)
          #end
          $logger.debug query.inspect
          measurements["idx"]=query["idx"];
          results=""
          $logger.debug "AFTER MERGE"
          $logger.debug measurements.inspect
          measurements.keys.each { |ky|
            results += "#{ky}=#{measurements[ky].to_s};"
          }
          $logger.debug results.inspect
          response.body=results
        end # !reqs_failed
      end #Finished verification of measure parameters.

    elsif (args.last == 'GET_RPTP')
      $logger.debug "get_rptp #{@current_rptp}"
      response.body="#{@switch_delay}"
    else
      response.body="STATUS=>#{state}"
    end
    response.status=200
    $logger.debug response.body.inspect
    response.send_response(sock)
  rescue Errno::ECONNRESET, Errno::ECONNABORTED,Errno::EPROTO => ex
  rescue Exception => ex
    raise
  end
  if (args.last == 'NOMON')
    return Monitor::NOMON
  elsif (args.last == 'FIRMWARE')
    return Monitor::FIRMWARE
  elsif (args.last == 'TSWITCH')
    @switch_delay=args[args.length-2]
    #$logger.debug "url:#{request.path}"
    #$logger.debug "delayswitch #{@switch_delay}"
    return Monitor::TSWITCH
  elsif (args.last == 'INGRESS')
    return Monitor::INGRESS
  elsif (args.last == 'DOWNSTREAM')
    return Monitor::DOWNSTREAM
  elsif (args.last == 'MAINT')
    return Monitor::MAINT
  else
    $logger.debug "Do not queue. Assume a heartbeat"
    return Monitor::HEARTBEAT
  end
end
def flag_datalog(instrument_id)
  $logger.debug "Flagging Datalog"
  $monitor_obj.instr_obj.datalog_flag=true
end

def update_status(prefix,pos,total,instr_id)
  SystemLog.log("#{prefix} #{(pos.to_f/total.to_f*100.0).to_i}% complete ","",SystemLog::PROGRESS,instr_id)
  instr         = Analyzer.find(instr_id)
  instr.update_attributes({:processing=> Time.now})
end

def deactivate_analyzer_alarms(instr)
  instr.get_all_sites().each { |site|
    Alarm.deactivate(site.id)
    DownAlarm.deactivate(site.id)
  }
end
def sleep_it(secs)
  sleep secs
  $logger.debug "Sleeping for #{secs} seconds"
end

begin
  instr         = Analyzer.find(instrument_id)
  deactivate_analyzer_alarms(instr)
  $monitor_obj  = Monitor.new(instrument_id,cmd_port)
  #If analyzer was in downstream or ingress monitoring then restore that monitoring mode on restart.
  if (instr.status == Analyzer::DOWNSTREAM)
    $logger.debug "Add To Queue Downstream"
    $monitor_obj.addto_queue(Monitor::DOWNSTREAM)
  elsif (instr.status == Analyzer::INGRESS)
    $logger.debug "Add To Queue INGRESS"
    $monitor_obj.addto_queue(Monitor::INGRESS)
  else
    instr.update_attributes({:status=>Analyzer::DISCONNECTED, :processing=>nil})
    # $monitor_obj.addto_queue(Monitor::NOMON)
    $monitor_obj.addto_queue(Monitor::AUTOCO)
  end
  instr.update_attributes({:pid=>Process.pid})
  $monitor_obj.run()
rescue SunriseError => e
  $logger.debug "Sunrise Error - #{e.message}"
  SystemLog.log(e.message,e.backtrace(),SystemLog::EXCEPTION,instrument_id)
  $logger.debug e.backtrace()
rescue  Exception => e
  SystemLog.log("UNKNOWN ERROR #{e.message}",e.message + "\n"+e.backtrace().to_s,SystemLog::EXCEPTION,instrument_id)
  $logger.debug e.message
  $logger.debug e.backtrace
  #$monitor_obj.shutdown
ensure
  instr=Analyzer.find(instrument_id)
  instr.update_attributes({:status=>Analyzer::DISCONNECTED, :processing=>nil})
  if instr.att_count < 9
    instr.update_attributes(:att_count=> instr.att_count+1)
  else
    instr.update_attributes({:att_count=> -1,:auto_mode=> 3})
    SystemLog.log("Auto connect Mode shut down as auto connect failed.","Auto Connect have already try 9 times. But Failed, then give up Auto Connect.",SystemLog::RECONNECT,instr.id)
  end
  $logger.debug "Auto connect att_count has been add by 1 current is #{instr.att_count}"
  deactivate_analyzer_alarms(instr)
  `kill -s 9 #{instr.id}` if @kill_flag
end
