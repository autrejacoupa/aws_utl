#!/usr/bin/env ruby

# Creates a EBS snapshot of EBS volumes attached to this instance and needs AWS credentials under /etc/aws.conf 

#cat << EOF > /etc/aws.conf
#region: us-east-1
#aws_access_key_id: Akia..............
#aws_secret_access_key: h9Zx.........................
#EOF
 
require 'rubygems'
require 'fog'
require 'time'

abort("Failed to find /etc/aws.conf") if !File.exists? '/etc/aws.conf'
ec2_bin="/opt/ec2/tools/bin" 
instance_id=`wget -q -O- http://169.254.169.254/latest/meta-data/instance-id`

$deployment = ""
$nickname = "#{instance_id}"
$snap_age_delete = -1
$snap_always_keep = false

loop {
case ARGV[0]
  when '-nickname'
    ARGV.shift; $nickname = ARGV.shift
  when '-snap_always_keep'
    ARGV.shift; $snap_always_keep = ARGV.shift
  when '-deployment'
    ARGV.shift; $deployment = ARGV.shift
  when '-snap_age_delete'
    ARGV.shift; $snap_age_delete = ARGV.shift.to_i
  when /^-/
    message  = "Usage: -nickname [nickname] -snap_always_keep true|false -deployment <string> -snap_age_delete days"
    message += "       nickname: added as tag to snapshot"
    message += "       snap_always_keep: default is to mark it to be deleted after snap_age_delete days"
    message += "       deployment: optional, added as tag to snapshot, any string prd, dev prd99"
    message += "       snap_age_delete: optional, default not to delete old snapshots, mention how many days old snapshot with tag nickname and snap_always_keep should be deleted."
    abort ("#{message}")
  else break
end;
}

config = YAML.load(File.read('/etc/aws.conf'))

aws = Fog::Compute.new(
  :provider => 'AWS',
  :region => config['region'],
  :aws_access_key_id => config['aws_access_key_id'],
  :aws_secret_access_key => config['aws_secret_access_key']
)

# Grab the volume
vols = aws.volumes.select{ |volume| volume.server_id == "#{instance_id}" }

if (!vols)
  puts "Attached EBS volume cannot be found."
  exit 1
end  

time = Time.now.utc
puts "Creating snapshot for volumes attached to #{instance_id} #{time}"
time_stamp = time.strftime("%Y%m%d%H%M%S")

vols.each do |vol|
  puts "Creating snapshot for #{vol.id}"
  snapshot = aws.snapshots.new
  name = "#{$nickname}:#{time_stamp}"
  description = name  + ":#{$deployment}:#{vol.device}:#{vol.id}:#{vol.size}"
  snapshot.description =  description
  snapshot.volume_id = vol.id
  snapshot.save
  snapshot.reload
  aws.tags.create(:resource_id => snapshot.id, :key => "c_deployment", :value => $deployment)
  aws.tags.create(:resource_id => snapshot.id, :key => "c_nickname", :value => $nickname)
  aws.tags.create(:resource_id => snapshot.id, :key => "c_object", :value => 'snapshot')
  aws.tags.create(:resource_id => snapshot.id, :key => "c_always_keep", :value => false)
  aws.tags.create(:resource_id => snapshot.id, :key => "c_name", :value => name)
  aws.tags.create(:resource_id => snapshot.id, :key => "c_description", :value => description)
end

# Cleanup old snapshots
if ($snap_age_delete >= 0)
  puts "Delete old snaps older than #{$snap_age_delete} days."
  tags = aws.tags.all(:key => 'c_nickname', :value => $nickname)
  tags.each do |tag|
    next if tag.resource_type != 'snapshot'
    snapshot = aws.snapshots.get(tag.resource_id)
    puts "Checking snapshot #{snapshot.description}"
    if (snapshot.created_at < Time.now - ($snap_age_delete * 24 * 60 * 60) && snapshot.tags['c_always_keep'] != 'true')
      puts "Deleting snapshot #{snapshot.description}"
      aws.delete_snapshot(snapshot.id)
    end
  end
end