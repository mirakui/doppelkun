# vim:fileencoding=utf-8
BASE_DIR = File.dirname(__FILE__)
$:<< File.join(BASE_DIR, 'gena/lib')
require 'rubygems'
require 'bundler/setup'
require 'gena/twitter'
require 'time'
require 'logger'
require 'pp'
require 'optparse'
require 'uri'
require 'open-uri'
if RUBY_VERSION>="1.9"
  require 'ruby-debug'
else
  require 'ruby-debug'
  $KCODE='u'
end
require File.join(BASE_DIR, 'lib/file_db')

$target_file         = Gena::FileDB.new 'tmp/target',         :base=>__FILE__
$since_id_file       = Gena::FileDB.new 'tmp/since_id',       :base=>__FILE__
$reply_since_id_file = Gena::FileDB.new 'tmp/reply_since_id', :base=>__FILE__

$log = Logger.new(STDOUT)
#$log.level = Logger::DEBUG
$log = Logger.new(File.join(BASE_DIR, 'log', 'doppelkun.log'), 'daily')
$log.level = $DEBUG ? Logger::DEBUG : Logger::INFO

def retry_on(retry_count_max, sleep_time=1)
  retry_count = 0
  begin
    yield
  rescue => e
    if retry_count < retry_count_max
      retry_count += 1
      $log.warn "Retry [#{retry_count}/#{retry_count_max}]: #{e.inspect}"
      sleep sleep_time
      retry
    else
      raise e
    end
  end
end

def retarget(tw, target=nil)
  $log.info('begin retarget')

  target_old = $target_file.read
  $log.debug "target_old=#{target_old}"

  if target.nil?
    #friends = tw.my(:followers).map {|f| f.screen_name}
    target_old_id = tw.show(target_old)['id']
    followers_ids = tw.followers_ids
    $log.debug "followers=(#{followers_ids.length})#{followers_ids.join ','}"

    target_id = (followers_ids - [target_old_id]).sample
    target = tw.show(target_id)['screen_name']
  end
  $log.debug "target=#{target}"

  $target_file.write target
  $log.info "target wrote: #{target}"

  since_id = tw.user_timeline('id'=>target).first['id']

  $since_id_file.write since_id
  $log.info "wrote since_id #{since_id}"

  tw.update ". @#{target_old} -> ?"
  tw.message target_old, 'さようなら'
  tw.message target, '今日はあなたに決めた'
  $log.info "retarget @#{target_old} -> @#{target}"

  $log.info 'end retarget'

  target
end

def mirror_post(tw)
  $log.info('begin mirror_post')
  target   = $target_file.read || retarget(tw)

  $log.debug "target=#{target}"
  since_id = $since_id_file.read

  $log.debug "since_id=#{since_id}"

  timeline = since_id ?
    tw.user_timeline('id'=>target, 'since_id'=>since_id).reverse :
    tw.user_timeline('id'=>target).reverse

  $log.debug "timeline.length=#{timeline.length}"

  unless timeline.empty?
    timeline.each do |t|
      last_id = t['id']
      #text = URI.escape(t.text.delete('@'), /[&]/)
      text = t['text']
      retry_on(3) do
        tw.update text.force_encoding("utf-8")
      end
      $since_id_file.write last_id
      $log.info "wrote since_id #{last_id}"
    end
    $log.info "posted #{timeline.length} statuses"
  else
    $log.info "no statuses to mirror"
  end
  $log.info 'end mirror_post'

  forward_replies(tw)
end

def forward_replies(tw)
  $log.info('begin forward_replies')
  target = $target_file.read || retarget(tw)
  reply_since_id = $reply_since_id_file.read
  rss = ''
  mentions = []
  retry_on(3) do
    mentions = tw.mentions( reply_since_id ? {'since_id' => reply_since_id} : {} )
  end

  first = true
  mentions.each do |mention|
    status_id    = mention['id']

    if first
      if reply_since_id != status_id
        $reply_since_id_file.write status_id
        $log.info "wrote reply_since_id #{status_id}"
      else
        $log.info "didn't wrote reply_since_id #{status_id}"
      end
      first = false
    end

    if reply_since_id == status_id
      $log.debug "breaked by status_id #{status_id}"
      break
    end

    #status      = description.scan(/^[^\s]+?\s(.*)$/).first.first
    status      = description
    status      = URI.escape(status, /[&]/).force_encoding('utf-8')
    from        = mention['user']['screen_name']
    if from == target 
      $log.info "didn't sent a message because from == target(#{target}), status_id:#{status_id}"
    else
      message = "@#{from} が「#{status}」だって"
      tw.message target, message
      $log.info "sent a message '#{message}' to #{target}"
    end
  end
  $log.info('end forward_replies')
end

def announce_target(tw)
  $log.info('begin announce_target')
  target = $target_file.read || retarget(tw)
  status = "今日は @#{target} に憑いてる"
  tw.update status
  $log.info "sent a status '#{status}'"
  $log.info('end announce_target')
end

# main
begin
  task  = ARGV.shift

  retry_count = 3
  pit = nil
  retry_on(3) do
    $log.info "trying to load a pit (left #{retry_count})"
  end

  tw = nil
  retry_on(3) do
    #tw = Gena::Twitter.load_pit('mirakuitest')
    tw = Gena::Twitter.load_pit('doppelkun')
    tw.logger = $log
  end

  case task
  when 'retarget'
    retarget(tw, ARGV.shift)
  when 'announce'
    announce_target(tw)
  when 'test'
    forward_replies(tw)
  else
    mirror_post(tw)
  end
rescue StandardError => e
  $log.error [e.class.to_s, e.to_s, e.backtrace].flatten.join("\n\t")
  exit 1
rescue Object => e
  $log.error "#{e.class}:#{e.to_s}"
  exit 1
end

__END__
