module Bosh::Director
  module Jobs
    class DeleteDeployment < BaseJob
      include LockHelper

      @queue = :normal

      def self.job_type
        :delete_deployment
      end

      def initialize(deployment_name, options = {})
        @deployment_name = deployment_name
        @force = options['force']
        @keep_snapshots = options['keep_snapshots']
        @deployment_manager = Api::DeploymentManager.new
      end

      def perform
        logger.info("Deleting: #{@deployment_name}")
        parent_id = add_event
        with_deployment_lock(@deployment_name) do
          deployment_model = @deployment_manager.find_by_name(@deployment_name)

          fail_if_ignored_instances_found(deployment_model)

          # IP Provider is never used by the instance deleter in this case
          # We also don't have access to the networks to properly instantiate one
          ip_provider = DeploymentPlan::IpProvider.new(nil, nil, logger)

          powerdns_manager = PowerDnsManagerProvider.create
          disk_manager = DiskManager.new(logger)
          instance_deleter = InstanceDeleter.new(
            ip_provider,
            powerdns_manager,
            disk_manager,
            force: @force,
            stop_intent: :delete_deployment,
          )
          deployment_deleter = DeploymentDeleter.new(Config.event_log, logger, powerdns_manager, Config.max_threads)

          vm_deleter = Bosh::Director::VmDeleter.new(logger, @force, Config.enable_virtual_delete_vms)
          deployment_deleter.delete(deployment_model, instance_deleter, vm_deleter)
          add_event(parent_id)

          "/deployments/#{@deployment_name}"
        end
      rescue Exception => e
        add_event(parent_id, e)
        raise e
      end

      private

      def add_event(parent_id = nil, error = nil)
        event = event_manager.create_event(
          parent_id:   parent_id,
          user:        username,
          action:      'delete',
          object_type: 'deployment',
          object_name: @deployment_name,
          deployment:  @deployment_name,
          task:        task_id,
          error:       error,
        )
        event.id
      end

      def fail_if_ignored_instances_found(deployment_model)
        deployment_model.instances.each do |instance_model|
          if instance_model.ignore
            raise DeploymentIgnoredInstancesDeletion, "You are trying to delete deployment '#{deployment_model.name}', which " \
                'contains ignored instance(s). Operation not allowed.'
          end
        end
      end
    end
  end
end
