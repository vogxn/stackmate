require 'rufus-json/automatic'
require 'ruote'
require 'ruote/storage/fs_storage'
require 'json'
require 'cloudstack_ruby_client'
require 'set'
require 'tsort'
require 'SecureRandom'
require 'optparse'
require 'Base64'

class CloudStackResource < Ruote::Participant
  def initialize()
      @url = ENV['URL']
      @apikey = ENV['APIKEY']
      @seckey = ENV['SECKEY']
      @client = CloudstackRubyClient::Client.new(@url, @apikey, @seckey, false)
  end
  def on_workitem
    p workitem.participant_name
    reply
  end
end

class Instance < CloudStackResource
  def on_workitem
    myname = workitem.participant_name
    p myname
    resolved = workitem.fields['ResolvedNames']
    sleep(rand)
    props = workitem.fields['Resources'][workitem.participant_name]['Properties']
    security_group_names = []
    props['SecurityGroups'].each do |sg| 
        sg_name = resolved[sg['Ref']]
        security_group_names << sg_name
    end
    keypair = nil
    if props['KeyName']
        keypair = resolved[props['KeyName']['Ref']]
    end
    userdata = nil
    if props['UserData']
        userdata = user_data(props['UserData'], resolved)
    end
    args = { 'serviceofferingid' => '13954c5a-60f5-4ec8-9858-f45b12f4b846',
             'templateid' => '7fc2c704-a950-11e2-8b38-0b06fbda5106',
             'zoneid' => default_zone_id,
             'securitygroupnames' => security_group_names.join(','),
             'displayname' => myname,
             #'name' => myname
    }
    if keypair
        args['keypair'] = keypair
    end
    if userdata
        args['userdata'] = userdata 
        p userdata
    end

    @client.deployVirtualMachine(args)
    reply
  end

  def user_data(datum, resolved)
      #TODO make this more general purpose
      actual = datum['Fn::Base64']['Fn::Join']
      delim = actual[0]
      data = actual[1].map { |d|
          d.kind_of?(Hash) ? resolved[d['Ref']]: d
      }
      Base64.urlsafe_encode64(data.join(delim))

  end

  def default_zone_id
      '1'
  end

  def default_zone_id
      '1'
  end
end

class WaitConditionHandle < Ruote::Participant
  def on_workitem
    sleep(rand)
    p workitem.participant_name
    reply
  end
end

class WaitCondition < Ruote::Participant
  def on_workitem
    sleep(rand)
    p workitem.participant_name
    reply
  end
end

class SecurityGroup < CloudStackResource
  def on_workitem
    myname = workitem.participant_name
    p myname
    resolved = workitem.fields['ResolvedNames']
    sleep(rand)
    props = workitem.fields['Resources'][myname]['Properties']
    name = workitem.fields['StackName'] + '-' + workitem.participant_name;
    resolved[myname] = name
    args = { 'name' => name,
             'description' => props['GroupDescription']
    }
    @client.createSecurityGroup(args)
    props['SecurityGroupIngress'].each do |rule|
        cidrIp = rule['CidrIp']
        if cidrIp.kind_of?  Hash
            #TODO: some sort of validation
            cidrIpName = cidrIp['Ref']
            cidrIp = resolved[cidrIpName]
        end
        args = { 'securitygroupname' => name,
            'startport' => rule['FromPort'],
            'endport' => rule['ToPort'],
            'protocol' => rule['IpProtocol'],
            'cidrlist' => cidrIp
        }
        #TODO handle usersecuritygrouplist
        @client.authorizeSecurityGroupIngress(args)
    end
    reply
  end
end

class Output < Ruote::Participant
  def on_workitem
    #p workitem.fields.keys
    p workitem.participant_name
    p "Done"
    reply
  end
end

