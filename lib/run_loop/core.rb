require 'fileutils'
require 'tmpdir'
require 'timeout'
require 'json'
require 'open3'

module RunLoop

  class TimeoutError < RuntimeError
  end

  module Core

    START_DELIMITER = "OUTPUT_JSON:\n"
    END_DELIMITER="\nEND_OUTPUT"

    SCRIPTS_PATH = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'scripts'))
    SCRIPTS = {
        :dismiss => 'run_dismiss_location.js',
        :run_loop_fast_uia => 'run_loop_fast_uia.js',
        :run_loop_host => 'run_loop_host.js'
    }

    def self.scripts_path
      SCRIPTS_PATH
    end

    def self.script_for_key(key)
      if SCRIPTS[key].nil?
        return nil
      end
      File.join(scripts_path, SCRIPTS[key])
    end

    def self.detect_connected_device
      begin
        Timeout::timeout(1, TimeoutError) do
          return `#{File.join(scripts_path, 'udidetect')}`.chomp
        end
      rescue TimeoutError => _
        `killall udidetect &> /dev/null`
      end
      nil
    end

    def self.run_with_options(options)
      before = Time.now
      ensure_instruments_not_running!

      device_target = options[:udid] || options[:device_target] || detect_connected_device || 'simulator'
      if device_target && device_target.to_s.downcase == 'device'
        device_target = detect_connected_device
      end

      log_file = options[:log_path]
      timeout = options[:timeout] || 30

      results_dir = options[:results_dir] || Dir.mktmpdir('run_loop')
      results_dir_trace = File.join(results_dir, 'trace')
      FileUtils.mkdir_p(results_dir_trace)

      dependencies = options[:dependencies] || []
      dependencies << File.join(scripts_path, 'calabash_script_uia.js')
      dependencies.each do |dep|
        FileUtils.cp(dep, results_dir)
      end

      script = File.join(results_dir, '_run_loop.js')


      code = File.read(options[:script])
      code = code.gsub(/\$PATH/, results_dir)
      code = code.gsub(/\$MODE/, 'FLUSH') unless options[:no_flush]

      repl_path = File.join(results_dir, 'repl-cmd.txt')
      File.open(repl_path, 'w') { |file| file.puts "0:UIALogger.logMessage('Listening for run loop commands');" }

      File.open(script, 'w') { |file| file.puts code }


      # Compute udid and bundle_dir / bundle_id from options and target depending on Xcode version

      udid, bundle_dir_or_bundle_id = udid_and_bundle_for_launcher(device_target, options)

      args = options.fetch(:args, [])

      log_file ||= File.join(results_dir, 'run_loop.out')

      if ENV['DEBUG']=='1'
        p options
        puts "device_target=#{device_target}"
        puts "udid=#{udid}"
        puts "bundle_dir_or_bundle_id=#{bundle_dir_or_bundle_id}"
        puts "script=#{script}"
        puts "log_file=#{log_file}"
        puts "timeout=#{timeout}"
        puts "args=#{args}"
      end

      after = Time.now

      if ENV['DEBUG']=='1'
        puts "Preparation took #{after-before} seconds"

      end

      cmd = instruments_command(options.merge(:udid => udid,
                                              :results_dir_trace => results_dir_trace,
                                              :bundle_dir_or_bundle_id => bundle_dir_or_bundle_id,
                                              :results_dir => results_dir,
                                              :script => script,
                                              :log_file => log_file,
                                              :args => args))

      log_header("Starting on #{device_target} App: #{bundle_dir_or_bundle_id}")
      cmd_str = cmd.join(' ')
      if ENV['DEBUG']
        log(cmd_str)
      end
      if !jruby? && RUBY_VERSION && RUBY_VERSION.start_with?('1.8')
        pid = fork do
          exec(cmd_str)
        end
      else
        pid = spawn(cmd_str)
      end

      Process.detach(pid)

      File.open(File.join(results_dir, 'run_loop.pid'), 'w') do |f|
        f.write pid
      end

      run_loop = {:pid => pid, :udid => udid, :app => bundle_dir_or_bundle_id, :repl_path => repl_path, :log_file => log_file, :results_dir => results_dir}

      uia_timeout = options[:uia_timeout] || (ENV['UIA_TIMEOUT'] && ENV['UIA_TIMEOUT'].to_f) || 10

      before = Time.now
      begin
        Timeout::timeout(timeout, TimeoutError) do
          read_response(run_loop, 0, uia_timeout)
        end
      rescue TimeoutError => e
        if ENV['DEBUG']
          puts "Failed to launch\n"
          puts "reason=#{e}: #{e && e.message} "
          puts "device_target=#{device_target}"
          puts "udid=#{udid}"
          puts "bundle_dir_or_bundle_id=#{bundle_dir_or_bundle_id}"
          puts "script=#{script}"
          puts "log_file=#{log_file}"
          puts "timeout=#{timeout}"
          puts "args=#{args}"
        end
        raise TimeoutError, "Time out waiting for UIAutomation run-loop to Start. \n Logfile #{log_file} \n\n #{File.read(log_file)}\n"
      end

      after = Time.now()

      if ENV['DEBUG']=='1'
        puts "Launching took #{after-before} seconds"
      end

      run_loop
    end

    def self.udid_and_bundle_for_launcher(device_target, options)
      bundle_dir_or_bundle_id = options[:app] || ENV['BUNDLE_ID']|| ENV['APP_BUNDLE_PATH'] || ENV['APP']

      unless bundle_dir_or_bundle_id
        raise 'key :app or environment variable APP_BUNDLE_PATH, BUNDLE_ID or APP must be specified as path to app bundle (simulator) or bundle id (device)'
      end

      udid = nil
      if above_or_eql_version?('5.1', xcode_version)
        if device_target.nil? || device_target.empty? || device_target == 'simulator'
          device_target = 'iPhone Retina (4-inch) - Simulator - iOS 7.1'
        end
        udid = device_target

        unless /simulator/i.match(device_target)
          bundle_dir_or_bundle_id = options[:bundle_id] if options[:bundle_id]
        end

      else
        if device_target == 'simulator'

          unless File.exist?(bundle_dir_or_bundle_id)
            raise "Unable to find app in directory #{bundle_dir_or_bundle_id} when trying to launch simulator"
          end


          device = options[:device] || :iphone
          device = device && device.to_sym

          plistbuddy='/usr/libexec/PlistBuddy'
          plistfile="#{bundle_dir_or_bundle_id}/Info.plist"
          if device == :iphone
            uidevicefamily=1
          else
            uidevicefamily=2
          end
          system("#{plistbuddy} -c 'Delete :UIDeviceFamily' '#{plistfile}'")
          system("#{plistbuddy} -c 'Add :UIDeviceFamily array' '#{plistfile}'")
          system("#{plistbuddy} -c 'Add :UIDeviceFamily:0 integer #{uidevicefamily}' '#{plistfile}'")
        else
          udid = device_target
          bundle_dir_or_bundle_id = options[:bundle_id] if options[:bundle_id]
        end
      end
      return udid, bundle_dir_or_bundle_id
    end

    def self.above_or_eql_version?(target_version, xcode_version)
      t_major,t_minor,t_patch = target_version.split('.')
      x_major,x_minor,x_patch = xcode_version.split('.')
      return true if x_major.to_i > t_major.to_i
      return false if x_major.to_i < t_major.to_i
      #major versions are equal
      t_minor_i = (t_minor && t_minor.to_i || 0)
      x_minor_i = (x_minor && x_minor.to_i || 0)
      return true if x_minor_i > t_minor_i
      return false if x_minor_i < t_minor_i
      #minor versions are equal

      t_patch_i = (t_patch && t_patch.to_i || 0)
      x_patch_i = (x_patch && x_patch.to_i || 0)

      x_patch_i >= t_patch_i
    end

    def self.xcode_version
      xcode_build_output = `xcrun xcodebuild -version`.split("\n")
      xcode_build_output.each do |line|
        match=/^Xcode\s(.*)$/.match(line.strip)
        return match[1] if match && match.length > 1
      end
    end

    def self.jruby?
      RUBY_PLATFORM == 'java'
    end

    def self.write_request(run_loop, cmd)
      repl_path = run_loop[:repl_path]

      cur = File.read(repl_path)

      colon = cur.index(':')

      if colon.nil?
        raise "Illegal contents of #{repl_path}: #{cur}"
      end
      index = cur[0, colon].to_i + 1


      tmp_cmd = File.join(File.dirname(repl_path), '__repl-cmd.txt')
      File.open(tmp_cmd, 'w') do |f|
        f.write("#{index}:#{cmd}")
        if ENV['DEBUG']
          puts "Wrote: #{index}:#{cmd}"
        end
      end

      FileUtils.mv(tmp_cmd, repl_path)
      index
    end

    def self.read_response(run_loop, expected_index, empty_file_timeout=10)

      log_file = run_loop[:log_file]
      initial_offset = run_loop[:initial_offset] || 0
      offset = initial_offset

      result = nil
      loop do
        unless File.exist?(log_file) && File.size?(log_file)
          sleep(0.2)
          next
        end


        size = File.size(log_file)

        output = File.read(log_file, size-offset, offset)

        if /AXError: Could not auto-register for pid status change/.match(output)
          if /kAXErrorServerNotFound/.match(output)
            $stderr.puts "\n\n****** Accessibility is not enabled on device/simulator, please enable it *** \n\n"
            $stderr.flush
          end
          raise TimeoutError.new('AXError: Could not auto-register for pid status change')
        end
        if /Automation Instrument ran into an exception/.match(output)
          raise TimeoutError.new('Exception while running script')
        end
        index_if_found = output.index(START_DELIMITER)
        if ENV['DEBUG_READ']=='1'
          puts output.gsub('*', '')
          puts "Size #{size}"
          puts "offset #{offset}"
          puts "index_of #{START_DELIMITER}: #{index_if_found}"
        end

        if index_if_found

          offset = offset + index_if_found
          rest = output[index_if_found+START_DELIMITER.size..output.length]
          index_of_json = rest.index("}#{END_DELIMITER}")

          if index_of_json.nil?
            #Wait for rest of json
            sleep(0.1)
            next
          end

          json = rest[0..index_of_json]


          if ENV['DEBUG_READ']=='1'
            puts "Index #{index_if_found}, Size: #{size} Offset #{offset}"

            puts ("parse #{json}")
          end

          offset = offset + json.size
          parsed_result = JSON.parse(json)
          if ENV['DEBUG_READ']=='1'
            p parsed_result
          end
          json_index_if_present = parsed_result['index']
          if json_index_if_present && json_index_if_present == expected_index
            result = parsed_result
            break
          end
        else
          sleep(0.1)
        end
      end

      run_loop[:initial_offset] = offset

      result

    end

    def self.pids_for_run_loop(run_loop, &block)
      results_dir = run_loop[:results_dir]
      udid = run_loop[:udid]
      instruments_prefix = instruments_command_prefix(udid, results_dir)

      pids_str = `ps x -o pid,command | grep -v grep | grep "#{instruments_prefix.gsub(%Q["], %Q[\\"])}" | awk '{printf "%s,", $1}'`
      pids = pids_str.split(',').map { |pid| pid.to_i }
      if block_given?
        pids.each do |pid|
          block.call(pid)
        end
      else
        pids
      end
    end

    def self.instruments_command_prefix(udid, results_dir_trace)
      instruments_path = 'instruments'
      if udid
        instruments_path = "#{instruments_path} -w \"#{udid}\""
      end
      instruments_path << " -D \"#{results_dir_trace}\"" if results_dir_trace
      instruments_path
    end


    def self.instruments_command(options)
      udid = options[:udid]
      results_dir_trace = options[:results_dir_trace]
      bundle_dir_or_bundle_id = options[:bundle_dir_or_bundle_id]
      results_dir = options[:results_dir]
      script = options[:script]
      log_file = options[:log_file]
      args= options[:args] || []

      instruments_prefix = instruments_command_prefix(udid, results_dir_trace)
      cmd = [
          instruments_prefix,
          '-t', "\"#{automation_template}\"",
          "\"#{bundle_dir_or_bundle_id}\"",
          '-e', 'UIARESULTSPATH', results_dir,
          '-e', 'UIASCRIPT', script,
          args.join(' ')
      ]
      if log_file
        cmd << "&> #{log_file}"
      end
      cmd
    end

    def self.automation_template(candidate = ENV['TRACE_TEMPLATE'])
      unless candidate && File.exist?(candidate)
        candidate = default_tracetemplate
      end
      candidate
    end

    def self.default_tracetemplate
      cmd = 'xcrun instruments -s templates'
      xc_version = self.xcode_version
      if above_or_eql_version?('5.1', xc_version)
        `#{cmd}`.split("\n").delete_if { |path| not path =~ /Automation.tracetemplate/ }.first
      else
        # prints to $stderr (>_>) - seriously?
        Open3.popen3(cmd) do |_, _, stderr, _|
          stderr.read.chomp.split(/(,|\(|")/).map do |elm|
            elm.strip
          end.delete_if do |path|
            not path =~ /Automation.tracetemplate/
          end.first
        end
      end
    end

    def self.log(message)
      if ENV['DEBUG']=='1'
        puts "#{Time.now } #{message}"
        $stdout.flush
      end
    end

    def self.log_header(message)
      if ENV['DEBUG']=='1'
        puts "\n\e[#{35}m### #{message} ###\e[0m"
        $stdout.flush
      end
    end

    def self.ensure_instruments_not_running!
      instruments_pids.each do |pid|
        if ENV['DEBUG']=='1'
          puts "Found instruments #{pid}. Killing..."
        end
        `kill -9 #{pid} && wait #{pid} &> /dev/null`
      end
    end

    def self.instruments_running?
      instruments_pids.size > 0
    end

    def self.instruments_pids
      pids_str = `ps x -o pid,command | grep -v grep | grep "instruments" | awk '{printf "%s,", $1}'`.strip
      pids_str.split(',').map { |pid| pid.to_i }
    end

  end


  def self.run(options={})
    script = validate_script(options)
    options[:script] = script

    Core.run_with_options(options)
  end

  def self.send_command(run_loop, cmd, timeout=60)

    if not cmd.is_a?(String)
      raise "Illegal command #{cmd} (must be a string)"
    end


    expected_index = Core.write_request(run_loop, cmd)
    result = nil

    begin
      Timeout::timeout(timeout, TimeoutError) do
        result = Core.read_response(run_loop, expected_index)
      end

    rescue TimeoutError => _
      raise TimeoutError, "Time out waiting for UIAutomation run-loop for command #{cmd}. Waiting for index:#{expected_index}"
    end

    result
  end

  def self.stop(run_loop, out=Dir.pwd)
    return if run_loop.nil?
    results_dir = run_loop[:results_dir]

    dest = out


    Core.pids_for_run_loop(run_loop) do |pid|
      Process.kill('TERM', pid.to_i)
    end


    FileUtils.mkdir_p(dest)

    if results_dir
      pngs = Dir.glob(File.join(results_dir, 'Run 1', '*.png'))
    else
      pngs = []
    end
    FileUtils.cp(pngs, dest) if pngs and pngs.length > 0
  end


  def self.validate_script(options)
    script = options[:script]
    if script
      if script.is_a?(Symbol)
        script = Core.script_for_key(script)
        unless script
          raise "Unknown script for symbol: #{options[:script]}. Options: #{Core::SCRIPTS.keys.join(', ')}"
        end
      elsif script.is_a?(String)
        unless File.exist?(script)
          raise "File does not exist: #{script}"
        end
      else
        raise "Unknown type for :script key: #{options[:script].class}"
      end
    else
      script = Core.script_for_key(:run_loop_fast_uia)
    end
    script
  end

end
