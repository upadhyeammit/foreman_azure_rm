module ForemanAzureRM
  class AzureRM < ComputeResource
    alias_attribute :sub_id, :user
    alias_attribute :secret_key, :password
    alias_attribute :app_ident, :url
    alias_attribute :tenant, :uuid

    delegate :logger, :to => :Rails

    validates :url, :user, :password, :uuid, :presence => true

    before_create :test_connection

    def to_label
      "#{name} (#{provider_friendly_name})"
    end

    def self.model_name
      ComputeResource.model_name
    end

    def provider_friendly_name
      'Azure Resource Manager'
    end

    def capabilities
      [:image]
    end

    def locations
      [
        'Central US',
        'South Central US',
        'North Central US',
        'West Central US',
        'East US',
        'East US 2',
        'West US',
        'West US 2'
      ]
    end

    def resource_groups
      rgs      = rg_client.list_resource_groups
      rg_names = []
      rgs.each do |rg|
        rg_names << rg.name
      end
      rg_names
    end

    def available_resource_groups
      rg_client.list_resource_groups
    end

    def storage_accts(location = nil)
      stripped_location = location.gsub(/\s+/, '').downcase
      acct_names        = []
      if location.nil?
        storage_client.list_all.each do |acct|
          acct_names << acct.name
        end
      else
        (storage_client.list_all.select { |acct| acct.location == stripped_location }).each do |acct|
          acct_names << acct.name
        end
      end
      acct_names
    end

    def provided_attributes
      super.merge(:ip => :provisioning_ip_address)
    end

    def host_interfaces_attrs(host)
      host.interfaces.select(&:physical?).each.with_index.reduce({}) do |hash, (nic, index)|
        hash.merge(index.to_s => nic.compute_attributes.merge(
          ip  => nic.ip,
          ip6 => nic.ip6
        ))
      end
    end

    def available_vnets(_attr = {})
      virtual_networks
    end

    def available_networks(_attr = {})
      subnets
    end

    def available_subnets
      subnets
    end

    # TODO Delete this
    def networks
      subnets
    end

    def virtual_networks(location = nil)
      if location.nil?
        vnet_client.list_all
      else
        normalized_location = location.gsub(/\s+/, '').downcase
        vnet_client.list_all.select { |vnet| vnet.location == normalized_location }
      end
    end

    def subnets(location = nil)
      vnets   = virtual_networks(location)
      subnets = []
      vnets.each do |vnet|
        subnets << subnet_client.list(vnet, vnet.resource_group)
      end
      subnets
    end

    def subscriptions
      subscription_client.list
    end

    def test_connection(options = {})
      begin
        super(options)
        subscriptions.present?
      rescue Azure::Armrest::NotFoundException => _e
        errors[:base] << 'Your permissions are insufficient'
      end
    end

    def new_interface(attr = {})
      network_interface_client.create(attr)
    end

    def new_volume(attr = {})
      disk_client.create(attr)
    end

    def vms
      compute_client.list_all
    end

    def vm_sizes(location)
      compute_client.sizes(location)
    end

    def find_vm_by_uuid(uuid)
      # TODO: Find a better way to handle this than loading and sorting through
      # all VMs, which also requires that names be globally unique, instead of
      # unique within a resource group
      vm = vms.all.find { |vm| vm.name == uuid }
      raise ActiveRecord::RecordNotFound unless vm.present?
      vm
    end

    def create_nics(args = {})
      nics               = []
      args[:interfaces_attributes].each do |nic, attrs|
        attrs[:pubip_alloc]  = attrs[:bridge]
        attrs[:privip_alloc] = (attrs[:name] == 'false') ? false : true
        pip_alloc            = if attrs[:pubip_alloc] == 'None'
                                 nil
                               else
                                 attrs[:pubip_alloc]
                               end
        priv_ip_alloc        = if attrs[:priv_ip_alloc]
                                 'Static'
                               else
                                 'Dynamic'
                               end
        if pip_alloc.present?
          pip = public_ip_client.create(
            "#{args[:vm_name]}-pip#{nic}",
            args[:resource_group],
            :location   => args[:location],
            :properties => {
              :public_ip_allocation_method => pip_alloc
            }
          )

        end
        new_nic = network_client.network_interfaces.create(
          "#{args[:vm_name]}-nic#{nic}",
          args[:resource_group],
          :location   => args[:location],
          :properties => {
            :subnet                       => { :id => attrs[:network] },
            :public_ip_address            => { :id => pip.present? ? pip.id : nil },
            :ip_configuration_name        => 'ipcfg01',
            :private_ip_allocation_method => priv_ip_alloc
          }
        )
        nics << new_nic
      end
      nics
    end

    def constuct_os_profile(args = {})
      os_profile = {
        :admin_username => args[:username],
        :admin_password => args[:password],
        :computer_name  => args[:vm_name]
      }
      case args[:platform].lower
      when 'windows'
        os_profile[:windows_configuration] = {
          :enable_automatic_updates => false,
          :provision_vm_agent       => true
        }
      when 'linux'
        os_profile[:linux_configuration] = {
          :disable_password_authentication => args[:ssh_key_data].present?,
          :ssh                             => {
            :key_data => args.fetch(:ssh_key_data, nil),
            :path     => args.fetch(:ssh_key_path, nil)
          }
        }
      else
        raise "Invalid platform: #{args[:platform]}"
      end
      os_profile
    end

    def construct_storage_profile(args)
      storage_profile = {
        :image_reference => {},
        :os_disk         => {},
        :data_disks      => []
      }
      if args[:image_id].start_with?('/')
        storage_profile[:image_reference] = { :id => args[:image_id] }
      else
        urn = args[:image_id].split(':')
        storage_profile[:image_reference] = {
          :publisher => urn[0],
          :offer     => urn[1],
          :sku       => urn[2],
          :version   => urn[3]
        }
      end
      storage_profile[:os_disk] = {
        :caching       => args[:os_disk_caching],
        :create_option => :from_image,
        :disk_size_gb  => args[:os_disk_size],
        :managed_disk  => { :storage_account_type => args[:premium_os_disk] ? 'Premium_LRS' : 'Standard_LRS' },
        :name          => "#{args[:vm_name]}-osDisk",
        :os_type       => args[:platform]
      }
      args[:volumes_attributes].each_with_index do |disk, idx|
        storage_profile[:data_disks] << {
          :caching       => disk[:data_disk_caching],
          :disk_size_gb  => disk[:disk_size_gb],
          :create_option => 'Empty',
          :lun           => idx + 1,
          :managed_disk  => { :storage_account_type => disk[:account_type] ? 'Premium_LRS' : 'Standard_LRS' }
        }
      end
      storage_profile
    end

    def construct_vm_proprties(args = {})
      nics = create_nics(args)

      {
        :hardware_profile => { :vm_size => args[:vm_size] },
        :license_type     => args[:license_type],
        :os_profile       => constuct_os_profile(args),
        :network_profile  => nics.each_with_index.map { |nic, idx| { :id => nic.id, :primary => idx == 0 } },
        :storage_profile  => construct_storage_profile(args),
      }
    end

    def create_vm_extension(args = {})
      return nil unless args[:script_command].present? && args[:script_uris].present?
      properties = {
        :auto_upgrade_minor_version => true,
        :settings                   => {
          :command_to_execute => args[:script_command],
          :file_uris          => args[:script_uris].split(',')
        }
      }
      if args[:platform] == 'Linux'
        properties[:publisher] = 'Microsoft.Azure.Extensions'
        properties[:virtual_machine_extension_type] = 'CustomScript'
        properties[:type_handler_version] = '2.0'
      elsif args[:platform] == 'Windows'
        properties[:publisher] = 'Microsoft.Compute'
        properties[:virtual_machine_extension_type] = 'CustomScriptExtension'
        properties[:type_handler_version] = '1.7'
      end

      extension = {
        :location   => args[:location],
        :properties => properties
      }
      extension_client.create(
        args[:vm_name],
        'ForemanCustomScript',
        extension,
        args[:resource_group]
      )
    end

    def convert_to_fog_model(args = {})
    end

    # TODO convert VM to Fog model
    def create_vm(args = {})
      args[:vm_name] = args[:name].split('.')[0]
      args[:location] = args[:location].gsub(/\s+/, '').downcase
      vm = compute_client.create(
        args[:vm_name],
        args[:resource_group],
        :location   => args[:location],
        :properties => construct_vm_proprties(args)
      )

      create_vm_extension(args)
      vm
      # compute_client.servers.new vm_hash
    # fog-azure-rm raises all ARM errors as RuntimeError
    rescue Fog::Errors::Error, RuntimeError => e
      Foreman::Logging.exception('Unhandled Azure RM error', e)
      destroy_vm vm.id if vm
      raise e
    end

    # TODO convert Azure Armrest
    def destroy_vm(uuid)
      vm           = find_vm_by_uuid(uuid)
      raw_model    = compute_client.get_virtual_machine(vm.resource_group, vm.name)
      os_disk_name = raw_model.storage_profile.os_disk.name
      data_disks   = raw_model.storage_profile.data_disks
      nic_ids      = vm.network_interface_card_ids
      # In ARM things must be deleted in order
      vm.destroy
      nic_ids.each do |id|
        nic   = network_client.network_interfaces.get(id.split('/')[4],
                                                      id.split('/')[-1])
        ip_id = nic.public_ip_address_id
        nic.destroy
        if ip_id.present?
          network_client.public_ips.get(ip_id.split('/')[4],
                                        ip_id.split('/')[-1]).destroy
        end
      end
      compute_client.managed_disks.get(vm.resource_group, os_disk_name).destroy
      data_disks.each do |disk|
        compute_client.managed_disks.get(vm.resource_group, disk.name).destroy
      end
    rescue ActiveRecord::RecordNotFound
      # If the VM does not exist, we don't really care.
      true
    end

    protected

    def arm_api_configration
      @config ||= Azure::Armrest::Configuration.new(
        :client_id       => app_ident,
        :client_key      => secret_key,
        :tenant_id       => tenant,
        :subscription_id => sub_id
      )
    end

    def compute_client
      @compute_client ||= Azure::Armrest::VirtualMachineService.new(arm_api_configration)
    end

    def extension_client
      @extension_client ||= Azure::Armrest::VirtualMachineExtensionService.new(arm_api_configration)
    end

    def disk_client
      @disk_client ||= Azure::Armrest::DiskService.new(arm_api_configration)
    end

    def rg_client
      @rg_client ||= Azure::Armrest::ResourceGroupService.new(arm_api_configration)
    end

    def storage_client
      @storage_client ||= Azure::Armrest::StorageAccountService.new(arm_api_configration)
    end

    def network_interface_client
      @network_client ||= Azure::Armrest::NetworkInterfaceService.new(arm_api_configration)
    end

    def vnet_client
      @vnet_client ||= Azure::Armrest::VirtualNetworkService.new(arm_api_configration)
    end

    def subnet_client
      @subnet_client ||= Azure::Armrest::SubnetService.new(arm_api_configration)
    end

    def public_ip_client
      @public_ip_client ||= Azure::Armrest::Network::IpAddressService.new(arm_api_configration)
    end

    def subscription_client
      @subscripiton_client ||= Azure::Armrest::SubscriptionService.new(arm_api_configration)
    end

    def availability_set_client
      @availability_set_client ||= Azure::Armrest::AvailabilitySetService.new(arm_api_configration)
    end
  end
end
