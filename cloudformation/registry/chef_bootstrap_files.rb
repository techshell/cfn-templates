SparkleFormation::Registry.register(:chef_bootstrap_files) do
  metadata('AWS::CloudFormation::Init') do
    _camel_keys_set(:auto_disable)
    config do
      files('/etc/chef/chef-client-config.json') do
        content join!(
                    "{\n",
                    "  \"chef_client\": {\n",
                    "    \"server_url\": \"", ref!(:chef_server_u_r_l), "\",\n",
                    "    \"validation_client_name\": \"", ref!(:chef_validation_client_user_name), "\"\n",
                    "  },\n",
                    "  \"run_list\": [ \"recipe[chef-client::config]\" ]\n",
                    "}\n"
                )
        mode '000644'
        owner 'root'
        group 'root'
      end
      files('/etc/chef/solo.rb') do
        content join!(
                    "log_level :info\n",
                    "log_location STDOUT\n",
                    "file_cache_path \"/var/chef-solo\"\n",
                    "cookbook_path \"/var/chef-solo/cookbooks\"\n",
                    "recipe_url \"http://s3.amazonaws.com/chef-solo/bootstrap-latest.tar.gz\"\n"
                )
        mode '000644'
        owner 'root'
        group 'root'
      end
      files('/etc/chef/chef-client-bootstrap.json') do
        content join!(
                    "{\n",
                    "  \"run_list\": [ \"",
                    join!( ref!(:chef_run_list), {:options => { :delimiter => '", "'}}),
                    "\" ]\n",
                    "}\n"
                )
        mode '000644'
        owner 'root'
        group 'root'
      end
      files('/home/ubuntu/.s3cfg') do
        content join!(
                    "[default]\n",
                    "access_key = ", ref!(:cfn_keys), "\n",
                    "secret_key = ", attr!(:cfn_keys, :secret_access_key), "\n",
                    "use_https = True\n"
                )
        mode '000644'
        owner 'root'
        group 'root'
      end
    end
  end
end
