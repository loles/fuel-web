#    Copyright 2013 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

require 'naily/reporter'
require 'softlayer_api'

module Naily
  class Dispatcher
    def initialize(producer)
      @orchestrator = Astute::Orchestrator.new(nil, log_parsing=true)
      @producer = producer
      @provisionLogParser = Astute::LogParser::ParseProvisionLogs.new
    end

    def echo(args)
      Naily.logger.info 'Running echo command'
      args
    end

    def download_release(data)
      # Example of message = {
      # {'method': 'download_release',
      # 'respond_to': 'download_release_resp',
      # 'args':{
      #     'task_uuid': 'task UUID',
      #     'release_info':{
      #         'release_id': 'release ID',
      #         'redhat':{
      #             'license_type' :"rhn" or "rhsm",
      #             'username': 'username',
      #             'password': 'password',
      #             'satellite': 'satellite host (for RHN license)'
      #             'activation_key': 'activation key (for RHN license)'
      #         }
      #     }
      # }}
      Naily.logger.info("'download_release' method called with data: #{data.inspect}")
      reporter = Naily::Reporter.new(@producer, data['respond_to'], data['args']['task_uuid'])
      release_info = data['args']['release_info']['redhat']
      begin
        result = @orchestrator.download_release(reporter, data['args']['task_uuid'], release_info)
      rescue Timeout::Error
        msg = "Timeout of release download is exceeded."
        Naily.logger.error msg
        reporter.report({'status' => 'error', 'error' => msg})
        return
      end
    end

    def check_redhat_credentials(data)
      release = data['args']['release_info']
      task_id = data['args']['task_uuid']
      reporter = Naily::Reporter.new(@producer, data['respond_to'], task_id)
      @orchestrator.check_redhat_credentials(reporter, task_id, release)
    end

    def check_redhat_licenses(data)
      release = data['args']['release_info']
      nodes = data['args']['nodes']
      task_id = data['args']['task_uuid']
      reporter = Naily::Reporter.new(@producer, data['respond_to'], task_id)
      @orchestrator.check_redhat_licenses(reporter, task_id, release, nodes)
    end

    def provision(data)
      Naily.logger.info("'provision' method called with data: #{data.inspect}")

      reporter = Naily::Reporter.new(@producer, data['respond_to'], data['args']['task_uuid'])
      begin
        @orchestrator.provision(reporter,
                                data['args']['provisioning_info']['engine'],
                                data['args']['provisioning_info']['nodes'])
      rescue => e
        Naily.logger.error "Error running provisioning: #{e.message}, trace: #{e.backtrace.inspect}"
        raise StopIteration
      end

      @orchestrator.watch_provision_progress(
        reporter, data['args']['task_uuid'], data['args']['provisioning_info']['nodes'])
    end

    def deploy(data)
      Naily.logger.info("'deploy' method called with data: #{data.inspect}")

      reporter = Naily::Reporter.new(@producer, data['respond_to'], data['args']['task_uuid'])
      begin
        @orchestrator.deploy(reporter, data['args']['task_uuid'], data['args']['deployment_info'])
        reporter.report('status' => 'ready', 'progress' => 100)
      rescue Timeout::Error
        msg = "Timeout of deployment is exceeded."
        Naily.logger.error msg
        reporter.report('status' => 'error', 'error' => msg)
      end
    end

    def verify_networks(data)
      reporter = Naily::SubtaskReporter.new(@producer, data['respond_to'], data['args']['task_uuid'], data['subtasks'])
      result = @orchestrator.verify_networks(reporter, data['args']['task_uuid'], data['args']['nodes'])
      report_result(result, reporter)
    end

    def dump_environment(data)
      task_id = data['args']['task_uuid']
      reporter = Naily::Reporter.new(@producer, data['respond_to'], task_id)
      @orchestrator.dump_environment(reporter, task_id, data['args']['lastdump'])
    end

    def remove_nodes(data)
      task_uuid = data['args']['task_uuid']
      reporter = Naily::Reporter.new(@producer, data['respond_to'], task_uuid)
      nodes = data['args']['nodes']
      provision_engine = Astute::Provision::Cobbler.new(data['args']['engine'])
      data['args']['engine_nodes'].each do |name|
        if provision_engine.system_exists(name)
          Naily.logger.info("Removing system from cobbler: #{name}")
          provision_engine.remove_system(name)
          if not provision_engine.system_exists(name)
            Naily.logger.info("System has been successfully removed from cobbler: #{name}")
          else
            Naily.logger.error("Cannot remove node from cobbler: #{name}")
          end
        else
          Naily.logger.info("System is not in cobbler: #{name}")
        end
      end
      Naily.logger.debug("Cobbler syncing")
      provision_engine.sync

      result = nil
      if nodes.empty?
        Naily.logger.debug("#{task_uuid} Node list is empty")
      else
        nodes = mark_sl_nodes(nodes)
        sl_nodes = nodes.map{|node| node if node['sl_id']}.compact
        normal_nodes = nodes - sl_nodes
        result = @orchestrator.remove_nodes(reporter, data['args']['task_uuid'], normal_nodes)
        #TODO move it to astute code
        Naily.logger.info("Removing SL nodes.")
        sl_result = reload_sl_nodes(sl_nodes, {'master_ip' => data['args']['master_ip']})
        result = merge_results(result, sl_result)
      end

      report_result(result, reporter)
    end

    private

    def report_result(result, reporter)
      result = {} unless result.instance_of?(Hash)
      status = {'status' => 'ready', 'progress' => 100}.merge(result)
      reporter.report(status)
    end

    def mark_sl_nodes(nodes)
        if(Naily.config.sl_api_username and Naily.config.sl_api_key)
            hs = SoftLayer::Service.new('SoftLayer_Hardware_Server',
                                  :username => Naily.config.sl_api_username,
                                  :api_key => Naily.config.sl_api_key)
            nodes.each do |node|
                Naily.logger.info("Searching for node with IP: " + node['ip'])
                sl_node = hs.findByIpAddress(node['ip'])
                if (sl_node)
                    Naily.logger.info("Node found")
                    node['sl_id'] = sl_node['id']
                end
            end
        else
            Naily.logger.info("No softlayer config.")
        end
        return nodes
    end

    def reload_sl_nodes(nodes, configuration)
        hs = SoftLayer::Service.new('SoftLayer_Hardware_Server',
                                  :username => Naily.config.sl_api_username,
                                  :api_key => Naily.config.sl_api_key)
        error_nodes = Astute::NodesHash.new
        erased_nodes = Astute::NodesHash.new
        custom_configuration = {
               'customProvisionScriptUri'=> "https://#{configuration['master_ip']}/bootstrap.sh"
               }
        nodes.each do |node|
            begin
                hs.object_with_id(node['sl_id']).reloadOperatingSystem('FORCE', custom_configuration)
                Naily.logger.info("Removing node #{node['sl_id']}")
            rescue SoftLayer::SoftLayerAPIException => e
                if(e.message != 'There is currently an outstanding transaction for this server')
                    node['error'] = "SoftLayer API error: #{e.message}"
                    error_nodes << node
                    next
                end
            end
            erased_nodes << node
        end
        answer = {'nodes' => erased_nodes.nodes.map(&:to_hash)}
        unless error_nodes.empty?
            answer.merge!({'error_nodes' => error_nodes.nodes.map(&:to_hash), 'status' => 'error'})
        end
        return answer
    end

    def merge_results(result, sl_result)
        result['nodes'] += sl_result['nodes']
        if(sl_result['status'] and sl_result['status'] == 'error')
                if(result['error_nodes'])
                    result['error_nodes'] += sl_result['error_nodes']
                else
                    result['error_nodes'] = sl_result['error_nodes']
                end
            result['status'] = 'error'
        end
        result
    end
  end
end
