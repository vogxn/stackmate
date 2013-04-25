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
require 'yaml'

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
  def initialize()
    super
    @localized = {}
    load_local_mappings()
  end

  def on_workitem
    myname = workitem.participant_name
    p myname
    resolved = workitem.fields['ResolvedNames']
    resolved['AWS::StackId'] = workitem.fei.wfid #TODO put this at launch time
    props = workitem.fields['Resources'][workitem.participant_name]['Properties']
    security_group_names = []
    props['SecurityGroups'].each do |sg| 
        sg_name = resolved[sg['Ref']]
        security_group_names << sg_name
    end
    keypair = resolved[props['KeyName']['Ref']] if props['KeyName']
    userdata = nil
    if props['UserData']
        userdata = user_data(props['UserData'], resolved)
    end
    templateid = image_id(props['ImageId'], resolved, workitem.fields['Mappings'])
    templateid = @localized['templates'][templateid] if @localized['templates']
    svc_offer = resolved[props['InstanceType']['Ref']]  #TODO fragile
    svc_offer = @localized['service_offerings'][svc_offer] if @localized['service_offerings']
    args = { 'serviceofferingid' => svc_offer,
             'templateid' => templateid,
             'zoneid' => default_zone_id,
             'securitygroupnames' => security_group_names.join(','),
             'displayname' => myname,
             #'name' => myname
    }
    args['keypair'] = keypair if keypair
    args['userdata'] = userdata  if userdata
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

  def load_local_mappings()
      begin
          @localized = YAML.load_file('local.yaml')
      rescue
          print "Warning: Failed to load localized mappings from local.yaml\n"
      end
  end

  def default_zone_id
      '1'
  end

  def image_id(imgstring, resolved, mappings)
      #TODO convoluted logic only handles the cases
      #ImageId : {"Ref" : "FooBar"}
      #ImageId :  { "Fn::FindInMap" : [ "Map1", { "Ref" : "OuterKey" },
      #                          { "Fn::FindInMap" : [ "Map2", { "Ref" : "InnerKey" }, "InnerVal" ] } ] },
      #ImageId :  { "Fn::FindInMap" : [ "Map1", { "Ref" : "Key" },  "Value" ] } ] },
      if imgstring['Ref']
          return resolved[imgstring['Ref']]
      else 
          if imgstring['Fn::FindInMap']
              key = resolved[imgstring['Fn::FindInMap'][1]['Ref']]
              #print "Key = ", key, "\n"
              if imgstring['Fn::FindInMap'][2]['Ref']
                  val = resolved[imgstring['Fn::FindInMap'][2]['Ref']]
                  #print "Val [Ref] = ", val, "\n"
              else
                  if imgstring['Fn::FindInMap'][2]['Fn::FindInMap']
                      val = image_id(imgstring['Fn::FindInMap'][2], resolved, mappings)
                      #print "Val [FindInMap] = ", val, "\n"
                  else
                      val = imgstring['Fn::FindInMap'][2]
                  end
              end
          end
          return mappings[imgstring['Fn::FindInMap'][0]][key][val]
      end
  end

end

class WaitConditionHandle < Ruote::Participant
  def on_workitem
    myname = workitem.participant_name
    p myname
    presigned_url = 'http://localhost:4567/waitcondition/' + workitem.fei.wfid + '/' + myname
    workitem.fields['ResolvedNames'][myname] = presigned_url
    print "Your pre-signed URL is: ", presigned_url, "\n"
    print "Try: curl -X PUT --data 'foo' ", presigned_url,  "\n"
    WaitCondition.create_handle(myname, presigned_url)

    reply
  end
end

class WaitCondition < Ruote::Participant
  @@handles = {}
  @@conditions = []
  def on_workitem
    p workitem.participant_name
    @@conditions << self
    @wi = workitem
  end

  def self.create_handle(handle_name, handle)
      @@handles[handle_name] = handle
  end

  def set_handle(handle_name)
      reply(@wi) if @@handles[handle_name]
  end

  def self.get_conditions()
      @@conditions
  end
end

class SecurityGroup < CloudStackResource
  def on_workitem
    myname = workitem.participant_name
    p myname
    resolved = workitem.fields['ResolvedNames']
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
