# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require "aws-sdk-sns"

class DeveloperKey < ActiveRecord::Base
  class CacheOnAssociation < ActiveRecord::Associations::BelongsToAssociation
    def find_target
      if owner.instance_variable_get(:@skip_dev_key_cache)
        super
      else
        DeveloperKey.find_cached(owner.attribute(reflection.foreign_key))
      end
    end
  end

  CONFIDENTIAL_CLIENT_TYPE = "confidential"
  PUBLIC_CLIENT_TYPE = "public"
  ALLOWED_AUTHORIZED_FLOWS = ["service_user_client_credentials"].freeze

  include CustomValidations
  include Workflow

  belongs_to :user
  belongs_to :account
  belongs_to :root_account, class_name: "Account"
  belongs_to :service_user, class_name: "User"
  belongs_to :lti_registration, class_name: "Lti::Registration", inverse_of: :developer_key
  has_many :page_views
  has_many :access_tokens, -> { where(workflow_state: "active") }
  has_many :developer_key_account_bindings, inverse_of: :developer_key
  has_many :context_external_tools

  has_one :tool_consumer_profile, class_name: "Lti::ToolConsumerProfile", inverse_of: :developer_key
  has_one :tool_configuration, class_name: "Lti::ToolConfiguration", inverse_of: :developer_key
  # This *cannot* be dependent: :destroy. Lti::IMS::Registration includes Canvas::SoftDeletable, which overrides
  # what it means to destroy a record. If we set this to dependent: :destroy, it will try to destroy the
  # Lti::IMS::Registration, which will only set the workflow_state to deleted. Rails will then
  # check to see if the record was actually deleted from the database, and if it wasn't,
  # will abort the callback. This leaves us in a weird state where the developer key doesn't get "destroyed",
  # but the IMS Registration does. Thus, we let the lti_registration take care of deleting
  # all LTI associated records.
  has_one :ims_registration, class_name: "Lti::IMS::Registration", inverse_of: :developer_key
  serialize :scopes, type: Array

  before_validation :normalize_public_jwk_url
  before_validation :normalize_scopes
  before_validation :validate_scopes!
  before_create :generate_api_key
  before_create :set_auto_expire_tokens
  before_create :set_visible
  before_save :nullify_empty_icon_url
  before_save :protect_default_key
  before_save :set_require_scopes
  before_save :set_root_account
  after_create :create_lti_registration
  after_create :create_default_account_binding
  after_save :clear_cache
  after_update :invalidate_access_tokens_if_scopes_removed!
  after_update :destroy_external_tools!, if: :destroy_external_tools?
  # See comment on destroy_associated_records! for why we don't use
  # lifecycle callbacks here.
  before_destroy :destroy_associated_records!

  validates :client_type, inclusion: { in: [PUBLIC_CLIENT_TYPE, CONFIDENTIAL_CLIENT_TYPE] }
  validates_as_url :redirect_uri, :oidc_initiation_url, :public_jwk_url, allowed_schemes: nil
  validate :validate_redirect_uris
  validate :validate_public_jwk
  validate :validate_lti_fields
  validate :validate_flag_combinations
  validate :validate_authorized_flows

  attr_reader :private_jwk
  attr_accessor :skip_lti_sync, :current_user

  scope :nondeleted, -> { where("workflow_state<>'deleted'") }
  scope :not_active, -> { where("workflow_state<>'active'") } # search for deleted & inactive keys
  scope :visible, -> { where(visible: true) }
  scope :site_admin, -> { where(account_id: nil) } # site_admin keys have a nil account_id
  scope :site_admin_lti, lambda { |key_ids|
    # Select site admin shard developer key ids
    site_admin_key_ids = key_ids.select do |id|
      Shard.local_id_for(id).second == Account.site_admin.shard
    end

    Account.site_admin.shard.activate do
      lti_key_ids = Lti::ToolConfiguration.joins(:developer_key)
                                          .where(developer_keys: { id: site_admin_key_ids })
                                          .pluck(:developer_key_id)
      where(id: lti_key_ids)
    end
  }

  workflow do
    state :active do
      event :deactivate, transitions_to: :inactive
    end
    state :inactive do
      event :activate, transitions_to: :active
    end
    state :deleted
  end

  DEFAULT_KEY_NAME = "User-Generated"

  # https://stackoverflow.com/a/2500819
  alias_method :referenced_tool_configuration, :tool_configuration

  alias_method :destroy_permanently!, :destroy
  def destroy
    return true if deleted?

    self.workflow_state = "deleted"
    destroy_associated_records!
    save!
  end

  def confidential_client?
    client_type == CONFIDENTIAL_CLIENT_TYPE
  end

  def public_client?
    client_type == PUBLIC_CLIENT_TYPE
  end

  def usable?
    return false if DeveloperKey.test_cluster_checks_enabled? &&
                    test_cluster_only? && !ApplicationController.test_cluster?

    active?
  end

  def usable_in_context?(context)
    account_binding_for(context.try(:account) || context)&.on? && usable?
  end

  def redirect_uri=(value)
    super(value.presence)
  end

  def redirect_uris=(value)
    value = value.split if value.is_a?(String)
    super
  end

  def ims_registration?
    ims_registration.present?
  end

  def validate_redirect_uris
    uris = redirect_uris&.map do |value|
      value, _ = CanvasHttp.validate_url(value, allowed_schemes: nil)
      value
    end

    errors.add :redirect_uris, "a redirect_uri is too long" if uris.any? { |uri| uri.length > 4096 }

    self.redirect_uris = uris unless uris == redirect_uris
  rescue CanvasHttp::Error, URI::Error, ArgumentError
    errors.add :redirect_uris, "is not a valid URI"
  end

  def protect_default_key
    raise "Please never delete the default developer key" if workflow_state != "active" && self == self.class.default
  end

  def nullify_empty_icon_url
    self.icon_url = nil if icon_url.blank?
  end

  def generate_api_key(overwrite = false)
    self.api_key = CanvasSlug.generate(nil, 64) if overwrite || !api_key
  end

  def generate_rsa_keypair!(overwrite: false)
    return if public_jwk.present? && !overwrite

    key_pair = CanvasSecurity::RSAKeyPair.new
    @private_jwk = key_pair.to_jwk
    self.public_jwk = key_pair.public_jwk.to_h
  end

  def set_auto_expire_tokens
    self.auto_expire_tokens = true
  end

  def set_visible
    self.visible = !site_admin?
  end

  def destroy_associated_records!
    # You might wonder why we aren't using lifecycle callbacks here.
    # The answer is that if we do, Rails will also try to destroy the IMS Registration.
    # However, Lti::IMS::Registration includes Canvas::SoftDeletable,
    # which means that `destroy` only sets the workflow_state to deleted. Rails will then
    # go "Hey, I called destroy but you didn't get actually get deleted from the database! Abort!"
    # and then we'll be left in a weird state where the developer key doesn't get "destroyed",
    # but the IMS Registration does. Additionally, the order here is important, as we need to
    # destroy the tool configuration before the LTI registration and IMS registration.
    tool_configuration&.destroy
    lti_registration&.destroy
    ims_registration&.destroy
    lti_registration&.destroy
    developer_key_account_bindings&.find_each(&:destroy)
  end

  class << self
    def default(create_if_missing: true)
      get_special_key(DeveloperKey::DEFAULT_KEY_NAME, create_if_missing:)
    end

    def get_special_key(default_key_name, create_if_missing: true)
      Shard.birth.activate do
        @special_keys ||= {}

        key = @special_keys[default_key_name]
        return key if key

        if (key_id = Setting.get("#{default_key_name}_developer_key_id", nil)) && key_id.present?
          key = DeveloperKey.where(id: key_id).first
        end
        return @special_keys[default_key_name] = key if key
        return nil unless create_if_missing

        key = DeveloperKey.create!(name: default_key_name)
        key.developer_key_account_bindings.update_all(workflow_state: "on")
        key.update(auto_expire_tokens: false)
        Setting.set("#{default_key_name}_developer_key_id", key.id)
        return @special_keys[default_key_name] = key
      end
    end

    # for now, only one AWS account for SNS is supported
    def sns(region:)
      @sns ||= {}

      unless @sns[region].present?
        settings = Rails.application.credentials.sns_creds
        @sns[region] = Aws::SNS::Client.new(settings.merge(region:)) if settings
      end
      @sns[region]
    end

    def test_cluster_checks_enabled?
      Setting.get("dev_key_test_cluster_checks_enabled", nil).present?
    end

    def find_cached(id)
      global_id = Shard.global_id_for(id)
      MultiCache.fetch("developer_key/#{global_id}") do
        GuardRail.activate(:secondary) do
          DeveloperKey.find_by(id: global_id)
        end
      end or raise ActiveRecord::RecordNotFound
    end

    def by_cached_vendor_code(vendor_code)
      MultiCache.fetch("developer_keys/#{vendor_code}") do
        DeveloperKey.shard([Shard.current, Account.site_admin.shard].uniq).where(vendor_code:).to_a
      end
    end

    def mobile_app_keys(active: true)
      GuardRail.activate(:secondary) do
        keys = shard(Shard.default).where.not(sns_arn: nil)
        active ? keys.nondeleted : keys
      end
    end
  end

  def clear_cache
    MultiCache.delete("developer_key/#{global_id}")
    MultiCache.delete("developer_keys/#{vendor_code}") if vendor_code.present?
  end

  def set_root_account
    # If the key belongs to a non-site admin account, resolve
    # the root account through that account. Otherwise use the
    # site admin account ID if the current shard is the site admin
    # shard
    self.root_account_id ||= account&.resolved_root_account_id
    self.root_account_id ||= Account.site_admin.id if Shard.current == Shard.default
  end

  def authorized_for_account?(target_account)
    return false unless binding_on_in_account?(target_account)
    return true if account_id.blank?
    return true if target_account.id == account_id

    include_federated_parent_id = !target_account.root_account.primary_settings_root_account?

    target_account.account_chain_ids(include_federated_parent_id:).include?(account_id)
  end

  def account_name
    account.try(:name)
  end

  def last_used_at
    access_tokens.maximum(:last_used_at)
  end

  # verify that the given uri has the same domain as this key's
  # redirect_uri domain.
  def redirect_domain_matches?(redirect_uri)
    return false if redirect_uri.blank?
    return true if redirect_uris.include?(redirect_uri)

    # legacy deprecated
    self_uri = URI.parse(self.redirect_uri)
    self_domain = self_uri.host
    other_uri = URI.parse(redirect_uri)
    other_domain = other_uri.host
    result = self_domain.present? && other_domain.present? &&
             self_uri.scheme == other_uri.scheme &&
             (self_domain == other_domain || other_domain.end_with?(".#{self_domain}"))
    if result && redirect_uri != self.redirect_uri
      Rails.logger.info("Allowed lenient OAuth redirect uri #{redirect_uri} on developer key #{global_id}")
    end
    result
  rescue URI::Error
    false
  end

  # Verify that the given uri has the same scheme, domain and port as this key's
  # redirect_uri's.
  def redirect_uri_matches?(redirect_uri)
    return false if redirect_uri.blank?

    normalized_redirect_uri = Addressable::URI.parse(redirect_uri).normalized_site
    return false if normalized_redirect_uri.blank?
    return true if redirect_uris.include?(redirect_uri)

    redirect_uris.map { |uri| Addressable::URI.parse(uri).normalized_site }
                 .include?(normalized_redirect_uri)
  rescue Addressable::URI::InvalidURIError
    false
  end

  def account_binding_for(binding_account)
    # If no account was specified return nil to prevent unneeded searching
    return if binding_account.blank?

    # First check for explicitly set bindings starting with site admin and working down
    binding = DeveloperKeyAccountBinding.find_site_admin_cached(self)
    return binding if binding.present?

    # Search for bindings in the account chain starting with the highest account,
    # and include consortium parent if necessary
    include_federated_parent = !binding_account.root_account.primary_settings_root_account?
    accounts = binding_account.account_chain(include_federated_parent:).reverse
    binding = DeveloperKeyAccountBinding.find_in_account_priority(accounts, self)

    # If no explicitly set bindings were found check for 'allow' bindings
    binding ||= DeveloperKeyAccountBinding.find_in_account_priority(accounts.reverse, self, explicitly_set: false)

    binding
  end

  def owner_account
    account || Account.site_admin
  end

  def binding_on_in_account?(target_account)
    account_binding_for(target_account)&.on?
  end

  def disable_external_tools!(binding_account)
    manage_external_tools(
      tool_management_enqueue_args,
      :disable_tools_on_active_shard!,
      binding_account
    )
  end

  def enable_external_tools!(binding_account)
    manage_external_tools(
      tool_management_enqueue_args,
      :enable_tools_on_active_shard!,
      binding_account
    )
  end

  def restore_external_tools!(binding_account)
    manage_external_tools(
      tool_management_enqueue_args,
      :restore_tools_on_active_shard!,
      binding_account
    )
  end

  def update_external_tools!
    manage_external_tools(
      tool_management_enqueue_args,
      :update_tools_on_active_shard!,
      account
    )
  end

  def issue_token(claims)
    case client_credentials_audience
    when "external"
      # asymmetric encryption signed with private key to be verified by third
      # party using public key fetched from /login/oauth2/jwks
      key = Canvas::OAuth::KeyStorage.present_key
      Canvas::Security.create_jwt(claims, nil, key, :autodetect).to_s
    else
      # default symmetric encryption to be verified when given right back to
      # canvas
      Canvas::Security.create_jwt(claims).to_s
    end
  end

  def mobile_app?
    false
  end

  def tokens_expire_in
    return nil unless mobile_app? || public_client?

    # By default, non-mobile public clients have a two-hour rolling refresh window
    return Setting.get("public_client_token_ttl", "120").to_f.minutes if public_client? && !mobile_app?

    # Public client mobile apps expiration is configurable by the sessions plugin
    # and falls back to a globally-configurable default, so these tokens always expire
    sessions_settings = Canvas::Plugin.find("sessions").settings || {}
    configured_timeout = sessions_settings[:mobile_timeout]&.to_f&.minutes
    return configured_timeout || Setting.get("mobile_public_client_token_ttl_days", "90").to_f.days if public_client?

    # Confidential client mobile apps expiration is configurable by the sessions plugin
    # and might be nil (meaning no expiration)
    configured_timeout
  end

  # In an OAuth context, setting this field to true means that access tokens
  # from this key will not be displayed on the user profile page.
  #
  # In an LTI context, setting this field to true means that any tools associated
  # with this key are considered "internal" tools (like Quizzes, etc) and are
  # eligible for internal-only features. These features are opt-in only and not
  # required, and internally-developed tools are not required to set this field
  # to true if they don't need any of the features. These tools may be LTI 1.1
  # or LTI 1.3 tools.
  def internal_service?
    internal_service
  end

  # If true, this key can be used for "service authentication" (a token request
  # using a client_credentials grant type and a pre-determined service user).
  #
  # This pattern is only supported for keys with
  # "service_user_client_credentials" in authorized_flows.
  def site_admin_service_auth?
    authorized_flows.include?("service_user_client_credentials") && service_user.present?
  end

  def tool_configuration
    ims_registration.presence || referenced_tool_configuration
  end

  private

  def create_lti_registration
    return unless is_lti_key?
    return if skip_lti_sync
    return if lti_registration.present?

    lti_registration = Lti::Registration.new(developer_key: self,
                                             account: account || Account.site_admin,
                                             created_by: current_user,
                                             updated_by: current_user,
                                             admin_nickname: name,
                                             name: tool_configuration_name,
                                             workflow_state:,
                                             ims_registration:,
                                             manual_configuration: referenced_tool_configuration)
    lti_registration.save!
  end

  def tool_configuration_name
    tool_configuration&.internal_lti_configuration&.dig(:title) || "Unnamed tool"
  end

  def validate_lti_fields
    return unless is_lti_key?
    return if public_jwk.present? || public_jwk_url.present?

    errors.add(:lti_key, "developer key must have public jwk or public jwk url")
  end

  def validate_flag_combinations
    return unless auto_expire_tokens && force_token_reuse

    errors.add(:auto_expire_tokens, "auto_expire_tokens cannot be set if force_token_reuse is set")
  end

  def normalize_public_jwk_url
    self.public_jwk_url = nil if public_jwk_url.blank?
  end

  def normalize_scopes
    self.scopes = scopes.uniq
  end

  def manage_external_tools(enqueue_args, method, affected_account)
    return if tool_configuration.blank?

    start_time = Time.zone.now.to_i
    if affected_account.blank? || affected_account.site_admin?
      # Cleanup tools across all shards
      delay(**enqueue_args)
        .manage_external_tools_multi_shard(enqueue_args, method, affected_account, start_time)
    else
      delay(**enqueue_args).manage_external_tools_on_shard(method, affected_account, start_time)
    end
  end

  def manage_external_tools_multi_shard_in_region(enqueue_args, method, affected_account, start_time)
    Shard.with_each_shard(Shard.in_current_region) do
      delay(**enqueue_args).manage_external_tools_on_shard(method, affected_account, start_time)
    rescue
      raise Delayed::RetriableError
    end
  end

  def manage_external_tools_multi_shard(enqueue_args, method, affected_account, start_time)
    DatabaseServer.send_in_each_region(
      self,
      :manage_external_tools_multi_shard_in_region,
      enqueue_args, # args passed to delay() this time when creating job in each region
      enqueue_args, # first argument to manage_external_tools_multi_shard_in_region
      method,
      affected_account,
      start_time
    )
  rescue
    raise Delayed::RetriableError
  end

  def manage_external_tools_on_shard(method, account, start_time)
    __send__(method, account)
    instrument_tool_management(method, start_time)
  rescue => e
    instrument_tool_management(method, start_time, e)
    raise e
  end

  def instrument_tool_management(method, start_time, exception = nil)
    stat_prefix = "developer_key.manage_external_tools"
    stat_prefix += ".error" if exception

    tags = { method: }
    latency = (Time.zone.now.to_i - start_time) * 1000 # ms for DD

    InstStatsd::Statsd.distributed_increment("#{stat_prefix}.count", tags:)
    InstStatsd::Statsd.timing("#{stat_prefix}.latency", latency, tags:)

    if exception
      Canvas::Errors.capture_exception(:developer_keys, exception, :error)
    end
  end

  def tool_management_enqueue_args
    {
      n_strand: ["developer_key_tool_management", account&.global_id || "site_admin"],
      priority: Delayed::LOW_PRIORITY,
      max_attempts: 4
    }
  end

  def destroy_external_tools?
    saved_change_to_workflow_state? && workflow_state == "deleted" && tool_configuration.present?
  end

  def destroy_external_tools!
    manage_external_tools(
      tool_management_enqueue_args,
      :destroy_tools_from_active_shard!,
      account
    )
  end

  def destroy_tools_from_active_shard!(affected_account)
    base_scope = ContextExternalTool.where.not(workflow_state: "deleted")
    tool_management_scope(base_scope, affected_account).select(:id).find_in_batches do |tool_ids|
      ContextExternalTool.where(id: tool_ids).destroy_all
    end
  end

  def set_tool_workflow_state_on_active_shard!(state, scope, binding_account)
    tool_management_scope(scope, binding_account).select(:id).find_in_batches do |tool_ids|
      ContextExternalTool.where(id: tool_ids).update(
        workflow_state: state
      )
    end
  end

  def tool_management_scope(base_scope, affected_account)
    if affected_account&.site_admin? || affected_account.blank?
      return base_scope.where(developer_key: self)
    end

    # Don't update tools in another root account on the same shard
    base_scope.where(developer_key: self, root_account: affected_account)
  end

  def update_tools_on_active_shard!(account)
    return if tool_configuration.blank?

    base_scope = ContextExternalTool.where.not(workflow_state: "deleted")
    tool_management_scope(base_scope, account).select(:id).find_in_batches do |tool_ids|
      # There appear to be broken tools with no context, which break later on in the process.
      # Skip them.
      ContextExternalTool.where(id: tool_ids).preload(:context).each do |tool|
        next unless tool.context

        lti_registration.new_external_tool(
          tool.context,
          existing_tool: tool
        )
      end
    end
  end

  def restore_tools_on_active_shard!(_binding_account)
    return if tool_configuration.blank?

    Account.root_accounts.each do |root_account|
      next if root_account.site_admin?

      binding = DeveloperKeyAccountBinding.find_by(
        developer_key: self,
        account: root_account
      )

      return nil if binding.blank?

      if binding.on?
        enable_tools_on_active_shard!(root_account)
      elsif binding.off?
        disable_tools_on_active_shard!(root_account)
      end
    end
  end

  def disable_tools_on_active_shard!(binding_account)
    return if tool_configuration.blank?

    set_tool_workflow_state_on_active_shard!(
      ContextExternalTool::DISABLED_STATE,
      ContextExternalTool.active,
      binding_account
    )
  end

  def enable_tools_on_active_shard!(binding_account)
    return if tool_configuration.blank?

    set_tool_workflow_state_on_active_shard!(
      tool_configuration.privacy_level,
      ContextExternalTool.disabled,
      binding_account
    )
  end

  def validate_public_jwk
    return if public_jwk.blank?

    jwk_errors = Schemas::Lti::PublicJwk.simple_validation_errors(public_jwk)
    return if jwk_errors.nil?

    jwk_errors.each { |error| errors.add :public_jwk, error }
  end

  def invalidate_access_tokens_if_scopes_removed!
    return unless saved_change_to_scopes?
    return if (scopes_before_last_save - scopes).blank?

    delay_if_production.invalidate_access_tokens!
  end

  def invalidate_access_tokens!
    access_tokens.destroy_all
  end

  def create_default_account_binding
    owner_account.developer_key_account_bindings.create!(developer_key: self)
  end

  def set_require_scopes
    # Prevent RSA keys from having API access
    self.require_scopes = true if public_jwk.present? || public_jwk_url.present?
  end

  def validate_scopes!
    return true if scopes.empty?

    invalid_scopes = scopes - TokenScopes.all_scopes
    return true if invalid_scopes.empty?

    errors.add(:scopes, "cannot contain #{invalid_scopes.join(", ")}")
  end

  def site_admin?
    account_id.nil?
  end

  def validate_authorized_flows
    return if authorized_flows.blank?

    invalid_flows = authorized_flows.reject { |af| ALLOWED_AUTHORIZED_FLOWS.include?(af) }
    errors.add(:authorized_flows, "contains invalid values: #{invalid_flows.join(", ")}") if invalid_flows.present?
    errors.add(:authorized_flows, "contains duplicate values") if authorized_flows.uniq.length != authorized_flows.length
  end
end
