require "riak"
require "json"
require "cgi"
require "active_support/core_ext/time/conversions"
require "active_support/core_ext/numeric/time"

module RemoteStorage
  class Riak

    ::Riak.url_decoding = true

    attr_accessor :settings, :server, :cs_credentials

    def initialize(settings, server)
      self.settings = settings
      self.server = server

      credentials = File.read(settings['riak_cs']['credentials_file'])
      self.cs_credentials = JSON.parse(credentials)
    end

    def authorize_request(user, directory, token, listing=false)
      request_method = server.env["REQUEST_METHOD"]

      if directory.split("/").first == "public"
        return true if request_method == "GET" && !listing
      end

      authorizations = auth_bucket.get("#{user}:#{token}").data
      permission = directory_permission(authorizations, directory)

      server.halt 401 unless permission
      if ["PUT", "DELETE"].include? request_method
        server.halt 401 unless permission == "rw"
      end
    rescue ::Riak::HTTPFailedRequest
      server.halt 401
    end

    def get_data(user, directory, key)
      object = data_bucket.get("#{user}:#{directory}:#{key}")

      server.headers["Content-Type"] = object.content_type
      server.headers["Last-Modified"] = last_modified_date_for(object)
      server.headers["ETag"] = object.etag

      server.halt 304 if server.env["HTTP_IF_NONE_MATCH"] == object.etag

      if binary_key = object.meta["binary_key"]
        object = cs_binary_bucket.files.get(binary_key[0])

        case object.content_type[/^[^;\s]+/]
        when "application/json"
          return object.body.to_json
        else
          return object.body
        end
      end

      case object.content_type[/^[^;\s]+/]
      when "application/json"
        return object.data.to_json
      else
        return serializer_for(object.content_type) ? object.data : object.raw_data
      end
    rescue ::Riak::HTTPFailedRequest
      server.halt 404
    end

    def get_directory_listing(user, directory)
      directory_object = directory_bucket.get("#{user}:#{directory}")

      timestamp = directory_object.data.to_i
      timestamp /= 1000 if timestamp.to_s.length == 13
      server.headers["Content-Type"] = "application/json"
      server.headers["Last-Modified"] = Time.at(timestamp).to_s(:rfc822)
      server.headers["ETag"] = directory_object.etag

      server.halt 304 if server.env["HTTP_IF_NONE_MATCH"] == directory_object.etag

      listing = directory_listing(user, directory)

      return listing.to_json
    rescue ::Riak::HTTPFailedRequest
      server.halt 404
    end

    def put_data(user, directory, key, data, content_type=nil)
      object = build_data_object(user, directory, key, data, content_type)

      if required_match = server.env["HTTP_IF_MATCH"]
        server.halt 412 unless required_match == object.etag
      end

      object_exists = !object.raw_data.nil? || !object.meta["binary_key"].nil?
      existing_object_size = object_size(object)

      server.halt 412 if object_exists && server.env["HTTP_IF_NONE_MATCH"] == "*"

      timestamp = (Time.now.to_f * 1000).to_i
      object.meta["timestamp"] = timestamp

      if binary_data?(object.content_type, data)
        save_binary_data(object, data) or server.halt 422
        new_object_size = data.size
      else
        set_object_data(object, data) or server.halt 422
        new_object_size = object.raw_data.size
      end

      object.store

      log_count = object_exists ? 0 : 1
      log_operation(user, directory, log_count, new_object_size, existing_object_size)

      update_all_directory_objects(user, directory, timestamp)

      server.headers["ETag"] = object.etag
      server.halt object_exists ? 200 : 201
    rescue ::Riak::HTTPFailedRequest
      server.halt 422
    end

    def delete_data(user, directory, key)
      object = data_bucket.get("#{user}:#{directory}:#{key}")
      existing_object_size = object_size(object)
      etag = object.etag

      if required_match = server.env["HTTP_IF_MATCH"]
        server.halt 412 unless required_match == etag
      end

      if binary_key = object.meta["binary_key"]
        object = cs_binary_bucket.files.get(binary_key[0])
        object.destroy
      end

      riak_response = data_bucket.delete("#{user}:#{directory}:#{key}")

      if riak_response[:code] != 404
        log_operation(user, directory, -1, 0, existing_object_size)
      end

      timestamp = (Time.now.to_f * 1000).to_i
      delete_or_update_directory_objects(user, directory, timestamp)

      server.halt 200
    rescue ::Riak::HTTPFailedRequest
      server.halt 404
    end

    private

    def extract_category(directory)
      if directory.match(/^public\//)
        "public/#{directory.split('/')[1]}"
      else
        directory.split('/').first
      end
    end

    def build_data_object(user, directory, key, data, content_type=nil)
      object = data_bucket.get_or_new("#{user}:#{directory}:#{key}")

      object.content_type = content_type || "text/plain; charset=utf-8"

      directory_index = directory == "" ? "/" : directory
      object.indexes.merge!({:user_id_bin => [user],
                             :directory_bin => [directory_index]})

      object
    end

    def log_operation(user, directory, count, new_size=0, old_size=0)
      size = (-old_size + new_size)
      return if count == 0 && size == 0

      log_entry = opslog_bucket.new
      log_entry.content_type = "application/json"
      log_entry.data = {
        "count" => count,
        "size" => size,
        "category" => extract_category(directory)
      }
      log_entry.indexes.merge!({:user_id_bin => [user]})
      log_entry.store
    end

    def object_size(object)
      if binary_key = object.meta["binary_key"]
        response = cs_client.head_object cs_binary_bucket.key, binary_key[0]
        response.headers["Content-Length"].to_i
      else
        object.raw_data.nil? ? 0 : object.raw_data.size
      end
    end

    def escape(string)
      ::Riak.escaper.escape(string).gsub("+", "%20").gsub('/', "%2F")
    end

    # A URI object that can be used with HTTP backend methods
    def riak_uri(bucket, key)
      rc = settings.symbolize_keys
      URI.parse "http://#{rc[:host]}:#{rc[:http_port]}/riak/#{bucket}/#{key}"
    end

    def serializer_for(content_type)
      ::Riak::Serializers[content_type[/^[^;\s]+/]]
    end

    def last_modified_date_for(object)
      timestamp = object.meta["timestamp"]
      timestamp = (timestamp[0].to_i / 1000) if timestamp
      last_modified = timestamp ? Time.at(timestamp) : object.last_modified

      last_modified.to_s(:rfc822)
    end

    def directory_permission(authorizations, directory)
      authorizations = authorizations.map do |auth|
        auth.index(":") ? auth.split(":") : [auth, "rw"]
      end
      authorizations = Hash[*authorizations.flatten]

      permission = authorizations[""]

      authorizations.each do |key, value|
        if directory.match(/^(public\/)?#{key}(\/|$)/)
          if permission.nil? || permission == "r"
            permission = value
          end
          return permission if permission == "rw"
        end
      end

      permission
    end

    def directory_listing(user, directory)
      listing = {}

      sub_directories(user, directory).each do |entry|
        directory_name = entry["name"].split("/").last
        timestamp = entry["timestamp"].to_i
        etag = entry["etag"]

        listing.merge!({ "#{directory_name}/" => etag })
      end

      directory_entries(user, directory).each do |entry|
        entry_name = entry["name"]
        timestamp = if entry["timestamp"]
                      entry["timestamp"].to_i
                    else
                      DateTime.rfc2822(entry["last_modified"]).to_time.to_i
                    end
        etag = entry["etag"]

        listing.merge!({ entry_name => etag })
      end

      listing
    end

    def directory_entries(user, directory)
      all_keys = user_directory_keys(user, directory, data_bucket)
      return [] if all_keys.empty?

      map_query = <<-EOH
        function(v){
          keys = v.key.split(':');
          keys.splice(0, 2);
          key_name = keys.join(':');
          last_modified_date = v.values[0]['metadata']['X-Riak-Last-Modified'];
          timestamp = v.values[0]['metadata']['X-Riak-Meta']['X-Riak-Meta-Timestamp'];
          etag = v.values[0]['metadata']['X-Riak-VTag'];
          return [{
            name: key_name,
            last_modified: last_modified_date,
            timestamp: timestamp,
            etag: etag
          }];
        }
      EOH

      run_map_reduce(data_bucket, all_keys, map_query)
    end

    def sub_directories(user, directory)
      all_keys = user_directory_keys(user, directory, directory_bucket)
      return [] if all_keys.empty?

      map_query = <<-EOH
        function(v){
          keys = v.key.split(':');
          key_name = keys[keys.length-1];
          timestamp = v.values[0]['data'];
          etag = v.values[0]['metadata']['X-Riak-VTag'];
          return [{
            name: key_name,
            timestamp: timestamp,
            etag: etag
          }];
        }
      EOH

      run_map_reduce(directory_bucket, all_keys, map_query)
    end

    def user_directory_keys(user, directory, bucket)
      directory = "/" if directory == ""

      user_keys = bucket.get_index("user_id_bin", user)
      directory_keys = bucket.get_index("directory_bin", directory)

      user_keys & directory_keys
    end

    def run_map_reduce(bucket, keys, map_query)
      map_reduce = ::Riak::MapReduce.new(client)
      keys.each do |key|
        map_reduce.add(bucket.name, key)
      end

      map_reduce.
        map(map_query, :keep => true).
        run
    end

    def update_all_directory_objects(user, directory, timestamp)
      parent_directories_for(directory).each do |parent_directory|
        update_directory_object(user, parent_directory, timestamp)
      end
    end

    def update_directory_object(user, directory, timestamp)
      if directory.match(/\//)
        parent_directory = directory[0..directory.rindex("/")-1]
      elsif directory != ""
        parent_directory = "/"
      end

      directory_object = directory_bucket.new("#{user}:#{directory}")
      directory_object.content_type = "text/plain; charset=utf-8"
      directory_object.data = timestamp.to_s
      directory_object.indexes.merge!({:user_id_bin => [user]})
      if parent_directory
        directory_object.indexes.merge!({:directory_bin => [parent_directory]})
      end
      directory_object.store
    end

    def delete_or_update_directory_objects(user, directory, timestamp)
      parent_directories_for(directory).each do |parent_directory|
        existing_files = directory_entries(user, parent_directory)
        existing_subdirectories = sub_directories(user, parent_directory)

        if existing_files.empty? && existing_subdirectories.empty?
          directory_bucket.delete "#{user}:#{parent_directory}"
        else
          update_directory_object(user, parent_directory, timestamp)
        end
      end
    end

    def set_object_data(object, data)
      if object.content_type[/^[^;\s]+/] == "application/json"
        data = "{}" if data.blank?
        data = JSON.parse(data)
      end

      if serializer_for(object.content_type)
        object.data = data
      else
        object.raw_data = data
      end
    rescue JSON::ParserError
      return false
    end

    def save_binary_data(object, data)
      cs_binary_object = cs_binary_bucket.files.create(
        :key          => object.key,
        :body         => data,
        :content_type => object.content_type
      )

      object.meta["binary_key"] = cs_binary_object.key
      object.raw_data = ""
    end

    def binary_data?(content_type, data)
      return true if content_type[/[^;\s]+$/] == "charset=binary"

      original_encoding = data.encoding
      data.force_encoding("UTF-8")
      is_binary = !data.valid_encoding?
      data.force_encoding(original_encoding)

      is_binary
    end

    def parent_directories_for(directory)
      directories = directory.split("/")
      parent_directories = []

      while directories.any?
        parent_directories << directories.join("/")
        directories.pop
      end

      parent_directories << ""
    end

    def client
      @client ||= ::Riak::Client.new(:host      => settings['host'],
                                     :http_port => settings['http_port'])
    end

    def data_bucket
      @data_bucket ||= begin
                         bucket = client.bucket(settings['buckets']['data'])
                         bucket.allow_mult = false
                         bucket
                       end
    end

    def directory_bucket
      @directory_bucket ||= begin
                              bucket = client.bucket(settings['buckets']['directories'])
                              bucket.allow_mult = false
                              bucket
                            end
    end

    def auth_bucket
      @auth_bucket ||= begin
                         bucket = client.bucket(settings['buckets']['authorizations'])
                         bucket.allow_mult = false
                         bucket
                       end
    end

    def binary_bucket
      @binary_bucket ||= begin
                           bucket = client.bucket(settings['buckets']['binaries'])
                           bucket.allow_mult = false
                           bucket
                         end
    end

    def opslog_bucket
      @opslog_bucket ||= begin
                           bucket = client.bucket(settings['buckets']['opslog'])
                           bucket.allow_mult = false
                           bucket
                         end
    end

    def cs_client
      @cs_client ||= Fog::Storage.new({
        :provider                 => 'AWS',
        :aws_access_key_id        => cs_credentials['key_id'],
        :aws_secret_access_key    => cs_credentials['key_secret'],
        :endpoint                 => settings['riak_cs']['endpoint']
      })
    end

    def cs_binary_bucket
      @cs_binary_bucket ||= cs_client.directories.create(:key => settings['buckets']['cs_binaries'])
    end

  end
end
