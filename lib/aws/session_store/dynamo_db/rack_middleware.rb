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

require 'rack/session/abstract/id'
require 'openssl'
require 'aws-sdk-dynamodb'

module Aws::SessionStore::DynamoDB
  # This class is an ID based Session Store Rack Middleware
  # that uses a DynamoDB backend for session storage.
  class RackMiddleware < Rack::Session::Abstract::ID

    # Initializes SessionStore middleware.
    #
    # @param app Rack application.
    # @option (see Configuration#initialize)
    # @raise [Aws::DynamoDB::Errors::ResourceNotFoundException] If valid table
    #   name is not provided.
    # @raise [Aws::SessionStore::DynamoDB::MissingSecretKey] If secret key is
    #   not provided.
    def initialize(app, options = {})
      super
      @config = Configuration.new(options)
      set_locking_strategy
    end

    private

    # Sets locking strategy for session handler
    #
    # @return [Locking::Null] If locking is not enabled.
    # @return [Locking::Pessimistic] If locking is enabled.
    def set_locking_strategy
      if @config.enable_locking
        @lock = Aws::SessionStore::DynamoDB::Locking::Pessimistic.new(@config)
      else
        @lock = Aws::SessionStore::DynamoDB::Locking::Null.new(@config)
      end
    end

    # Determines if the correct session table name is being used for
    # this application. Also tests existence of secret key.
    #
    # @raise [Aws::DynamoDB::Errors::ResourceNotFoundException] If wrong table
    #   name.
    def validate_config
      raise MissingSecretKeyError unless @config.secret_key
    end

    # Gets session data.
    def get_session(env, sid)
      validate_config
      case verify_hmac(sid)
      when nil
        set_new_session_properties(env)
      when false
        handle_error {raise InvalidIDError}
        set_new_session_properties(env)
      else
        data = @lock.get_session_data(env, sid)
        [sid, data || {}]
      end
    end

    def set_new_session_properties(env)
      env['dynamo_db.new_session'] = 'true'
      [generate_sid, {}]
    end

    # Sets the session in the database after packing data.
    #
    # @return [Hash] If session has been saved.
    # @return [false] If session has could not be saved.
    def set_session(env, sid, session, options)
      @lock.set_session_data(env, sid, session, options)
    end

    # Destroys session and removes session from database.
    #
    # @return [String] return a new session id or nil if options[:drop]
    def destroy_session(env, sid, options)
      @lock.delete_session(env, sid)
      generate_sid unless options[:drop]
    end

    # Each database operation is placed in this rescue wrapper.
    # This wrapper will call the method, rescue any exceptions and then pass
    # exceptions to the configured session handler.
    def handle_error(env = nil, &block)
      begin
        yield
      rescue Aws::DynamoDB::Errors::Base,
             Aws::SessionStore::DynamoDB::InvalidIDError => e
        @config.error_handler.handle_error(e, env)
      end
    end

    # Generate HMAC hash
    def generate_hmac(sid, secret)
      OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, secret, sid).strip()
    end

    # Generate sid with HMAC hash
    def generate_sid(secure = @sid_secure)
      sid = super(secure)
      sid = "#{generate_hmac(sid, @config.secret_key)}--" + sid
    end

    # Verify digest of HMACed hash
    #
    # @return [true] If the HMAC id has been verified.
    # @return [false] If the HMAC id has been corrupted.
    def verify_hmac(sid)
      return unless sid
      digest, ver_sid  = sid.split("--")
      return false unless ver_sid
      digest == generate_hmac(ver_sid, @config.secret_key)
    end
  end
end
