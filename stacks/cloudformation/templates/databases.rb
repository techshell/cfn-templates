require 'fog'
require 'sparkle_formation'

ENV['org'] ||= 'indigo'
ENV['environment'] ||= 'dr'
ENV['region'] ||= 'us-east-1'

ENV['snapshots'] ||= ''
ENV['backup_id'] ||= ''

ENV['notification_topic'] ||= "#{ENV['org']}-#{ENV['region']}-terminated-instances"
ENV['net_type'] ||= 'Private'
ENV['sg'] ||= 'private_sg'

def extract(response)
  response.body if response.status == 200
end

connection = Fog::Compute.new({ :provider => 'AWS', :region => ENV['region'] })

# Find subnets and security groups by VPC membership and network type.  These subnets
# and security groups will be passed into the ASG and launch config (respectively) so
# that the ASG knows where to launch instances.

vpcs = extract(connection.describe_vpcs)['vpcSet']
vpc = vpcs.find { |vpc| vpc['tagSet'].fetch('Environment', nil) == ENV['environment']}['vpcId']

subnets = extract(connection.describe_subnets)['subnetSet']
subnets.collect! { |sn| sn['subnetId'] if sn['tagSet'].fetch('Network', nil) == ENV['net_type'] and sn['vpcId'] == vpc }.compact!

sgs = Array.new
ENV['sg'].split(',').each do |sg|
  found_sgs = extract(connection.describe_security_groups)['securityGroupInfo']
  found_sgs.collect! { |fsg| fsg['groupId'] if fsg['tagSet'].fetch('Name', nil) == sg and fsg['vpcId'] == vpc }.compact!
  sgs.concat found_sgs
end

# The user supplied a backup_id, so hunt for snapshots and supply them to the launch configs
# of each database ASG.

snapshots = Array.new(ENV['snapshots'].split(','))
unless ENV['backup_id'].empty?
  found_snaps = extract(connection.describe_snapshots)['snapshotSet'].select { |ss| ss['tagSet'].include?('backup_id')}
  found_snaps.collect! { |ss| ss['snapshotId'] if ss['tagSet']['backup_id'].downcase.include?(ENV['backup_id'].downcase) }.compact
  snapshots.concat found_snaps
  snapshots.compact!
end

# The dereg_queue template sets up an SQS queue that contains node termination news.

sns = Fog::AWS::SNS.new(:region => ENV['region'])
topics = extract(sns.list_topics)['Topics']
topic = topics.find { |e| e =~ /#{ENV['notification_topic']}/ }

# Build the template.

stack = SparkleFormation.new('databases')
stack.load(:precise_ami, :ssh_key_pair, :chef_validator_key_bucket).overrides do
  set!('AWSTemplateFormatVersion', '2010-09-09')
  description <<EOF
Creates a cluster of database instances in order, so that the third instance that is
bootstrapped with Chef will create a complete MongoDB / TokuMX replica set.

Each instance has a number of EBS volumes attached for persistent data storage.  Optionally,
these EBS volumes may be initialized from snapshot.

Each instance is given an IAM instance profile, which allows the instance to get objects
from the Chef Validator Key Bucket.

Launch this template while launching the rabbitmq and file server templates.  Depends on
the VPC template.

EOF

  dynamic!(:iam_instance_profile, 'database', :policy_statements => [ :create_snapshots ])

  # Two database cluster members
  args = [
    'database',
    :iam_instance_profile => :database_iam_instance_profile,
    :iam_instance_role => :database_iam_instance_role,
    :instance_type => 't2.small',
    :create_ebs_volumes => true,
    :volume_count => 4,
    :volume_size => 10,
    :security_groups => sgs,
    :chef_run_list => 'role[base],role[tokumx_server]'
  ]
  args.last.merge!(:snapshots => snapshots) unless snapshots.empty?
  dynamic!(:launch_config_chef_bootstrap, *args)

  dynamic!(:auto_scaling_group,
           'database',
           :launch_config => :database_launch_config,
           :subnets => subnets,
           :notification_topic => topic,
           :min_size => 1,
           :max_size => 2,
           :desired_capacity => 2)

  # Third database cluster member, depends on the first two.  The idea is that a chef run
  # will automatically set up the replicaset once the third database server comes online.
  args = [
    'thirddatabase',
    :iam_instance_profile => :database_iam_instance_profile,
    :iam_instance_role => :database_iam_instance_role,
    :instance_type => 't2.small',
    :create_ebs_volumes => true,
    :volume_count => 4,
    :volume_size => 10,
    :security_groups => sgs,
    :chef_run_list => 'role[base],role[tokumx_server],role[tokumx_backups]'
  ]
  args.last.merge!(:snapshots => snapshots) unless snapshots.empty?
  dynamic!(:launch_config_chef_bootstrap, *args)

  dynamic!(:auto_scaling_group,
           'thirddatabase',
           :launch_config => :thirddatabase_launch_config,
           :subnets => subnets,
           :notification_topic => topic,
           :min_size => 0,
           :max_size => 1,
           :desired_capacity => 1,
           :depends_on => 'DatabaseAsg')
end
