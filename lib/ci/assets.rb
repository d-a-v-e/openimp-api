module CI
  class Error < Exception
    def self.json_create properties
      raise new(properties["errormessage"])
    end

    [:PermissionDenied, :NotImplemented, :Conflict, :BadParameters, :NotFound].each do |error|
      class_eval <<-CLASS
        class #{error} < Error
        end
      CLASS
    end
  end

  # The +Asset+ class defines the core features of server-side objects, including the ability to autoinstantiate them
  # from _JSON_ for transport across the network.
  class Asset
    # Simple implementation of a +class inheritable accessor+.
    def self.class_inheritable_accessor *args
      args.each do |arg|
        class_eval <<-METHODS
          def self.#{arg}
            @#{arg} ||= superclass.#{arg} unless self == CI::Asset
          end 

          def self.#{arg}=(val)
            @#{arg}=val
          end
        METHODS
      end
    end
 
    # should return a list of path components for (if no instance given) the base URL for the object type, otherwise the base URL for the instance given
    def self.path_components(instance=nil)
      raise NotImplemented, "You need to override CI::Asset.path_components"
    end

    def self.list
      MediaFileServer.get(path_components + ['list'])
    end

    # A +meta programming helper method+ which converts an MFS attribute into more manageable forms.
    def self.with_api_attributes *attributes
      Array.new(attributes).each do |api_attribute|
        yield api_attribute.to_method_name, api_attribute.to_sym
      end
    end

    # equality based on the path_components (the URL is necessarily a unique identifier for a resource within the API)
    def ==(other)
      super or (other.instance_of?(self.class) && path_components && path_components == other.path_components)
    end
    def hash; path_components.hash; end
    alias :eql? :==

    # Defines an MFS attribute present on the current class and creates accessor methods for manupulating it.
    def self.attributes *attributes #:nodoc:
      with_api_attributes(*attributes) do |ruby_method, api_key|
        define_method(ruby_method) do
          # For attributes which expose only a representation we support lazy loading
          result = @parameters[api_key]
          if result.is_a?(Hash) && (url = result["__REPRESENTATION__"])
            path_components = url.sub(/^\//,'').split('/')
            @parameters[api_key] = MediaFileServer.get(path_components)
          else
            result
          end
        end
        define_method("#{ruby_method}=") { |value| @parameters[api_key] = value }
      end
    end

    # Defines an MFS attribute as representing a collection of one or more server-side objects and creates
    # accessor methods for manipulating it.
    def self.collections *attributes
      with_api_attributes(*attributes) do |ruby_method, api_key|
        define_method(ruby_method) { @parameters[api_key] || [] }
        define_method("#{ruby_method}=") do |values|
          @parameters[api_key] = values.map { |v| v.respond_to?(:has_key?) ? Asset.create(v) : v }
        end
      end
    end

    class << self
      alias :json_create :new

      def find(parameters)
        stub = new(parameters)
        path = stub.path_components
        raise "Insufficient attributes were passed to CI::Asset.find to generate a URL" unless path
        MediaFileServer.get(path)
      end
      
      def find_or_new(parameters)
        find(parameters) || new(parameters)
      end
    end

    def initialize parameters = {}
      @parameters = {}
      parameters.delete('__CLASS__')

      representation = parameters.delete('__REPRESENTATION__')
      @path_components = representation.sub(/^\//,'').split('/') if representation

      parameters.each do |k, v|
        setter = "#{k.to_method_name}="
        send(setter, v) if respond_to?(setter)
      end
    end

    def path_components(*args)
      components = if defined?(@path_components)
        @path_components
      else
        @path_components = self.class.path_components(self) and @path_components.map! {|c| c.to_s} # we normalise this to a string representation for comparison purposes
      end
      components && components + args
    end

    def to_json *a
      result = {'__CLASS__' => self.class.name.sub(/CI::/i, 'MFS::')}
      parameters.each do |k,v|
        result[k] = case v
        # the CI API needs 0/1 instead of the normal json true/false. apparently.
        when true then 1
        when false then 0
        else v
        end
      end
      result.to_json(*a)
    end

    [:get, :get_octet_stream, :head, :delete].each do |m|
      class_eval <<-METHOD
        def #{m} action = nil
          MediaFileServer.#{m}(path_components(action))
        end
      METHOD
    end

    def post properties, action = nil, headers = {}
      MediaFileServer.post(path_components(action), properties, headers)
    end

    def multipart_post
      MediaFileServer.multipart_post(path_components || self.class.path_components) {|url| yield url}
    end

    def put content_type, data
      MediaFileServer.put(path_components, content_type, data)
    end
    
    def reload
      pc = path_components() or raise "Insufficient attributes were defined to generate a URL in order to reload"
      MediaFileServer.get(pc)
    end
    
    def reload!
      replace_with!(reload)
    end

  protected
    def replace_with! asset
      @parameters = asset.parameters
      @path_components = asset.path_components
      self
    end

    def parameters
      @parameters.clone
    end
  end


  module Metadata
    # An +Encoding+ describes the audio codec associated with a server-side audio file.
    class Encoding < Asset
      attributes    :Name, :Codec, :Family, :PreviewLength, :Channels, :Bitrate, :Description
      @@encodings = nil

      def self.path_components(instance=nil)
        if instance
          ['encoding', instance.name] if instance.name
        else
          ['encoding']
        end
      end

      def self.synchronize
        @@encodings = MediaFileServer.get(path_components)
      end

      def self.encodings
        @@encodings.dup rescue nil
      end
    end
  end

  # A +ContextualMethod+ is a method call avaiable on a server-side object.
  class ContextualMethod < Asset
  end
end