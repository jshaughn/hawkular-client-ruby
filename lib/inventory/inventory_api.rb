require 'hawkular'

# Inventory module provides access to the Hawkular Inventory REST API.
# @see http://www.hawkular.org/docs/rest/rest-inventory.html
#
# @note While Inventory supports 'environments', they are not used currently
#   and thus set to 'test' as default value.
module Hawkular::Inventory
  # Client class to interact with Hawkular Inventory
  class InventoryClient < Hawkular::BaseClient
    # Create a new Inventory Client
    # @param entrypoint [String] base url of Hawkular-inventory - e.g
    #   http://localhost:8080/hawkular/inventory
    # @param credentials [Hash{String=>String}] Hash of username, password, token(optional)
    def initialize(entrypoint = nil, credentials = {})
      @entrypoint = entrypoint

      super(entrypoint, credentials)
    end

    # Retrieve the tenant id for the passed credentials.
    # If no credentials are passed, the ones from the constructor are used
    # @param credentials [Hash{String=>String}] Hash of username, password, token(optional)
    # @return [String] tenant id
    def get_tenant(credentials = {})
      creds = credentials.empty? ? @credentials : credentials
      auth_header = { Authorization: base_64_credentials(creds) }

      ret = http_get('/tenant', auth_header)

      ret['id']
    end

    # TODO: revisit and potentially move to Base ?
    def impersonate(credentials = {})
      @tenant = get_tenant(credentials)
      @options[:tenant] = @tenant
    end

    # List feeds in the system
    # @return [Array<String>] List of feed ids
    def list_feeds(_environment = 'test')
      ret = http_get('feeds')
      ret.map { |f| f['id'] }
    end

    # List resource types. If no need is given all types are listed
    # @param [String] feed The id of the feed the type lives under. Can be nil for feedless types
    # @return [Array<ResourceType>] List of types, that can be empty
    def list_resource_types(feed = nil)
      if feed.nil?
        ret = http_get('/resourceTypes')
      else
        the_feed = hawk_escape feed
        ret = http_get("/feeds/#{the_feed}/resourceTypes")
      end
      ret.map { |rt| ResourceType.new(rt) }
    end

    # Return all resources for a feed
    # @param [String] feed Id of the feed that hosts the resources
    # @param [Boolean] fetch_properties Should the config data be fetched too
    # @return [Array<Resource>] List of resources, which can be empty.
    def list_resources_for_feed(feed, fetch_properties = false)
      fail 'Feed must be given' unless feed
      the_feed = hawk_escape feed
      ret = http_get("/feeds/#{the_feed}/resources")
      ret.map do |r|
        if fetch_properties
          p = get_config_data_for_resource(r['id'], feed)
          r['properties'] = p['value']
        end
        Resource.new(r)
      end
    end

    # List the resources for the passed feed and resource type. The representation for
    # resources under a feed are sparse and additional data must be retrived separately.
    # It is possible though to also obtain runtime properties by setting #fetch_properties to true.
    # @param [String] feed The id of the feed the type lives under. Can be nil for all feeds
    # @param [String] type Name of the type to look for. Can be obtained from {ResourceType}.id.
    #   Must not be nil
    # @param [Boolean] fetch_properties Shall additional runtime properties be fetched?
    # @return [Array<Resource>] List of resources. Can be empty
    def list_resources_for_type(feed, type, fetch_properties = false)
      fail 'Type must not be nil' unless type
      the_type = hawk_escape type
      if feed.nil?
        ret = http_get("resourceTypes/#{the_type}/resources")
      else

        the_feed = hawk_escape feed
        ret = http_get("/feeds/#{the_feed}/resourceTypes/#{the_type}/resources")
      end
      ret.map do |r|
        if fetch_properties && !feed.nil?
          p = get_config_data_for_resource(r['id'], feed)
          r['properties'] = p['value']
        end
        Resource.new(r)
      end
    end

    # Retrieve runtime properties for the passed resource
    # @param [String] resource_id Id of the resource to read properties from
    # @param [String] feed Feed of the resource
    # @return [Hash<String,Object] Hash with additional data
    def get_config_data_for_resource(resource_id, feed)
      the_id = hawk_escape resource_id
      the_feed = hawk_escape feed
      query = generate_query_params dataType: 'configuration'
      http_get("feeds/#{the_feed}/resources/#{the_id}/data#{query}")
    rescue
      {}
    end

    # Obtain the child resources of the passed resource. In case of a WildFly server,
    # those would be Datasources, Deployments and so on.
    # @param [Resource] parent_resource Resource to obtain children from
    # @param [Boolean] recursive Whether to fetch also all the children of children of ...
    # @return [Array<Resource>] List of resources that are children of the given parent resource.
    #   Can be empty
    def list_child_resources(parent_resource, recursive = false)
      the_feed = hawk_escape parent_resource.feed
      the_id = hawk_escape parent_resource.id

      which_children = (recursive ? '/recursiveChildren' : '/children')
      ret = http_get("/feeds/#{the_feed}/resources/#{the_id}#{which_children}")
      ret.map { |r| Resource.new(r) }
    end

    # Obtain a list of relationships starting at the passed resource
    # @param [Resource] resource One end of the relationship
    # @param [String] named Name of the relationship
    # @return [Array<Relationship>] List of relationships
    def list_relationships(resource, named = nil)
      query = named.nil? ? '' : (generate_query_params named: named)
      ret = http_get("/path#{resource.path}/relationships#{query}")
      ret.map { |r| Relationship.new(r) }
    end

    # Obtain a list of relationships for the passed feed
    # @param [String] feed_id Id of the feed
    # @param [String] named Name of the relationship
    # @return [Array<Relationship>] List of relationships
    def list_relationships_for_feed(feed_id, named = nil)
      the_feed = hawk_escape feed_id
      query = named.nil? ? '' : (generate_query_params named: named)
      ret = http_get("/feeds/#{the_feed}/relationships#{query}")
      ret.map { |r| Relationship.new(r) }
    rescue
      []
    end

    # Retrieve a single entity from inventory by its canonical path
    # @param [CanonicalPath] path canonical path of the entity
    # @return inventory entity
    def get_entity(path)
      http_get("path#{path}")
    end

    # [15:01:51]  <jkremser>	pilhuhn, this works for me curl -XPOST
    #   -H "Content-Type: application/json"
    #   -u jdoe:password -d
    # '{"id" : "foo", "source": "/t;28026b36-8fe4-4332-84c8-524e173a68bf/f;localhost",
    # "target": "/t;28026b36-8fe4-4332-84c8-524e173a68bf/f;localhost/r;localhost~Local~~/
    #      r;localhost~Local~%2Fsubsystem=hawkular-bus-broker",
    # "name": "isRelatedTo"}'
    #    'http://localhost:8080/hawkular/inventory/feeds/localhost/relationships'
    #
    # def create_relationship(source_resource, target_resource, name, properties = {})
    #   rel = Relationship.new
    #   rel.source_id = source_resource.path
    #   rel.target_id = target_resource.path
    #   rel.name = name
    #   rel.properties = properties
    #
    #   http_post('/feeds/' + source_resource.feed + '/relationships',
    #             rel.to_h)
    # end

    # List the metrics for the passed feed and metric type. If feed is not passed,
    # all the metrics across all the feeds of a given type will be retrieved
    # This method may perform multiple REST calls.
    # @param [String] feed The id of the feed the type lives under. Can be nil for all feeds
    # @param [String] type Name of the metric type to look for. Can be obtained from {MetricType}.id.
    #   Must not be nil
    # @return [Array<Metric>] List of metrics. Can be empty
    def list_metrics_for_metric_type(feed, type)
      fail 'Type must not be nil' unless type
      the_type = hawk_escape type
      if feed.nil?
        type_hash = http_get("metricTypes/#{the_type}")
      else
        the_feed = hawk_escape feed
        type_hash = http_get("/feeds/#{the_feed}/metricTypes/#{the_type}")
      end

      rels = list_relationships(ResourceType.new(type_hash), 'defines')
      rels.map do |rel|
        path = CanonicalPath.parse(rel.target_id.to_s)
        metric_hash = get_entity path
        Metric.new(metric_hash)
      end
    rescue
      []
    end

    # List the metrics for the passed feed and all the resources of given resource type.
    # If feed is not passed, all the metrics across all the feeds of a resource type will be retrieved
    # This method may perform multiple REST calls.
    # @param [String] feed The id of the feed the type lives under. Can be nil for all feeds
    # @param [String] type Name of the resource type to look for. Can be obtained from {ResourceType}.id.
    #   Must not be nil
    # @return [Array<Metric>] List of metrics. Can be empty
    def list_metrics_for_resource_type(feed, type)
      fail 'Type must not be nil' unless type
      the_type = hawk_escape type
      if feed.nil?
        ret = http_get("resourceTypes/#{the_type}/resources")
      else
        the_feed = hawk_escape feed
        ret = http_get("feeds/#{the_feed}/resourceTypes/#{the_type}/resources")
      end
      ret.flat_map do |r|
        path = CanonicalPath.parse(r['path'])
        if !path.feed_id.nil?
          nested_ret = http_get("feeds/#{path.feed_id}/resources/#{path.resource_ids.join('/')}/metrics")
        else
          nested_ret = http_get("#{path.environment_id}/resources/#{path.resource_ids.join('/')}/metrics")
        end
        nested_ret.map { |m| Metric.new(m) }
      end
    end

    # List metric (definitions) for the passed resource. It is possible to filter down the
    #   result by a filter to only return a subset. The
    # @param [Resource] resource
    # @param [Hash{Symbol=>String}] filter for 'type' and 'match'
    #   Metric type can be one of 'GAUGE', 'COUNTER', 'AVAILABILITY'. If a key is missing
    #   it will not be used for filtering
    # @return [Array<Metric>] List of metrics that can be empty.
    # @example
    #    # Filter by type and match on metrics id
    #    client.list_metrics_for_resource(wild_fly, type: 'GAUGE', match: 'Metrics~Heap')
    #    # Filter by type only
    #    client.list_metrics_for_resource(wild_fly, type: 'COUNTER')
    #    # Don't filter, return all metric definitions
    #    client.list_metrics_for_resource(wild_fly)
    def list_metrics_for_resource(resource, filter = {})
      the_feed = hawk_escape resource.feed
      the_id = hawk_escape resource.id

      ret = http_get("/feeds/#{the_feed}/resources/#{the_id}/metrics")
      with_nils = ret.map do |m|
        metric_new = Metric.new(m)
        found = should_include?(metric_new, filter)
        metric_new if found
      end
      with_nils.compact
    end

    # Create a new feed
    # @param [String] feed_id  Id of a feed - required
    # @param [String] feed_name A display name for the feed
    # @return [Object]
    def create_feed(feed_id, feed_name = nil)
      feed = create_blueprint
      feed[:id] = feed_id
      feed[:name] = feed_name

      begin
        return http_post('/feeds/', feed)
      rescue HawkularException  => error
        # 409 We already exist -> that is ok
        if error.status_code == 409
          the_feed = hawk_escape feed_id
          http_get("/feeds/#{the_feed}")
        else
          raise
        end
      end
    end

    # Delete the feed with the passed feed id.
    # @param feed Id of the feed to be deleted.
    def delete_feed(feed)
      the_feed = hawk_escape feed
      http_delete("/feeds/#{the_feed}")
    end

    # Create a new resource type
    # @param [String] feed_id Id of the feed to add the type to
    # @param [String] type_id Id of the new type
    # @param [String] type_name Name of the type
    # @return [ResourceType] ResourceType object just created
    def create_resource_type(feed_id, type_id, type_name)
      the_feed = hawk_escape feed_id

      type = create_blueprint
      type[:id] = type_id
      type[:name] = type_name

      begin
        res = http_post("/feeds/#{the_feed}/resourceTypes", type)
      rescue HawkularException => error
        # 409 We already exist -> that is ok
        if error.status_code == 409
          the_type = hawk_escape type_id
          res = http_get("/feeds/#{the_feed}/resourceTypes/#{the_type}")
        else
          raise
        end
      end
      ResourceType.new(res)
    end

    # Create a resource of a given type under a given feed. To retrieve that resource
    # you need to call {#get_resource}
    # @param [String] feed_id Id of the feed to add the resource to
    # @param [String] type_path Path of the resource type of this resource
    # @param [String] resource_id Id of the resource
    # @param [String] resource_name Name of the resource
    # @param [Hash<String,Object>] properties Additional properties. Those are not the config-properties
    # TODO allow to create this as child of another resource
    def create_resource(feed_id, type_path, resource_id, resource_name = nil, properties = {})
      the_feed = hawk_escape feed_id

      res = create_blueprint
      res[:properties] = properties
      res[:id] = resource_id
      res[:name] = resource_name
      res[:resourceTypePath] = type_path

      begin
        http_post("/feeds/#{the_feed}/resources", res)
      rescue HawkularException => error
        # 409 We already exist -> that is ok
        raise unless error.status_code == 409
      end

      get_resource feed_id, resource_id, false
    end

    # Return the resource object for the passed id
    # @param [String] feed_id Id of the feed this resource belongs to
    # @param [String] res_id Id of the resource to fetch
    # @param [Boolean] fetch_resource_config Should the resource config data be fetched?
    def get_resource(feed_id, res_id, fetch_resource_config = true)
      the_feed = hawk_escape feed_id
      the_resource = hawk_escape res_id

      res = http_get("/feeds/#{the_feed}/resources/#{the_resource}")
      if fetch_resource_config
        p = get_config_data_for_resource(res_id, feed_id)
        res['properties'].merge p['value'] unless p['value'].nil?
      end
      Resource.new(res)
    end

    # Create a new metric type for a feed
    # @param [String] feed_id Id of the feed
    # @param [String] metric_type_id Id of the metric type to create
    # @param [String] type Type of the Metric. Allowed are GAUGE,COUNTER, AVAILABILITY
    # @param [String] unit Unit of the metric
    # @param [Numeric] collection_interval
    # @return [MetricType] Type just created or the one from the server if it already existed.
    def create_metric_type(feed_id, metric_type_id, type = 'GAUGE', unit = 'NONE', collection_interval = 60)
      the_feed = hawk_escape feed_id

      metric_kind = type.nil? ? 'GAUGE' : type.upcase
      fail "Unknown type #{metric_kind}" unless %w(GAUGE COUNTER AVAILABILITY').include?(metric_kind)

      mt = build_metric_type_hash(collection_interval, metric_kind, metric_type_id, unit)

      begin
        http_post("/feeds/#{the_feed}/metricTypes", mt)
      rescue HawkularException => error
        # 409 We already exist -> that is ok
        raise unless error.status_code == 409
      end

      res = http_get("/feeds/#{the_feed}/metricTypes/#{metric_type_id}")

      MetricType.new(res)
    end

    def build_metric_type_hash(collection_interval, metric_kind, metric_type_id, unit)
      mt = {}
      mt['id'] = metric_type_id
      mt['type'] = metric_kind
      mt['unit'] = unit.nil? ? 'NONE' : unit.upcase
      mt['collectionInterval'] = collection_interval.nil? ? 60 : collection_interval
      mt
    end

    # Create a Metric and associate it with a resource.
    # @param [String] feed_id Id of the feed
    # @param [String] metric_id Id of the metric
    # @param [String] type_path Full path of the MetricType
    # @param [String] resource_id Id of the resource to associate the metric with
    # @return [Metric] The metric created or if it already existed the version from the server
    def create_metric_for_resource(feed_id, metric_id, type_path, resource_id)
      the_feed = hawk_escape feed_id
      the_resource = hawk_escape resource_id

      m = {}
      m['id'] = metric_id
      m['metricTypePath'] = type_path

      begin
        http_post("/feeds/#{the_feed}/metrics", m)
      rescue HawkularException => error
        # 409 We already exist -> that is ok
        raise unless error.status_code == 409
      end

      ret = http_get("/feeds/#{the_feed}/metrics/#{metric_id}")
      the_metric = Metric.new(ret)

      begin
        http_post("/feeds/#{the_feed}/resources/#{the_resource}/metrics", [the_metric.path])
      rescue HawkularException => error
        # 409 We already exist -> that is ok
        raise unless error.status_code == 409
      end
      the_metric
    end

    private

    # Creates a hash with the fields required by the Blueprint api in Hawkular-Inventory
    def create_blueprint
      res = {}
      res[:properties] = {}
      res[:id] = nil
      res[:name] = nil
      res[:outgoing] = {}
      res[:incoming] = {}
      res
    end

    def should_include?(metric_new, filter)
      found = true
      if filter.empty?
        found = true
      else
        found = false unless filter[:type] == (metric_new.type) || filter[:type].nil?
        found = false unless filter[:match].nil? || metric_new.id.include?(filter[:match])
      end
      found
    end
  end

  # A ResourceType is like a class definition for {Resource}s
  # ResourceTypes are currently unique per feed, but one can assume
  # that a two types with the same name of two different feeds are
  # (more or less) the same.
  class ResourceType
    # @return [String] Full path of the type
    attr_reader :path
    # @return [String] Name of the type
    attr_reader :name
    # @return [String] Name of the type
    attr_reader :id
    # @return [String] Feed this type belongs to
    attr_reader :feed
    # @return [String] Environment this Type belongs to - currently unused
    attr_reader :env
    # @return [String] Properties of this type
    attr_reader :properties

    def initialize(rt_hash)
      @id = rt_hash['id']
      @path = rt_hash['path']
      @name = rt_hash['name'] || rt_hash['id']
      @properties = rt_hash['properties']
      @_hash = rt_hash.dup

      return if @path.nil?

      tmp = @path.split('/')
      tmp.each do |pair|
        (key, val) = pair.split(';')
        case key
        when 'f'
          @feed = val
        when 'e'
          @env = val
        end
      end
    end

    # Returns a hash representation of the resource type
    # @return [Hash<String,Object>] hash of the type
    def to_h
      @_hash.dup
    end
  end

  # A Resource is an instantiation of a {ResourceType}
  class Resource
    # @return [String] Full path of the resource including feed id
    attr_reader :path
    # @return [String] Name of the resource
    attr_reader :name
    # @return [String] Name of the resource
    attr_reader :id
    # @return [String] Name of the feed for this resource
    attr_reader :feed
    # @return [String] Name of the environment for this resource -- currently unused
    attr_reader :env
    # @return [String] Full path of the {ResourceType}
    attr_reader :type_path
    # @return [Hash<String,Object>] Hash with additional, resource specific properties
    attr_reader :properties

    def initialize(res_hash)
      @id = res_hash['id']
      @path = res_hash['path']
      @properties = res_hash['properties'] || {}
      @type_path = res_hash['type']['path']
      @_hash = res_hash

      tmp = @path.split('/')
      tmp.each do |pair|
        (key, val) = pair.split(';')
        case key
        when 'f'
          @feed = val
        when 'e'
          @env = val
        when 'r'
          @name = val.nil? ? id : val
        end
      end
      self
    end

    def to_h
      @_hash.deep_dup
    end
  end

  class MetricType
    # @return [String] Full path of the metric (type)
    attr_reader :path
    # @return [String] Name of the metric
    attr_reader :name
    attr_reader :id
    attr_reader :feed
    attr_reader :unit
    # @return [Long] collection interval in seconds
    attr_reader :collection_interval

    def initialize(type_hash)
      @id = type_hash['id']
      @path = type_hash['path']
      @name = type_hash['name'] || @id
      @_hash = type_hash.dup

      tmp = path.split('/')
      tmp.each do |pair|
        (key, val) = pair.split(';')
        case key
        when 'f'
          @feed = val
        when 'e'
          @env = val
        when 'n'
          @name = val.nil? ? id : val
        end
      end
      @type = type_hash['type']
      @unit = type_hash['unit']
      @collection_interval = type_hash['collectionInterval']
    end
  end

  # Definition of a Metric inside the inventory.
  class Metric
    # @return [String] Full path of the metric (definition)
    attr_reader :path
    # @return [String] Name of the metric
    attr_reader :name
    attr_reader :id
    attr_reader :feed
    attr_reader :env
    attr_reader :type
    attr_reader :unit
    # @return [Long] collection interval in seconds
    attr_reader :collection_interval

    def initialize(metric_hash)
      @id = metric_hash['id']
      @path = metric_hash['path']
      @name = metric_hash['name'] || @id
      @_hash = metric_hash.dup

      tmp = path.split('/')
      tmp.each do |pair|
        (key, val) = pair.split(';')
        case key
        when 'f'
          @feed = val
        when 'e'
          @env = val
        when 'm'
          @name = val.nil? ? id : val
        end
      end
      @type = metric_hash['type']['type']
      @unit = metric_hash['type']['unit']
      @collection_interval = metric_hash['collectionInterval']
    end

    def to_h
      @_hash.dup
    end
  end

  # Definition of a Relationship between two entities in Inventory
  class Relationship
    attr_accessor :source_id
    attr_reader :target_id
    attr_reader :properties
    attr_reader :name
    attr_reader :id

    def initialize(hash = {})
      if hash.empty?
        @properties = {}
        return
      end

      @source_id = hash['source']
      @target_id = hash['target']
      @properties = hash['properties']
      @name = hash['name']
      @id = hash['id']
    end

    def to_h
      hash = {}
      hash['source'] = @source_id
      hash['target'] = @target_id
      hash['properties'] = @properties
      hash['name'] = @name
      hash['id'] = @id
      hash
    end
  end

  class CanonicalPath
    attr_reader :tenant_id
    attr_reader :feed_id
    attr_reader :environment_id
    attr_reader :resource_ids
    attr_reader :metric_id
    attr_reader :resource_type_id
    attr_reader :metric_type_id

    def initialize(hash)
      fail 'At least tenant_id must be specified' if hash[:tenant_id].to_s.strip.length == 0
      @tenant_id = hash[:tenant_id]
      @feed_id = hash[:feed_id]
      @environment_id = hash[:environment_id]
      @resource_type_id = hash[:resource_type_id]
      @metric_type_id = hash[:metric_type_id]
      @resource_ids = hash[:resource_ids]
      @metric_id = hash[:metric_id]
    end

    # rubocop:disable Metrics/CyclomaticComplexity
    def self.parse(path)
      fail 'CanonicalPath must not be nil or emtpy' if path.to_s.strip.length == 0
      tmp = path.split('/')
      hash = {}
      tmp.each do |pair|
        (key, val) = pair.split(';')
        case key
        when 't'
          hash[:tenant_id] = val
        when 'f'
          hash[:feed_id] = val
        when 'e'
          hash[:environment_id] = val
        when 'm'
          hash[:metric_id] = val
        when 'r'
          hash[:resource_ids] = [] if hash[:resource_ids].nil?
          hash[:resource_ids].push(val)
        when 'mt'
          hash[:metric_type_id] = val
        when 'rt'
          hash[:resource_type_id] = val
        end
      end
      CanonicalPath.new(hash)
    end
    # rubocop:enable Metrics/CyclomaticComplexity

    def ==(other)
      self.eql?(other) || other.class == self.class && other.state == state
    end

    def to_s
      ret = "/t;#{@tenant_id}"
      ret += "/f;#{@feed_id}" unless @feed_id.nil?
      ret += "/e;#{@environment_id}" unless @environment_id.nil?
      ret += "/rt;#{@resource_type_id}" unless @resource_type_id.nil?
      ret += "/mt;#{@metric_type_id}" unless @metric_type_id.nil?
      ret += "/m;#{@metric_id}" unless @metric_id.nil?
      ret += resources_chunk.to_s
      ret
    end

    protected

    def state
      [@tenant_id, @feed_id, @environment_id, @resource_ids, @metric_id, @metric_type_id, @resource_type_id]
    end

    private

    def resources_chunk
      @resource_ids.map { |r| "/r;#{r}" }.join unless @resource_ids.nil?
    end
  end
end
