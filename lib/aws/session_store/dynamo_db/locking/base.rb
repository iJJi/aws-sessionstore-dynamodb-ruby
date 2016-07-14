# Copyright 2013 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
#     http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.


module Aws::SessionStore::DynamoDB::Locking
  # This class provides a framework for implementing
  # locking strategies.
  class Base

    # Creates configuration object.
    def initialize(cfg)
      @config = cfg
    end

    # Updates session in database
    def set_session_data(env, sid, session, options = {})
      return false if session.empty?
      return sid if options.empty? && data_unchanged?(env,pack_data(session))
      handle_error(env) do
        save_opts = update_opts(env, sid, session, options)
        result = @config.dynamo_db_client.update_item(save_opts)
        sid
      end
    end

    # Packs session data.
    def pack_data(data)
      [Marshal.dump(data)].pack("m*")
    end

    # Gets session data.
    def get_session_data(env, sid)
      raise NotImplementedError
    end

    # Deletes session based on id
    def delete_session(env, sid)
      handle_error(env) do
        @config.dynamo_db_client.delete_item(delete_opts(sid))
      end
    end

    # Each database operation is placed in this rescue wrapper.
    # This wrapper will call the method, rescue any exceptions and then pass
    # exceptions to the configured error handler.
    def handle_error(env = nil, &block)
      begin
        yield
      rescue Aws::Errors::ServiceError => e
        @config.error_handler.handle_error(e, env)
      end
    end

    private

    # @return [Hash] Options for deleting session.
    def delete_opts(sid)
      merge_all(table_opts(sid))
    end

    # @return [Hash] Options for updating item in Session table.
    def update_opts(env, sid, session, options = {})
      if env['dynamo_db.new_session']
        updt_options = save_new_opts(env, sid, session)
      else
        updt_options = save_exists_opts(env, sid, session, options)
      end
      updt_options
    end

    # @return [Hash] Options for saving a new session in database.
    def save_new_opts(env, sid, session)
      attribute_opts = attr_updts(env, session, created_attr)
      merge_all(table_opts(sid), attribute_opts)
    end

    # @return [Hash] Options for saving an existing sesison in the database.
    def save_exists_opts(env, sid, session, options = {})
      add_attr = options[:add_attrs] || {}
      expected = options[:expect_attr] || {}
      attribute_opts = merge_all(attr_updts(env, session, add_attr), expected)
      merge_all(table_opts(sid), attribute_opts)
    end

    # Unmarshal the data.
    def unpack_data(packed_data)
      return {} if packed_data.nil?
      Marshal.load(packed_data.unpack("m*").first)
    end

    # Table options for client.
    def table_opts(sid)
      {
        :table_name => @config.table_name,
        :key => {@config.table_key => sid}
      }
    end

    # Attributes to update via client.
    def attr_updts(env, session, add_attrs = {})
      packed_session = pack_data(session)
      data = data_unchanged?(env, packed_session) ? {} : data_attr(packed_session)
      {
        :attribute_updates => merge_all(updated_attr, data, add_attrs, shadow_attr(session)),
        :return_values => "UPDATED_NEW"
      }
    end

    # Update client with current time attribute.
    def updated_at
      { :value => "#{(Time.now).to_f}", :action  => "PUT" }
    end

    # Attribute for creation of session.
    def created_attr
      { "created_at" => updated_at }
    end

    # Attribute for updating session.
    def updated_attr
      {
        "updated_at" => updated_at
      }
    end

    def data_attr(session)
       { "data" => {:value => session, :action  => "PUT"} }
    end

    def shadow_attr(session)
      return {} if @config.shadow.nil?

      attr = Hash.new

      @config.shadow.split(',').each do |e|
        key = e.split(':')[0]
        value = session[key]
        attr[key] = value.nil? ? {:action => "DELETE"} : {:value => value, :action => "PUT"}
      end

      attr
    end

    # Determine if data has been manipulated
    def data_unchanged?(env, session)
      return false unless env['rack.initial_data']
      env['rack.initial_data'] == session
    end

    # Expected attributes
    def expected_attributes(sid)
      { :expected => {@config.table_key => {:value => sid, :exists => true}} }
    end

    # Attributes to be retrieved via client
    def attr_opts
      {:attributes_to_get => ["data"],
      :consistent_read => @config.consistent_read}
    end

    # @return [Hash] merged hash of all hashes passed in.
    def merge_all(*hashes)
      new_hash = {}
      hashes.each{|hash| new_hash.merge!(hash)}
      new_hash
    end
  end
end
